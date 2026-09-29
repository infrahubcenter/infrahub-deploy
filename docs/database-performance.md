> **Superseded.** This documented the VM-attached, SSH-based Step 13 that
> was later fully replaced by standalone database performance monitoring
> (direct TCP/TLS, no VM/SSH involved) on top of Step 13's standalone
> rework. The read-only claims below ("nothing in this step can execute
> arbitrary SQL, cancel a query, kill a session...") were true for that
> removed architecture; they are **no longer true project-wide** as of
> Step 14, which adds exactly controlled, backend-templated versions of
> query cancellation/session termination/VACUUM/ANALYZE (never arbitrary
> SQL, always Admin-confirmed) — see
> [database-operations.md](database-operations.md) and the README's
> "Database Operations" section. This file is kept only for historical
> context.

# Advanced Database Performance Monitoring (Step 13) — historical, superseded

Still strictly read-only, layered on top of Step 12's discovery/common-metrics
foundation. Nothing in this step can execute arbitrary SQL, cancel a query,
kill a session, restart a database, run `VACUUM`/`ANALYZE`, or change any
configuration — those are explicitly reserved for a future, separately
gated, controlled-operation step (see [§15](#15-no-remediation) below).

## 1. Architecture

```
Database → Fast Collector (Step 12, 15s) ─┐
        └→ Deep Collector (Step 13, 60s) ─┴→ Caches → Go API → Dashboard
```

`DatabaseDeepMetricsService`/`DatabaseDeepMetricsScheduler`
(`internal/services/database_deep_metrics_{service,scheduler,cache}.go`) are
new, independent siblings of Step 12's `DatabaseMetricsService`/
`DatabaseMetricsScheduler` — never a modification of the fast path. Both
share the same SSH/RemoteExecutor foundation (Step 5) and the same
`DatabaseConnectionLimiter` (a `DATABASE_MONITOR_MAX_CONNECTIONS`-sized
semaphore, `database_connection_limiter.go`), so the two cycles' combined
concurrency can never open more monitoring connections to a target
database than that one configured number, regardless of how many workers
either scheduler runs.

## 2. Database adapters

`DatabaseAdapter` (Step 12) gained one new method:

```go
CollectDeepMetrics(ctx, client, executor, timeout, conn) (DeepMetricsResult, error)
```

Rather than the seven separate methods spec #80 sketches
(`GetPerformanceMetrics`/`GetQueryMetrics`/`GetConnectionMetrics`/
`GetLockMetrics`/`GetReplicationMetrics`/`GetStorageMetrics`), this
project uses **one** combined method per engine returning a
`DeepMetricsResult` whose sub-fields (`Queries`, `Locks`, `Replication`,
`Sessions`, `CacheHitRatio`, …) are independently optional — the same "one
round trip, several optional facts" discipline Step 12 established for
the fast path, applied to the slower cycle. An engine that doesn't
support a category simply leaves the corresponding field empty; the
frontend uses `CapabilitiesForType` (`database_capabilities.go`) to know
which tabs/sections to render rather than inferring support from empty
data.

## 3. Performance metrics by engine

- **PostgreSQL** (`database_postgresql_deep.go`): one scalar query
  (temp files/bytes, deadlocks, cache hit inputs, xact_commit/rollback,
  checkpoints, WAL LSN delta, replication lag, lock waiting/blocked
  counts via `pg_blocking_pids`), one bounded (`LIMIT 50`) session
  snapshot from `pg_stat_activity` (state/wait_event/duration/blocking
  PIDs — never query text), and `pg_stat_statements` for query rankings
  when available.
- **MySQL/MariaDB** (`database_mysql_deep.go`): InnoDB buffer pool
  hit ratio, row lock wait counters, temp table counters, table lock
  counters, and `performance_schema.events_statements_summary_by_digest`
  for query rankings when available.
- **MongoDB** (`database_mongodb_deep.go`): `serverStatus().opLatencies`
  (read/write/command average latency), WiredTiger cache sizing,
  `rs.status()` for replica-set state (wrapped in the script's own
  try/catch, since it errors outright on a non-replica-set node), and
  `getProfilingStatus()` — read-only, never changes profiler settings.
- **Redis** (`database_redis_deep.go`): evicted/expired key counters,
  `instantaneous_ops_per_sec`, `mem_fragmentation_ratio`, and replica lag
  parsed directly from `INFO replication`'s own `lag=` field.

## 4. Query monitoring

Query-level metrics are aggregated by fingerprint per collection cycle in
`database_query_metrics` (migration `022`) — never a copy of every
execution. PostgreSQL and MySQL/MariaDB both prefer the engine's own
already-normalized identifier over re-parsing SQL themselves:
`pg_stat_statements.queryid` and `performance_schema`'s `DIGEST`,
respectively, both computed by the database's own parser.

## 5. Query fingerprints

`Fingerprint(normalized string) string` (`database_query_normalize.go`)
is a SHA-256 hex digest. For Postgres/MySQL it's computed over the
engine's native identifier; `NormalizeQuery(sql string) string` is the
generic fallback/utility (regex-based literal-stripping + whitespace
collapse) — implemented and unit-tested per spec #9, even though the two
primary engines prefer their own superior native mechanism.

## 6. Query normalization

`NormalizeQuery` replaces string literals (`'...'`) and numeric literals
with `?` and collapses whitespace — deliberately not a full SQL parser
(spec #9: "do not guarantee perfect SQL normalization across every SQL
syntax"). `SELECT * FROM orders WHERE id = 100` and `WHERE id = 200`
normalize identically.

## 7. Query privacy

`DATABASE_QUERY_TEXT_CAPTURE` (default **`false`**) gates whether
`database_query_metrics.normalized_text` is ever populated at all — when
disabled, only the fingerprint and numeric stats are stored, and the API
returns no text field whatsoever. When enabled, the stored text is
already the engine's own *normalized* form (literals already stripped by
Postgres/MySQL themselves, never raw application SQL), truncated to
`DATABASE_QUERY_TEXT_MAX_BYTES` (default `4096`), and returned by the API
**only to an authenticated Admin** — a Member's response omits the field
entirely, regardless of the capture setting. Raw, unnormalized query text
is never captured, stored, or transmitted anywhere in this step.

## 8. Locks and waits

`LockMetrics{Waiting, Blocked}` are counts; `SessionInfo` (PID, database,
user, duration, state, wait_event_type, wait_event, application_name,
blocking PIDs) is the per-session detail, admin-gated at the handler
layer (`GET .../connections` and `.../locks` only include the
`sessions`/`blocked_sessions` array for `user.IsAdmin()`). No code path
anywhere in this step can call `pg_terminate_backend`, `KILL`, or any
session/query-cancellation command.

## 9. Replication

`ReplicationDetail{Status, LagSeconds, ReplicaCount}` — `Status` is a
coarse `NOT_CONFIGURED | HEALTHY | UNKNOWN` label computed by the adapter
from whether replication data could be read at all; WARNING/CRITICAL
severity from an actual lag value is decided centrally by
`ComputeDatabasePerformanceHealth` and `DatabaseDeepMetricsService.syncRecommendations`
against the same >10s threshold Step 12 already used, now finally fed by
real deep-collected data (Step 12's own fast-cycle replication-lag check
was never actually reachable — no fast adapter populated that field).

## 10. Storage / growth monitoring

`ComputeGrowthRate` (`database_performance_math.go`) derives bytes/day
from the first and last of up to 7 days of Step 12's own
`database_metric_snapshots.database_size_bytes` history — never a
duplicate size column, never computed from fewer than two samples spanning
at least an hour. `DATABASE_GROWTH_HIGH` fires when the projected 7-day
growth percentage (`growth_bytes_per_day * 7 / current_size * 100`)
exceeds `DATABASE_GROWTH_WARNING_PERCENT`. VM filesystem usage
(`GET .../storage`'s `vm_filesystem` field, from Step 6's own
`monitoring_snapshots`) is always reported *separately* from database
size — never implied to be the same number (spec #72).

## 11. Health and reasons

`ComputeDatabasePerformanceHealth` (`database_performance_health.go`)
layers Step 13's deep evidence (blocked-session count, cache hit ratio,
replication lag, query p95 latency) on top of Step 12's exact
`ComputeDatabaseHealth` verdict, returning `(HealthStatus, []string
reasons)` — e.g. `["Connection utilization is 86%.", "2 session(s) are
blocked.", "Query p95 latency is 1800ms."]` — never a single misleading
numeric score (spec #55/#123).

## 12. Recommendations

Eight new types (migration `022`'s `recommendations.type` extension):
`DATABASE_SLOW_QUERY`, `DATABASE_HIGH_QUERY_LATENCY`,
`DATABASE_LOCK_CONTENTION`, `DATABASE_LOW_CACHE_HIT`,
`DATABASE_HIGH_TEMP_IO`, `DATABASE_GROWTH_HIGH`,
`DATABASE_REDIS_EVICTIONS`, `DATABASE_REDIS_BLOCKED_CLIENTS`.
Deliberately **not** duplicating Step 12's existing
`DATABASE_CONNECTION_PRESSURE`/`DATABASE_MEMORY_PRESSURE`/
`DATABASE_REPLICATION_LAG`/`DATABASE_HIGH_ERROR_RATE` with
near-synonymous new type strings — spec #58 itself warns against more
than one recommendation for the same underlying issue, so those four
conditions keep their Step 12 identity and only genuinely new conditions
get new types here. All reuse the exact same
`UpsertRecommendationBySource`/`ResolveRecommendationBySource`
infrastructure (Step 7), deduplicated by `source_type` + the database
instance's own UUID.

## 13. Metric retention

`database_deep_metrics` and `database_metric_snapshots` share
`DATABASE_METRICS_RETENTION_DAYS` (Step 12's existing variable);
`database_query_metrics` — "can be high-volume" (spec #18) — has its own,
separately configurable `DATABASE_QUERY_METRICS_RETENTION_DAYS`.
`DatabaseRetentionService.Cleanup` (extended, not replaced) runs all
three deletes once a day; never touches `database_instances`,
`database_credentials`, `database_discovery_runs`, or `audit_logs`.

## 14. Deep vs. fast metrics

`DATABASE_METRICS_INTERVAL` (15s, unchanged) still governs Step 12's
cheap, frequent common metrics; `DATABASE_DEEP_METRICS_INTERVAL` (default
60s) is a new, independent, much slower cadence for expensive query
ranking / lock / replication / storage-growth collection —
`DatabaseDeepMetricsScheduler` is a structurally separate worker pool
(`DATABASE_DEEP_METRICS_WORKERS`, default 2) from
`DatabaseMetricsScheduler`. A deep-cycle failure (e.g. `pg_stat_statements`
unavailable) never touches `connection_status`/`health_status` — those
remain the fast cycle's exclusive responsibility (spec #79's isolation
requirement).

## 15. WebSocket streaming

`GET .../performance/stream` (`database_performance_stream.go`) mirrors
Step 12's metrics stream exactly: one shared collector (both caches),
authorization checked once at connection time, every tick reads
`DatabaseMetricsCache` + `DatabaseDeepMetricsCache` only — never a new SSH
command, never a per-viewer collector.

## 16. Authorization

Every new endpoint follows Step 12's exact pattern: `vm.view` plus
database-belongs-to-VM (`GetDatabaseInstanceForVM`), 404-not-403 on any
failure. Nothing in Step 13 is Admin-only at the router level — there is
no mutation to gate — but query text and per-session PID-level detail are
gated *inside* the handler via `user.IsAdmin()` (spec #96/#97's prepared,
not-yet-grantable `database.query_details`/`database.connection_details`
permission concept, enforced the same pragmatic way Step 11's
`vm.reboot` was: the permission exists in spirit, but the Admin-role
bypass is what actually gates it, rather than a full grant-management UI).

## 17. Security

- **No SQL/command console anywhere** (verified — see [§20](#20-known-limitations)):
  no endpoint in this project accepts a `query`/`command`/`redis_command`
  field; every monitoring query is a Go string constant.
- **No session/query termination**: no code path calls
  `pg_terminate_backend`, `KILL <connection>`, `CONFIG SET`,
  `FLUSHALL`/`FLUSHDB`, or any MongoDB command beyond
  `serverStatus`/`getProfilingStatus`/`rs.status`/ping.
- **Query text never in logs**: `RemoteExecutor` logging stays generic;
  no audit event or application log line ever includes
  `normalized_text`/raw SQL.
- **Bounded everything**: query list (25 default / 100 max), connection
  list (50/200), lock list (50/200), session snapshot (50 rows per
  cycle) — never an unbounded result set.

## 18. Monitoring overhead

Deep collection is a small, fixed number of read-only queries per engine
per 60s cycle (Postgres: 3 round trips; MySQL/MariaDB: 2; MongoDB: 1;
Redis: 1 — reuses the fast cycle's own `INFO` call, no extra round trip
at all). `DatabaseConnectionLimiter` caps total simultaneous fast+deep
connections at `DATABASE_MONITOR_MAX_CONNECTIONS` (default 3) regardless
of configured worker counts. `database_monitoring_health`
(`GET .../performance`'s `fast_collector`/`deep_collector` fields) tracks
`last_success_at`/`last_failure_at`/`last_duration_ms` per tier per
instance, so a stuck collector is visible without ever being confused
with the database itself being unreachable.

## 19. Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `DATABASE_SLOW_QUERY_MS` | `1000` | A query's average latency above this is `DATABASE_SLOW_QUERY`; also the p95 threshold for `DATABASE_HIGH_QUERY_LATENCY`. |
| `DATABASE_LONG_RUNNING_QUERY_SECONDS` | `60` | Session duration threshold for "long-running" classification (display-only; not yet a distinct recommendation type). |
| `DATABASE_QUERY_METRICS_RETENTION_DAYS` | `7` | Retention specifically for `database_query_metrics` (can be high-volume). |
| `DATABASE_DEEP_METRICS_INTERVAL` | `60s` | Deep-cycle collection cadence. |
| `DATABASE_DEEP_METRICS_WORKERS` | `2` | Deep scheduler worker pool size. |
| `DATABASE_MONITOR_MAX_CONNECTIONS` | `3` | Cap on simultaneous fast+deep monitoring connections combined. |
| `DATABASE_QUERY_TEXT_CAPTURE` | `false` | Whether normalized (never raw) query text is ever stored. |
| `DATABASE_QUERY_TEXT_MAX_BYTES` | `4096` | Truncation bound when capture is enabled. |
| `DATABASE_CACHE_HIT_WARNING_PERCENT` / `_CRITICAL_PERCENT` | `95` / `90` | Cache hit ratio thresholds (Postgres/MySQL/MariaDB only). |
| `DATABASE_LOCK_WARNING_COUNT` | `3` | Blocked-session count threshold for `DATABASE_LOCK_CONTENTION`. |
| `DATABASE_ALERT_COOLDOWN` | `15m` | Reserved for a future notification channel (see [§20](#20-known-limitations)) — recommendation flapping is currently prevented by hysteresis (distinct warn/resolve conditions), not a timer. |
| `DATABASE_GROWTH_WARNING_PERCENT` | `20` | Projected 7-day storage growth percentage threshold. |

Reused unchanged from Step 12: `DATABASE_METRICS_INTERVAL`,
`DATABASE_METRICS_WORKERS`, `DATABASE_METRICS_RETENTION_DAYS`,
`DATABASE_CONNECTION_TIMEOUT`, `DATABASE_QUERY_TIMEOUT`.

## 20. Known limitations

- **MySQL/MariaDB replication lag** is not implemented: `SHOW REPLICA
  STATUS`/`SHOW SLAVE STATUS` output shape varies too much across
  versions to parse reliably in this pass; `Replication.Status` stays
  `UNKNOWN` for these engines rather than risk a wrong parse.
- **MongoDB cross-member replication lag** is not computed: `rs.status()`
  member `optimeDate` is a BSON date mongosh serializes as a nested
  object, not a plain value; PRIMARY/SECONDARY state and replica count
  are reported, lag is not.
- **Redis latency percentiles** are not collected: `LATENCY LATEST`'s
  nested-list text output has no version-stable, simply-parsed shape, and
  meaningful data requires an admin to have already configured
  `latency-monitor-threshold` (which this step never does automatically,
  per spec #51). Documented as absent rather than guessed.
- **Percentiles are an approximation**: `latency_p50/p95/p99_ms` are
  computed across the population of query-fingerprint *average*
  latencies collected in one deep cycle (`ComputeLatencyPercentiles`),
  not a true per-execution latency histogram — most engines don't expose
  one without extra extensions. Labeled as such in the API response
  field names (`latency_p95_ms` on the deep-metrics rollup, not a claim
  of per-execution precision).
- **`DATABASE_ALERT_COOLDOWN`** is configured but not yet wired to a
  notification channel, because this project has none beyond the
  `recommendations` table itself (no email/push/webhook integration
  exists to "cool down"); flapping is already prevented by the
  warn/resolve hysteresis every threshold check uses.
- **UI tabs**: the spec's per-database "Tabs: Overview / Performance /
  Queries / Connections / Locks / Replication / Storage" are implemented
  as sequential page sections on the existing database detail page
  (`/vms/:vmId/databases/:databaseId`) rather than a literal tabbed
  widget, and Connections detail is folded into the Overview section's
  existing connection card rather than a separate section — a scope
  reduction for implementation time, not a missing capability: every
  backend endpoint listed in spec #88-93 is implemented and IDOR-tested
  independently of how the current frontend arranges them.
- **Live verification against real running database engines** (spec
  #145-149's PostgreSQL/MySQL/MariaDB/MongoDB/Redis test-case list) was
  not performed in this development environment — no SSH-reachable test
  VM/container with any of these five engines installed was available.
  Verification here is unit tests for every pure parsing/math/health
  function (parsePgDeepScalars, parseMySQLDigestRows,
  parseMongoDeepMetrics, parseRedisDeepMetrics, ComputeGrowthRate,
  ComputeLatencyPercentiles, ComputeDatabasePerformanceHealth, …) plus
  full HTTP-layer integration tests (IDOR across all 14 new endpoints,
  query-text Admin/Member visibility, capability gating, no-fake-data
  before any deep cycle has run) against a real Postgres-backed
  application database — see the Step 13 delivery summary for what
  remains before production use against each engine.
