# Security Hardening (Step 20)

The final step of the current implementation plan: a review-and-harden
pass over Steps 1–19, not a new feature. This document records what was
audited, what was already correct and is only verified here, and exactly
what changed. See `docs/authorization.md` for the authorization model
itself (unchanged by this step) and `docs/deployment.md` for
configuration/health-check/backup guidance.

## 1. Method

Every major subsystem was reviewed against the existing code (never
against assumptions about what "should" exist): authentication, RBAC/IDOR,
secret storage, SSH/SQL/S3 command construction, SSRF exposure, WebSocket
authorization, controlled operations (database remediation, VM reboot,
update execution), alerting, database schema/migrations, and the Next.js
frontend. Findings below are grouped by outcome, not by subsystem, so it's
clear what actually required a change.

## 2. Already correct — verified, not modified

These were reviewed in depth and found to already meet the Step 20 bar;
no code changed for them. Re-reviewing the specific mechanism referenced
is the way to confirm a claim below, not just this document.

- **Authentication** (`internal/services/auth.go`, `password.go`,
  `token.go`): Argon2id password hashing, HS256 JWTs with no sensitive
  claims, refresh-token rotation with theft detection (reusing an
  already-revoked token revokes every refresh token for that user),
  `RequireAuthentication` re-loading live user state on every request so
  a disabled account or role change takes effect on the very next
  request rather than at token expiry.
- **RBAC / IDOR discipline** (`internal/services/authorization.go`,
  `docs/authorization.md`): deny-by-default for VM/Database/Object
  Storage alike, the 404-vs-403 disclosure policy, and the Step 18
  extension to Database/Object Storage — all already covered by
  dedicated tests (`internal/server/idor_policy_test.go`,
  `permissions_test.go`, `users_role_test.go`).
- **Controlled operations** (database remediation, VM reboot, update
  execution): admin-only end to end (router-level *and* in-service
  re-checks), explicit confirmation required before execution, per-
  resource exclusivity plus a global concurrency cap, bounded timeouts,
  crash recovery that marks an interrupted operation `INTERRUPTED` rather
  than resuming it, full audit logging, and a closed, backend-defined
  command allowlist with no client-supplied-command path anywhere.
- **Alerting** (`internal/services/alert_engine.go`,
  `notification_service.go`): deduplication (one open alert per rule, not
  one per evaluation cycle), a real notification cooldown, condition-clear
  auto-recovery, acknowledge/suppress without deletion, and Member
  visibility scoped through the same resource-authorization merge every
  other endpoint uses.
- **WebSocket/SSE authorization**: all 6 streaming endpoints require
  authentication (cookie or bearer, never a URL query-string token that
  could leak into access logs), check the same per-resource authorization
  the equivalent REST endpoint uses *before* upgrading, and clean up their
  goroutine/ticker on client disconnect. See §5 for the one gap found.
- **Secret handling in responses/logs/audit**: every API response uses a
  hand-written DTO that never includes a private key, password, or secret
  key; `TestConnection`/`Test` endpoints classify errors instead of
  forwarding raw ones; audit logging explicitly documents "never a
  secret" and every checked call site complies; no logging statement
  anywhere passes a credential value.
- **Command/query construction**: every SSH command sent to a VM is
  either a fixed template or built from names validated against an
  allowlist regex *before* being executed (with one exception, fixed —
  see §3); every SQL query against a standalone database uses bound
  parameters for values and a regex-validated (or catalog-cross-checked)
  identifier allowlist for table/column names, never raw string
  concatenation of untrusted input; no endpoint anywhere accepts a raw
  shell/SQL/Redis/MongoDB command from a request body.
- **Database indexes/constraints**: every time-series table already has
  the composite `(resource_id, captured_at)`-shaped index its query
  pattern needs; foreign keys and duplicate-grant-prevention unique
  constraints are correctly in place (one gap found and closed — see §3).
- **Reliability**: graceful shutdown, background-worker context
  cancellation, and monitoring's "one offline VM doesn't break the
  dashboard" partial-failure handling were all already correct (see
  `docs/deployment.md` §4).
- **Frontend**: branding is already centralized and correct
  (`frontend/src/lib/branding.ts`), route protection happens server-side
  (`frontend/src/proxy.ts`) before any client-side role refinement, no
  secret or token is ever stored in `localStorage`/`sessionStorage` (auth
  relies entirely on httpOnly cookies), and no leftover mock data,
  `console.log`, or `Lorem ipsum` placeholder was found.

## 3. Fixed in this step

- **Command-injection gap in update verification**
  (`internal/services/update_execution_run.go`, `verifyPackages`):
  `POST /api/update-operations/:id/verify` built its version-check SSH
  command by concatenating package names read back from
  `update_plan_items` — sourced, ultimately, from a VM's own
  `dpkg-query`/`rpm -qa` output — *without* the
  `ValidatePackageNamesForExecution` allowlist check the actual
  execution path (`Run()`) already applies. A compromised or malicious VM
  could in principle report a package name containing shell
  metacharacters. Fixed by validating names before building the command;
  on failure, the live re-query is skipped and every item reports
  `UNKNOWN` (the same outcome as if the SSH call itself had failed) —
  never a change in behavior for any real, well-formed package name.
- **Webhook URL SSRF** (`internal/services/validate.go`,
  `notification_policy_service.go`): a notification policy's webhook URL
  had zero validation — not even a scheme check. Added
  `validateWebhookURL`: requires `http`/`https`, and rejects loopback/
  link-local targets, which specifically closes off the cloud-metadata
  endpoint every major provider exposes at a link-local address
  (`169.254.169.254`, `169.254.170.2`) — the one class of target that can
  never be a legitimate webhook. Ordinary private network ranges (10.x,
  172.16.x, 192.168.x) are deliberately left unblocked, since a
  self-hosted internal webhook relay is a legitimate target for this
  application.
- **DSN construction robustness** (`internal/services/
  direct_database_adapter.go`): `postgresConnString`/`mysqlDSN` built
  connection strings via raw `fmt.Sprintf`, unlike `mongoConnString`
  (which already escapes via `mongoURIEscape`) — a username/password
  containing `@`, `:`, or `/` could corrupt the resulting DSN.
  `postgresConnString` now builds via `net/url` (`url.UserPassword`);
  `mysqlDSN` now builds via the driver's own `mysql.Config.FormatDSN()`.
  Both are the officially correct construction method for their driver,
  not a hand-rolled escaping scheme.
- **Implicit-only error redaction** (`internal/services/
  package_service.go`, `safeErrorMessage`): relied entirely on pgx/
  go-sql-driver's own error messages happening not to embed a DSN — an
  external, implicit guarantee, not something this codebase enforced
  itself. `safeErrorMessage` now explicitly redacts any embedded
  `scheme://user:pass@` fragment before a message is ever logged, audited,
  or returned to a caller, closing the gap regardless of driver behavior.
- **`credentials` table missing a uniqueness constraint**
  (`migrations/029_credentials_unique_per_type.sql`):
  `CredentialService.ConfigureCredential`'s delete-then-insert transaction
  already prevents duplicate `(resource_id, credential_type)` rows in the
  normal case, but nothing at the schema level stopped a narrow race
  between two concurrent configure requests. Added
  `UNIQUE(resource_id, credential_type)`, after first de-duplicating any
  pre-existing rows down to the most recent per pair (a no-op on a clean
  or already-consistent database).
- **HTTP hardening middleware** (new:
  `internal/middleware/{ratelimit,security}.go`): the router previously
  had no request body size limit and no rate limiting anywhere, and set
  no security response headers.
  - `MaxBody` (`MAX_REQUEST_BODY_BYTES`, default 2 MiB) wraps every
    request in `http.MaxBytesReader`.
  - `RateLimiter.LimitByIP` (`LOGIN_RATE_LIMIT_ATTEMPTS`/`_WINDOW`,
    default 10 per 5m) applies only to `POST /api/auth/login` — the one
    unauthenticated endpoint that accepts a secret guess; refresh/logout
    require an already-issued cookie and don't need it.
  - `SecurityHeaders` sets `X-Content-Type-Options: nosniff`,
    `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer` always, and
    `Strict-Transport-Security` when `COOKIE_SECURE` is true (mirroring
    that flag's own existing "are we in a production/HTTPS context"
    signal).
- **`.env.example` completeness** (`backend/.env.example`): the Database
  monitoring/performance/operations (Steps 12–14) and Alerts/Notifications
  (Step 16) variable blocks were missing entirely, even though
  `internal/config/config.go` has always read them with defaults. Added,
  documented in the same style as every existing block.
- **Repository cleanup**: removed five stray compiled binaries
  (`*.exe` build artifacts left in `internal/server/` and `backend/`) and
  one leftover `go test -v` output log file — debug/build artifacts, not
  source.
- **Deployment additions**: `backend/Dockerfile`, `frontend/Dockerfile`,
  `docker-compose.prod.yml`, `next.config.ts`'s `output: "standalone"`,
  and `GET /api/live` (see `docs/deployment.md`) — none of these existed
  before Step 20; local development (`go run`/`npm run dev`, the existing
  Postgres-only `docker-compose.yml`) is unaffected by any of them.
- **Stale documentation**: `README.md`'s Roadmap section still claimed
  object-storage monitoring and non-VM authorization enforcement were
  "planned for later steps," even though Steps 17/18 had already shipped
  both. Corrected, and README sections for Object Storage, Users/
  Permissions, and the Monitoring Dashboard (previously undocumented at
  the README level, though each has its own detailed doc) were added.

## 4. Investigated, found benign — no change made

- **Migration numbering gap (021/022 missing)**: confirmed real
  (`020_vm_reboot.sql` → `023_standalone_database_monitoring.sql`), traced
  to two internal "Step" numbers (12 and 15) with no surviving migration
  file — most likely an abandoned/superseded early draft, since no Go code
  anywhere references the `database_instances` table `023`'s own comment
  implies once existed. `goose` (the migration runner) sorts and tracks by
  version number and does not require contiguous numbering — confirmed
  harmless by reading `cmd/migrate/main.go` directly, not just assumed.
- **N+1 permission/metric lookups for Database/Object Storage** in
  `GET /api/my-access` and the monitoring dashboard's Resources endpoint
  (`internal/handlers/myaccess.go`, `monitoring_dashboard.go`): each
  authorized resource triggers its own `EffectiveDatabaseAccess`/
  `EffectiveObjectStorageAccess` call (2–3 queries) rather than a single
  batched query, unlike the VM path in the same functions, which already
  batches correctly. Left unfixed deliberately: batching it safely means
  mirroring the VM path's dedicated batch-query functions across the
  authorization service for two more resource types, which is meaningful,
  separate engineering work against a security-critical code path, not a
  hardening-pass edit — and the real-world impact is bounded, since a
  typical deployment has far fewer configured databases/object storage
  entries than VMs. Recommended as a follow-up, not attempted here.

## 5. Known, accepted limitations

Documented in `README.md`'s Roadmap section (per-process rate limiter,
WebSocket mid-stream revocation, frontend dark mode not wired up) rather
than duplicated here — see that section for the reasoning behind each.
