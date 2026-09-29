# Controlled Database Operations & Admin Remediation (Step 14)

Step 13 only **observes and recommends**. Step 14 lets an Admin actually
act on a standalone database — but only through a small, closed set of
backend-defined, hardcoded operation templates. There is no SQL console,
no arbitrary Redis/MongoDB command, no shell access, and no code path
anywhere in this project that turns client-supplied text into something
executed against a database.

Flow: **Recommendation → Review → Operation Plan → Confirmation → Execute
→ Live Output → Result → Audit.**

## 1. Architecture

```
Next.js → Go API (Admin-only) → DatabaseOperationService
    → RunPrecheck (existence/capability/params/reachability/no-conflicting-op)
    → DatabaseOperationWorker (bounded pool, MAX_CONCURRENT_DATABASE_OPERATIONS)
    → database_operation_adapter.go (per-engine capability table +
       ValidateOperationParams/PreviewOperation/ExecuteOperation)
    → DirectDatabaseConnection (Step 13's own driver, direct TCP/TLS,
       no SSH -- pgx / go-sql-driver/mysql / mongo-driver / go-redis)
```

`database_operations` (migration 024) is the single source of truth for
an operation's plan, status, live log transcript, and result — mirroring
`reboot_operations`' shape (Step 11) closely: `operation_type`, `status`,
`requested_by`, `reason`, `parameters` (jsonb), `command_preview`,
`recommendation_id`, lifecycle timestamps, `result_summary`/
`result_detail`/`error_summary`, `health_before`/`health_after`. A
companion `database_operation_logs` table is the live-output transcript
(`SYSTEM`/`STDOUT`/`STDERR` lines), streamed over the same
gorilla/websocket + ticker-polls-the-store pattern used everywhere else
in this project (Docker container stats, update/reboot operation logs).

## 2. Status state machine

```
WAITING_CONFIRMATION --confirm--> PENDING --worker picks up--> RUNNING --> SUCCESS
        |                            |                            |
        +-------- cancel ------------+                            +--> FAILED
                                                                    +--> TIMEOUT
```

`CANCELLED` is only reachable from `WAITING_CONFIRMATION`/`PENDING` — once
`RUNNING`, the backend-defined command may already be in flight and there
is no safe way to abort it mid-execution (spec: "Never automatically kill
sessions"). All of `SUCCESS`/`FAILED`/`CANCELLED`/`TIMEOUT` are terminal;
a failed operation can only be retried by creating a brand new plan
(`POST .../retry`), which still requires its own fresh confirmation — this
project never automatically retries a destructive operation.

## 3. What's actually implemented, per engine

Each adapter declares its own supported operations
(`database_operation_adapter.go`'s `GetOperationCapabilities`) — nothing
is forced onto an engine that can't safely support it:

| Engine | Operations |
| --- | --- |
| PostgreSQL | Cancel Query (`pg_cancel_backend`), Terminate Session (`pg_terminate_backend`), `VACUUM`, `ANALYZE` |
| MySQL / MariaDB | Cancel Query (`KILL QUERY`), Terminate Session (`KILL`) |
| MongoDB | Kill Operation (`killOp`) |
| Redis / Valkey | Kill Client Connection (`CLIENT KILL ID`), Background Save (`BGSAVE`) |

`RESTART`, `REPLICATION_ACTION`, `CONFIG_CHANGE`, and `UPGRADE` exist in
the schema's `operation_type` enum and the Go `DatabaseOperationType`
constants for forward compatibility (the spec explicitly asks for a
"controlled workflow for future... upgrades" and safety-gated future
replication actions), but **no adapter declares them supported today** —
this project has no shell/SSH access to a standalone database's host, so
there is no honest way to restart its process or perform a provider
upgrade yet. The frontend never renders a button for an operation type a
database's own capability list doesn't include.

Every executed command is a fixed template with at most one
backend-validated parameter (`target_id` — a PID/connection id/opid/client
id, always sourced from an already-displayed session list, e.g. Step 13's
Connections/Locks views — never freely typed). `ValidateOperationParams`
rejects anything else before a connection is ever opened.

## 4. Validation before execution

Both `RequestOperation` (creating the plan) and `Run` (right before
actually executing, re-checked closer to real time) verify:

1. Caller is authenticated and is an Admin (`database.operations.*` is
   Admin-only, full stop — like `vm.reboot`, there is no grant path around
   it; a Member gets a plain 403).
2. Database exists and isn't soft-deleted.
3. Operation type is genuinely supported for this database's engine.
4. Parameters are well-formed for that operation.
5. The database is reachable (a real `TestDirectConnection` call).
6. No other operation is already `PENDING`/`RUNNING` for this database
   (`GetActiveDatabaseOperationForDatabaseLocked`, row-locked inside a
   transaction — the same claim pattern as Step 11's reboot exclusivity).
7. Explicit confirmation exists (`POST .../confirm` is a separate step
   from creating the plan).

## 5. Timeout and operation-queue exclusivity

`DATABASE_OPERATION_TIMEOUT` (default `300s`) bounds the entire
validate-connect-execute-verify window inside `Run`; exceeding it while
the backend command hasn't returned yet marks the operation `TIMEOUT`,
never leaves it `RUNNING` forever. `MAX_CONCURRENT_DATABASE_OPERATIONS`
caps the worker pool's semaphore, entirely independent of the VM-side
reboot/update worker caps. A crash-recovery sweep at startup
(`RecoverInterruptedDatabaseOperations`) marks any operation still
non-terminal from an unclean prior shutdown as `FAILED` with a message
telling the Admin to verify the database's state manually — never
resumes or re-sends a command.

## 6. Post-operation verification

After a command executes successfully, `Run` reconnects, collects fresh
fast metrics, and computes a health label the same way Step 13's
monitoring does (`ComputeDatabaseHealth`) — both `health_before` and
`health_after` are persisted. The operation's terminal status is still
`SUCCESS` either way (the command itself didn't fail), but
`result_summary` distinguishes "Operation successful; database is
healthy." from "...but the database requires attention (health:
WARNING/CRITICAL)." — never silently hidden.

## 7. Audit

Every operation emits `DATABASE_OPERATION_REQUESTED` /
`_CONFIRMED` / `_STARTED` / `_COMPLETED` / `_FAILED` / `_CANCELLED` audit
events (who, what, target database, when, outcome) — never a secret,
never the target database's credentials, never raw query text beyond the
fixed `command_preview` template.

## 8. API

```
GET    /api/databases/:id/operations
GET    /api/databases/:id/operations/capabilities
POST   /api/databases/:id/operations/preview
POST   /api/databases/:id/operations
GET    /api/databases/:id/operations/:operationId
POST   /api/databases/:id/operations/:operationId/confirm
POST   /api/databases/:id/operations/:operationId/cancel
POST   /api/databases/:id/operations/:operationId/retry
GET    /api/databases/:id/operations/:operationId/logs
GET    /api/databases/:id/operations/:operationId/logs/stream
GET    /api/database-operations                  # global, Admin-only
```

`GET /api/recommendations` also gained an optional `?resource_id=`
filter and now returns `resource_type` (`VM` | `DATABASE`) alongside
`resource_id`/`resource_name` — Step 13's database-specific
recommendation types (`DATABASE_LOCK_CONTENTION`, `DATABASE_SLOW_QUERY`,
etc.) were, before this step, silently rejected by a stale `CHECK`
constraint on `recommendations.type` left over from before Step 13's
standalone rework; migration 024 fixed that alongside adding this step's
own tables, and the dashboard's Member-scoping was extended to also
consult database access (it previously only ever checked VM access, so a
Member could never see a database recommendation they were otherwise
fully authorized to view).

```bash
curl -b cookies.txt http://localhost:8080/api/databases/<id>/operations/capabilities
curl -b cookies.txt -X POST http://localhost:8080/api/databases/<id>/operations/preview \
  -d '{"operation_type":"VACUUM","parameters":{}}'
curl -b cookies.txt -X POST http://localhost:8080/api/databases/<id>/operations \
  -d '{"operation_type":"VACUUM","parameters":{},"reason":"scheduled maintenance"}'
curl -b cookies.txt -X POST http://localhost:8080/api/databases/<id>/operations/<operationId>/confirm
curl -b cookies.txt http://localhost:8080/api/databases/<id>/operations/<operationId>
```

## 9. What's deliberately not implemented

- Arbitrary SQL, Redis, MongoDB, or shell command execution — none, ever.
- Automatic replication failover/promotion/resync/repair — the spec
  explicitly reserves any future replication operation for an Admin's
  explicit, individual initiation; nothing here does it automatically.
- Automatic retry of a failed or destructive operation.
- Database restart or provider-API-driven upgrade — no adapter declares
  either supported (see §3); the schema/type system leaves room for a
  future step to add a real, safe implementation without a redesign.
- A generic "maintenance window" scheduler UI — the `operation_type`/
  validation plumbing would support one being layered on top later, but
  no enforcement of a configured allowed-operations time window exists
  yet.
