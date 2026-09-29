# Central Infrastructure Alerts & Notifications (Step 16)

Connects the existing read-only monitoring/recommendations layer (Steps
6/8/13) to a stateful, deduplicated alert lifecycle and a notification
system — never a remediation trigger. Flow:

```
VM / Docker / Database → Metrics → Health/Recommendation → Alert Rule →
Alert → Notification → Admin/authorized user
```

## 1. Alert vs. Recommendation

Kept deliberately separate (spec §41). A **recommendation** (Step 7/13)
is advisory: upserted once per collection cycle, no duration gate, no
hysteresis, no acknowledgment workflow, no notification. An **alert**
(this step) is a stateful, threshold+duration-gated, deduplicated
lifecycle that drives real notifications — `Recommendation: "Database
connection usage is high."` vs. `Alert: "CRITICAL: Database connection
usage exceeded 95% for 5 minutes."`.

## 2. Architecture

```
AlertEngine.Run (ALERT_EVAL_INTERVAL, default 30s)
  → ListEnabledAlertRulesForEvaluation (one query, joins resources/vms/
    databases/docker_containers -- everything a rule needs to evaluate)
  → alertMetricLookup (reads the LATEST already-collected sample from
    monitoring_snapshots / docker_containers+docker_container_metric_snapshots /
    standalone_database_metrics+standalone_database_deep_metrics --
    never collects a new sample itself, never opens a new SSH/DB
    connection)
  → AlertCondition.Evaluate(value, threshold)
  → duration gate (alert_rules.breach_started_at)
  → dedup (GetActiveAlertForRule -- at most one ACTIVE/ACKNOWLEDGED
    alert per rule, also enforced by a partial unique index)
  → alerts / alert_events (migration 025)
  → NotificationService.NotifyAlert
      → resolveRecipients (every Admin + every Member with direct/group
        access to the resource, mirrors CanAccessVM/CanAccessDatabase's
        access model exactly)
      → per (alert, channel, recipient) cooldown check
        (ALERT_NOTIFICATION_COOLDOWN, default 15m)
      → NotificationProvider.Send (InAppProvider / WebhookProvider)
      → notifications row (status SENT/FAILED, never silently dropped)
```

## 3. Duration + hysteresis (spec §9/§10)

A rule's `condition`/`threshold` must hold continuously for
`duration_seconds` before an alert is created — `alert_rules.breach_started_at`
tracks this and resets to NULL the instant the condition stops holding
before the duration elapses, so a flapping metric never silently
accumulates toward triggering. Recovery uses `recovery_threshold` (the
trigger condition's inverse, evaluated against it) when configured, else
falls back to the trigger threshold itself (a zero-width hysteresis gap)
— recovery is **never** duration-gated: one good sample after a long bad
streak resolves immediately (matches the spec's own worked example).

## 4. Deduplication (spec §11)

Identity is `alert_rule_id` (which already encodes resource + alert_type
+ condition, since a rule is scoped to exactly one of each) — a unique
partial index (`alerts_rule_active_unique`) guarantees at most one
`ACTIVE`/`ACKNOWLEDGED` alert per rule at the database level, on top of
the engine's own check-before-create logic.

## 5. Notification channels (spec §23/§26)

`NotificationProvider` is a two-method interface (`Validate`, `Send`);
`InAppProvider` (a no-op — the `notifications` row itself is the
delivery) and `WebhookProvider` (a real `POST` of exactly `alert_id`,
`severity`, `resource`, `resource_type`, `alert_type`, `current_value`,
`threshold`, `status`, `timestamp` — never a credential) are registered
today. `EMAIL`/`SLACK`/`TEAMS` are valid `NotificationChannel` values a
policy can select (so the schema/UI never need to change when a real
provider is added) — until one is registered, selecting them just means
that one delivery is recorded `FAILED` with "no notification provider
registered for channel X", never a fabricated success.

Retries use a short, bounded exponential backoff
(`ALERT_NOTIFICATION_MAX_RETRIES`, default 3) — never indefinite (spec
§54). A failed notification never touches the underlying alert's own
status (spec §53) — `alerts.status` and `notifications.status` are
independent facts.

## 6. Suppression (spec §30) vs. rule disable

Suppressing an *alert* (`POST /api/alerts/:id/suppress`, Admin-only,
requires `duration_minutes` + `reason`) transitions the alert to
`SUPPRESSED` immediately and suppresses its underlying *rule* for the
same window (`alert_rules.suppressed_until`) — otherwise the engine's
very next evaluation cycle would just recreate an identical alert.
Disabling a rule (`PUT /api/alert-rules/:id` with `enabled: false`) is a
separate, coarser, indefinite action. Both are audited
(`ALERT_SUPPRESSED`).

## 7. Engine resilience (spec §52)

`AlertEngine.Status()` reports the engine's own health (`Healthy`/
`LastError`/`LastRunAt`) completely independently of any VM/Docker/
database's monitoring health — a failed or panicking evaluation cycle
(caught via `recover()`) degrades only this flag, never marks any
resource itself unavailable, and monitoring/collection schedulers are
entirely separate goroutines unaffected by an alert-engine failure.

## 8. Authorization (spec §22/§55-57)

Alert visibility mirrors the underlying resource's own access model
exactly (`CanAccessVM`/`CanAccessDatabase`, merged the same way
`RecommendationHandler` already does) — a Member sees only alerts for
resources they're authorized on, 404-not-403 for a specific alert ID
they aren't. Alert-rule management and acknowledge/suppress are
Admin-only, enforced server-side on every request (never inferred from
what the frontend renders). The real-time `GET /api/alerts/stream`
WebSocket resolves the same authorized-resource scope once at connect
time and re-applies it on every push — it does not fan a new alert out
to every connected browser, only to each browser's own authorized query.

## 9. What's deliberately not implemented

- Automatic remediation of any kind (spec §63) — an alert only notifies;
  Step 14's database operations remain the only execution path, always
  Admin-reviewed and explicitly confirmed.
- Real EMAIL/SLACK/TEAMS delivery — no such infrastructure exists in
  this project yet; the provider interface and channel vocabulary are
  ready for it.
- Escalation policies (WARNING → CRITICAL over time) — spec explicitly
  says not to build this until needed.
- A configured maintenance-window calendar — alert suppression (§6
  above) covers the "planned maintenance" use case spec describes
  without a separate scheduling subsystem.
- Docker container OOM detection — `DOCKER_CONTAINER_OOM` exists in the
  schema/type catalog for forward compatibility, but Docker's OOM-kill
  flag isn't captured anywhere in this project's `docker_containers`
  schema yet, so no adapter declares it evaluable (mirrors Step 14's
  "declared but unsupported" precedent for `RESTART`/`UPGRADE`).
- A tracked "capacity" for a standalone database's storage, so
  `DATABASE_HIGH_STORAGE` compares the database's own reported size (in
  GB) against an absolute Admin-chosen threshold, not a percentage —
  there's no capacity concept to compute a percentage against for an
  externally-managed database.
