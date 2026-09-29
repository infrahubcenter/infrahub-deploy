> **Superseded.** Step 13 replaced this VM-attached, SSH-based database
> model entirely with **standalone** database monitoring (a database is
> now a first-class resource under a Project, connected directly via
> TCP/TLS — never a VM child, never reached over SSH). Everything below
> describes the removed architecture and no longer matches the code. See
> the README's "Database Monitoring" and "Database Performance
> Monitoring" sections for the current design, and
> [database-operations.md](database-operations.md) for Step 14's
> controlled remediation layer built on top of it. This file is kept only
> for historical context and will be removed or rewritten in a future
> pass.

# Database Discovery + Monitoring (Step 12) — historical, superseded by Step 13

**Strictly read-only.** Nothing in this step can create, drop, or alter a
database or user; grant or revoke a privilege; run a client-supplied SQL
statement, MongoDB command, or Redis command; restart a database; change
its configuration; or touch its data in any way. Every query this step
issues is backend-defined and hardcoded. Those capabilities are explicitly
reserved for a future step.

## 1. Architecture

```
Next.js → Go API → DatabaseDiscoveryService/DatabaseMetricsService/
DatabaseConnectionService → SSHService (Step 5, unchanged) → VM →
psql / mysql / mongosh / redis-cli (over the VM's own loopback)
```

A database instance is a **child of a VM**, never an independent
top-level resource: `Project → Group → VM → Databases`, mirroring
`docker_containers`' relationship to `vms` (Step 8). The existing
placeholder `databases` table from Steps 2/4 (a top-level resource with an
`engine` check constraint) is left completely untouched — it models a
different, independent-resource shape than this step needs and may still
serve some future purpose; `database_instances` (migration `021`) is a
genuinely new table.

Supported engines today: PostgreSQL, MySQL, MariaDB, MongoDB, Redis.
ClickHouse, Elasticsearch, SQL Server, and Oracle are prepared for
(`DatabaseType` is a string enum, `AdapterForType` is a simple switch) but
not implemented.

## 2. The SSH-tunnel decision

The spec calls for preferring an SSH tunnel over exposing database ports
publicly (`Go Backend → SSH → VM → 127.0.0.1:5432`), "if practical." This
step's actual implementation reuses the exact same architecture Docker
discovery (Step 8) already established: run the engine's own CLI
(`psql`/`mysql`/`mongosh`/`redis-cli`) as a remote command over the
existing `RemoteExecutor.Execute`/SSH connection, rather than adding a new
Go-level database driver (`pgx`, `go-sql-driver`, `mongo-driver`,
`go-redis`) and a literal SSH port-forward. The database traffic never
leaves the VM's own loopback interface and never crosses the network as a
second connection — satisfying the "prefer a tunnel over a public port"
intent without a second connection mechanism or a second set of
credentials-in-memory-in-this-process concerns. This is the chosen
interpretation of the spec's "if practical" language; a literal
`net.Conn`-level tunnel remains possible in a future step if a driver
becomes necessary for functionality a CLI can't provide.

Password handling to the CLI: `PGPASSWORD=... psql ...` and
`MYSQL_PWD=... mysql ...` (via `env VAR=val cmd`, never on the command
line as a flag) for Postgres/MySQL/MariaDB; Redis via `redis-cli -a
'password'` (a standard, disclosed exposure — `redis-cli` has no
environment-variable password mechanism); MongoDB has no clean
environment-variable mechanism at all, so the password appears inside the
`mongodb://user:pass@host:port` connection-string argument passed to
`mongosh` — a known, disclosed limitation matching how real-world
ops scripts invoke `mongosh` today. None of these commands, nor their
output, are ever logged with the password intact — `RemoteExecutor`
truncates/logs commands generically, and no code path in this step writes
a raw connection string to `audit_logs` or application logs.

## 3. Database state model

Three independent state families, never conflated:

- **Service state** (`database_instances.status`): `NOT_INSTALLED |
  INSTALLED | RUNNING | STOPPED | UNAVAILABLE | AUTH_FAILED | CONNECTED |
  UNKNOWN` — what discovery observed about the binary/service on the VM.
- **Connection state** (`database_instances.connection_status`,
  `ConnectionTestStatus`): `CONNECTED | AUTH_FAILED | TIMEOUT | REFUSED |
  UNAVAILABLE | UNKNOWN` — the outcome of the most recent connectivity
  test or metrics-collection attempt. A database can be `RUNNING` yet
  `AUTH_FAILED` at the same time; these are never merged into one field.
- **Health state** (`database_metric_snapshots.health_status`,
  `HealthStatus`): `HEALTHY | WARNING | CRITICAL | UNKNOWN | OFFLINE` —
  rule-based, derived from real metrics plus the connection state (never a
  single misleading numeric score). `ComputeDatabaseHealth`
  (`internal/services/database_health.go`) maps every connection failure
  state to `OFFLINE`/`UNKNOWN` immediately, before any metric threshold is
  even evaluated.

"Installed" is never assumed from "running," and neither is assumed from
"reachable" or "authenticated" — `DetectResult{Installed, Running,
Version, Port, Host, ServiceName}` (`database_adapter.go`) reports each as
an independently-observed fact.

## 4. Discovery

`DatabaseDiscoveryService.DiscoverDatabases` (`internal/services/
database_discovery_service.go`) connects once via `SSHService`, then runs
every entry in `engineDetectors` (Postgres, the combined MySQL-family
detector, MongoDB, Redis) over that one connection, upserting a
`database_instances` row (natural key `vm_id, type, port`) for every
engine found installed, and soft-deleting (`status = NOT_INSTALLED,
deleted_at = now()`) any previously-discovered instance whose engine is no
longer detected. Every discovery run is recorded as one
`database_discovery_runs` row (`RUNNING → SUCCESS | PARTIAL | FAILED`,
with `databases_found` and a sanitized `error_summary`).

`DatabaseDiscoveryScheduler` (`internal/services/
database_discovery_scheduler.go`) is structurally identical to
`DockerDiscoveryScheduler`: a fixed worker pool (`DATABASE_DISCOVERY_WORKERS`,
default `2`) draining a buffered job channel on `DATABASE_DISCOVERY_INTERVAL`
(default `10m`), a `sync.Map` overlap guard so a VM is never scanned twice
concurrently, and a separate `ScanNow` manual-trigger path
(`POST /api/vms/:id/databases/scan`, admin-only) debounced to one call per
30 seconds per VM (`ErrDatabaseScanRateLimited`).

### Per-engine detection

- **PostgreSQL**: `command -v psql`/`postgres` existence, `psql --version`
  parsed by `ParsePostgresVersion`, and the real listening port found via
  `ss -ltn`/`netstat -ltn` (`ParseListeningPorts`/`FindListeningPort`)
  searched against the candidate `5432` — never assumed present as a
  default.
- **MySQL/MariaDB**: `detectMySQLFamily` runs one binary/port detection,
  then separately runs `mysqld --version`/`mariadbd --version` and parses
  the real output via `ParseMySQLFamilyVersion` for a literal `"MariaDB"`
  substring — MariaDB is never classified as MySQL merely because the
  `mysql` client command happens to also work against it (spec's explicit
  anti-pattern). This decision is made once, at detection time; the
  resulting `DatabaseType` (`MYSQL` or `MARIADB`) is then fixed for that
  instance's connection tests and metrics collection via
  `AdapterForType`.
- **MongoDB**: `mongod`/`mongosh` existence, version via
  `ParseMongoVersion`, port candidate `27017`.
- **Redis**: `redis-server`/`redis-cli` existence, version via
  `ParseRedisVersion`, port candidate `6379`.

## 5. Credentials

A dedicated `database_credentials` table (migration `021`, one row per
`database_instance_id`) rather than the generic `credentials` table —
that table's `resource_id` is a hard foreign key into `resources`, and a
`database_instances` row deliberately has no `resources` row of its own
(it's a VM child, not an independent resource). `DatabaseCredentialService`
(`internal/services/database_credential_service.go`) still reuses the
exact same `EncryptionService` (AES-256-GCM, Step 5, unchanged) for the
encrypted blob, honoring the spec's "use existing credential architecture"
via the shared encryption primitive.

A credential is configured by an admin (`POST /api/vms/:id/databases`, or
re-configuring the same instance) as `{username, password}` — the backend
never generates or infers one. The API never returns a password: `GET`
responses carry only `credential_username` and `credential_configured`
(`HasCredential`, which checks existence without decrypting). The intent
is a separate, least-privilege monitoring credential per spec (a
`pg_monitor`-equivalent role, a restricted MySQL user, MongoDB's built-in
`clusterMonitor`/read-only role, a scoped Redis ACL user) — the backend
has no way to enforce what privileges an admin's chosen credential
actually has, but no code path in this step ever requires or assumes
administrative privileges to function.

## 6. Connection testing

`DatabaseConnectionService.TestConnection` (`internal/services/
database_connection_service.go`, used by `POST /api/vms/:id/databases/
:databaseId/test`, admin-only) runs exactly one backend-defined, hardcoded
probe per engine (`SELECT 1`/`PING`/the driver's own ping) — the request
body is empty; there is no `{"query": ...}` field anywhere in this
project. The whole call (SSH connect + the one probe) is bounded by
`DATABASE_CONNECTION_TIMEOUT` (default `10s`); the probe command itself is
additionally bounded by `DATABASE_QUERY_TIMEOUT` (default `5s`) — two
distinct timeouts for two distinct things (overall budget vs. per-command
budget), not two names for the same value. Every outcome — including "no
credential configured" and "VM unreachable" — is a normal, persisted
`ConnectionTestStatus`, never an HTTP 500; only a genuine backend failure
(e.g. a database error while persisting the result) is a 500.

## 7. Metrics collection

`DatabaseMetricsService.CollectOne` (`internal/services/
database_metrics_service.go`) is the single per-instance collection cycle:
connect via SSH, run the adapter's one combined metrics query/command,
compute rates from the previous snapshot, classify health, persist one
`database_metric_snapshots` row, update the shared cache, and sync
recommendations. `DatabaseMetricsScheduler` (`internal/services/
database_metrics_scheduler.go`) runs this on `DATABASE_METRICS_INTERVAL`
(default `15s`) across `DATABASE_METRICS_WORKERS` (default `3`) workers,
keyed by **database instance ID** (not VM ID, since one VM can host
several monitored engines/instances independently), and only ever
enqueues instances with `monitoring_enabled = true`.

Common metrics (`CommonMetrics`, `database_metric_snapshots`' real
columns): connections, active connections, max connections, memory usage,
database size, operations/sec, transactions/sec, error count, uptime.
Every field is a pointer — absent means "could not be read," never a
fabricated zero. Engine-specific detail lives in `metric_details` (jsonb):
Postgres's cache hit ratio/deadlocks/locks/replication/long-running-query
count; MySQL/MariaDB's slow-queries-per-minute/replication lag; MongoDB's
replica set/primary/lag/collection and document counts; Redis's hit/miss
rate/key count. A `metric_details` field never includes secrets, query
text, connection strings, or tokens.

### Rate calculation (never treat a counter as a rate)

Postgres's `xact_commit`/`xact_rollback`, MySQL/MariaDB's `queries`/
`slow_queries`, MongoDB's opcounters, and Redis's
`total_commands_processed` are all cumulative counters. Each snapshot's
raw values are stored under a reserved `metric_details["_raw_counters"]`
key (never surfaced by the API — `sanitizeDatabaseDetails` in
`internal/handlers/database_instances.go` strips it from every response).
`DatabaseMetricsService.applyRates` computes `(current - previous) /
elapsed_seconds` against the prior snapshot's raw counters;
`detectRestart` recognizes any counter that decreased and resets the rate
baseline for that cycle rather than ever reporting a negative rate.

### Partial collection

`MetricsResult.Partial`/`Warning` carry the "some sub-metrics failed, but
not everything" case (spec's "not every database supports every metric");
the persisted `metrics_status` is `COMPLETE`, `PARTIAL`, or `FAILED` — the
frontend can distinguish "fully healthy data" from "some numbers are
missing" from "nothing could be collected this cycle," never silently
treating a partial result as complete.

## 8. Health classification

`ComputeDatabaseHealth` (`internal/services/database_health.go`) reuses
Step 6's exact `dimensionStatus` two-branch rule and `HealthStatus`
vocabulary. Connection percentage is only computed when both
`Connections` and a positive `MaxConnections` are known; memory percentage
only when both usage and a positive max-memory are known (Redis's
"unlimited maxmemory" case correctly never produces a fake percentage).
Thresholds are configurable (`DATABASE_CONNECTION_WARNING_PERCENT`/
`_CRITICAL_PERCENT`, `DATABASE_MEMORY_WARNING_PERCENT`/`_CRITICAL_PERCENT`)
and only ever applied to a metric that actually exists for that engine.

## 9. Recommendations

Seven new `recommendations.type` values (migration `021`'s `CHECK`
extension): `DATABASE_CONNECTION_PRESSURE`, `DATABASE_MEMORY_PRESSURE`,
`DATABASE_REPLICATION_LAG`, `DATABASE_DEADLOCKS`, `DATABASE_SLOW_QUERIES`,
`DATABASE_UNAVAILABLE`, `DATABASE_HIGH_ERROR_RATE`.
`DatabaseMetricsService.syncRecommendations` reuses Step 7's exact
`UpsertRecommendationBySource`/`ResolveRecommendationBySource` queries
directly — no new wrapper service — keyed by a `source_type` string
(e.g. `"database_connection_pressure"`) plus `source_id` = the database
instance's own UUID, giving natural WARNING → CRITICAL → RESOLVED
deduplication through the existing unique index. A recommendation is only
ever created from evidence the current metrics cycle actually produced;
`DATABASE_REPLICATION_LAG` specifically distinguishes "not configured"
(no recommendation) from "configured and lagging" (`> 10s`).

## 10. Retention

`DatabaseRetentionService` (`internal/services/database_retention.go`,
running daily) deletes `database_metric_snapshots` rows older than
`DATABASE_METRICS_RETENTION_DAYS` (default `7`) via
`DeleteDatabaseMetricSnapshotsBefore` — nothing else. `audit_logs`,
`database_instances`, `database_credentials`, and `database_discovery_runs`
are never touched by this job.

## 11. Live metrics

`DatabaseMetricsCache` (`internal/services/database_metrics_cache.go`)
mirrors `DockerMetricsCache` exactly: a `sync.RWMutex`-guarded map keyed
by database instance ID, written only by `DatabaseMetricsScheduler`, read
by both the REST `.../metrics/current` endpoint and the WebSocket stream
(`GET .../metrics/stream`, `internal/handlers/database_stream.go`, which
mirrors `docker_stream.go`'s `CheckOrigin`/read-goroutine-for-disconnect-
detection/ticker pattern exactly). One collector, N viewers sharing the
same cached sample — never a new SSH connection per viewer or per tick.

## 12. Metrics history

`GET .../metrics/history?range=15m|1h|6h|24h|7d` loads raw
`database_metric_snapshots` rows for the requested window and aggregates
them in Go (`aggregateDatabaseHistory`,
`internal/handlers/database_instances.go`) into at most 500 buckets,
averaging each numeric metric within a bucket and keeping the *worst*
health status seen in it (never silently dropping a `CRITICAL` sample by
only keeping a bucket's last value) — never returning millions of raw
15-second samples for a 7-day window.

## 13. API surface

| Method & path | Access |
| --- | --- |
| `GET /api/databases/summary` | any role, member-scoped to authorized VMs |
| `GET /api/vms/:id/databases` | any role, `vm.view` |
| `POST /api/vms/:id/databases` | admin only (configure) |
| `POST /api/vms/:id/databases/scan` | admin only |
| `GET /api/vms/:id/databases/:databaseId` | any role, `vm.view` |
| `PATCH /api/vms/:id/databases/:databaseId` | admin only (enable/disable monitoring) |
| `DELETE /api/vms/:id/databases/:databaseId` | admin only (soft-delete) |
| `POST /api/vms/:id/databases/:databaseId/test` | admin only |
| `GET /api/vms/:id/databases/:databaseId/metrics/current` | any role, `vm.view` |
| `GET /api/vms/:id/databases/:databaseId/metrics/history` | any role, `vm.view` |
| `GET /api/vms/:id/databases/:databaseId/metrics/stream` (WebSocket) | any role, `vm.view` |

## 14. Authorization & IDOR

Every database-scoped endpoint verifies, in order: the caller is
authenticated, the caller has `vm.view` on the VM in the URL (`404`, never
`403`, on failure — existence is never disclosed to an unauthorized
caller), and the requested database instance actually belongs to that VM
(`GetDatabaseInstanceForVM`'s `WHERE id = $1 AND vm_id = $2` — never a
bare lookup by database ID alone). `GET /api/databases/summary` scopes a
Member to exactly the VMs `AuthorizationService.GetUserVMAccess` returns,
identically to `RecommendationHandler.List` (Step 7); an Admin passes a
`nil` `resource_ids` slice, matched against `sqlc.narg` as
"unrestricted." Covered by `internal/server/database_instances_test.go`:
VM-A/database-A allowed, VM-A/database-from-VM-B denied, VM-B/database-B
for a member unauthorized on VM-B denied, nonexistent ID denied — the
same 404 in every denial case.

## 15. Security

- **No SQL/command console anywhere**: no endpoint in this project
  accepts a `query`/`command` field for a database instance; `Test` runs
  exactly one hardcoded probe.
- **Shell-injection prevention**: `shellQuote` (single-quote escaping with
  `'\''`) wraps every value interpolated into a generated CLI command;
  `ValidateDatabaseIdentifier` (a strict `^[A-Za-z0-9][A-Za-z0-9._-]*$`
  pattern) additionally validates the admin-supplied host and monitoring
  username before they're ever interpolated — unlike prior steps where
  every interpolated value was backend-sourced, an admin-supplied
  username/host is the one new input class this step introduces, so it
  gets an explicit allow-list check as its primary defense, on top of
  quoting.
- **Explicit engine command rejection**: no code path in this step can
  run `FLUSHALL`/`FLUSHDB`/`CONFIG`/`SHUTDOWN` (Redis), any DDL/DML
  statement (SQL engines), or any MongoDB command beyond the fixed
  `serverStatus`/`listDatabases`/ping calls — the commands sent are
  hardcoded string constants, not built from any request input.
- **No password ever returned**: every DTO in `internal/handlers/
  database_instances.go` includes only `credential_username`/
  `credential_configured`, never a password or encrypted blob.
- **No secrets in logs**: `RemoteExecutor` logging is generic (it doesn't
  echo full command lines with embedded env-var assignments in a way that
  surfaces a password); no code path in this step writes a raw connection
  string to `audit_logs`.

## 16. Known limitations

- MongoDB's password appears in the `mongosh` connection-string argument
  (Section 2) — a disclosed, standard limitation of `mongosh` itself, not
  unique to this implementation.
- The SSH-tunnel requirement is satisfied via CLI-over-SSH (Section 2)
  rather than a literal Go-level port-forward; revisit if a future engine
  genuinely requires a driver no CLI equivalent exists for.
- Docker-hosted database auto-discovery is prepared for (`runtime_type`
  `HOST`/`DOCKER`, nullable `container_id` on `database_instances`) but
  not implemented — every instance today is manually configured or
  detected as running directly on the VM's host OS.
- Live end-to-end verification against real running PostgreSQL/MySQL/
  MariaDB/MongoDB/Redis instances requires an SSH-reachable Linux test VM
  or container with sshd, which was not available in this development
  environment; verification here is unit tests for every pure
  parsing/rate/health function plus full HTTP-layer integration tests
  (authorization, IDOR, no-fake-data, no-secret-leak) against a real
  Postgres-backed application database. See the Step 12 delivery summary
  for the exact test list and what remains to be verified against live
  database engines before production use.

## 17. Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `DATABASE_DISCOVERY_INTERVAL` | `10m` | Background discovery scan cadence per VM. |
| `DATABASE_DISCOVERY_WORKERS` | `2` | Discovery scheduler worker pool size. |
| `DATABASE_METRICS_INTERVAL` | `15s` | Background metrics collection cadence per database instance. |
| `DATABASE_METRICS_WORKERS` | `3` | Metrics scheduler worker pool size. |
| `DATABASE_METRICS_RETENTION_DAYS` | `7` | How long `database_metric_snapshots` rows are kept. |
| `DATABASE_METRICS_STALE_AFTER` | `60s` | Age after which a cached/persisted sample is flagged `stale` in API responses. |
| `DATABASE_CONNECTION_WARNING_PERCENT` | `80` | Connection-utilization warning threshold. |
| `DATABASE_CONNECTION_CRITICAL_PERCENT` | `95` | Connection-utilization critical threshold. |
| `DATABASE_MEMORY_WARNING_PERCENT` | `80` | Memory-utilization warning threshold. |
| `DATABASE_MEMORY_CRITICAL_PERCENT` | `95` | Memory-utilization critical threshold. |
| `DATABASE_CONNECTION_TIMEOUT` | `10s` | Overall budget for one connect+check/collect cycle. |
| `DATABASE_QUERY_TIMEOUT` | `5s` | Per-remote-command budget within that cycle. |
