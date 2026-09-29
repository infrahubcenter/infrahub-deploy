# Update Execution Engine (Step 10)

The first step in this project that can actually change a remote VM.
Everything before this step (Steps 1-9) only ever observed VMs or produced
previews; this step adds one, tightly-controlled write path: an
Admin-approved, Admin-confirmed update plan (Step 9) can be executed,
producing a real `apt-get`/`dnf`/`yum` package upgrade over SSH. Every
control described below exists to keep that one write path safe,
auditable, and never accidental.

## 1. Execution architecture

```
Recommendation (Step 7) → Update Plan (Step 9, DRAFT→READY) → Admin reviews
command preview → POST .../execute {"confirmation": true} → Revalidate
(fresh prechecks, never trust an earlier approval) → Transactional claim
(lock plan, check no other operation is active for this VM, create
operation, plan → EXECUTING, commit) → Async worker dispatch → SSH connect
→ detect privilege (root vs sudo -n) → build the exact command → hash it →
execute with a bounded timeout, streaming output → verify each package's
real installed version → rediscover the VM (monitoring/packages/OS/Docker)
→ SUCCESS / PARTIAL / FAILED
```

The HTTP request that starts execution (`POST /api/update-plans/:id/execute`)
never blocks for the duration of the update — it does the transactional
claim synchronously (fast: a few DB round trips) and returns `202` with an
`operation_id` immediately. Everything after that runs on
`UpdateExecutionWorker`, a bounded goroutine pool
(`internal/services/update_execution_worker.go`) draining operation IDs
pushed onto a channel by the claim step.

Reused wholesale, never duplicated: `SSHService`/`RemoteExecutor` (Step 5),
`UpdatePlanService`'s prechecks (Step 9), `VMDiscoveryService`/
`VMMonitoringService`/`PackageService`/`DockerDiscoveryService`/
`OSUpdateService` (Steps 5-9) for post-update rediscovery.

## 2. Update plan lifecycle

`update_plans.status`: `DRAFT → READY → EXECUTING → COMPLETED | FAILED |
PARTIAL`, plus `CANCELLED`/`STALE` reachable at various points. `EXECUTING`
is a **lock**: once set, `CancelPlan` refuses (`ErrUpdatePlanExecuting`)
and no further mutation of the plan's selected packages/target
versions/command is possible. Only the execution engine itself, from
inside `settlePlanAndAudit`, ever moves a plan out of `EXECUTING` — never
an admin action.

`planStatusForOperation` maps the operation's real, evidence-based outcome
to the plan's final status: `SUCCESS → COMPLETED`, `PARTIAL → PARTIAL`,
everything else (`FAILED`/`CANCELLED`/`INTERRUPTED`) → `FAILED`. A plan is
never marked `COMPLETED` merely because the shell command exited 0 —
per-package verification is what actually decides this (§11).

## 3. Prechecks (revalidated immediately before execution)

`RequestExecution` calls `UpdatePlanService.ValidatePlan` fresh — the same
9-check report Step 9's `/validate` endpoint returns — immediately before
claiming the VM, never trusting an earlier `Approve`. A failure here marks
the plan `STALE` and returns `409` without ever touching the VM. The
worker's own first step (`PRECHECK`) runs the identical check again right
before connecting, since time can pass between the HTTP request returning
and the worker actually picking up the job.

## 4. Command generation

`internal/services/update_execution_command.go`'s `BuildExecutionCommand`
wraps Step 9's `UpdateCommandBuilder` (`os_update_command_builder.go`,
unchanged) additively:

- Base command from the existing builder (already whitelist-filters
  package names via `safePackageNamePattern`).
- Non-interactive flags appended so the command can never hang waiting on
  a stdin `RemoteExecutor` never supplies: `-y`/`--assume-yes`-equivalent
  for all three families, plus `env DEBIAN_FRONTEND=noninteractive` for
  APT (using the standalone `env` utility, not sudo's own
  environment-passthrough, which depends on `sudoers` `env_keep` and can
  silently fail).
- A privilege prefix (§7) applied last.

Preview strings shown before execution (`GetPlan`'s `proposed_command`,
Step 9, and `EstimatedExecutionCommand` for the confirmation dialog) are
never trusted as the executed command — the worker always regenerates the
real command itself from the plan's stored package selection and the
freshly-detected privilege mode, hashes it (§10), and only that hash/
command pair is ever sent over SSH.

## 5. Command validation (injection prevention)

Package names are validated against `safePackageNamePattern`
(`^[A-Za-z0-9][A-Za-z0-9+._:~-]*$`) both at plan-creation time (Step 9,
silently filtered for preview) and again at execution time via
`ValidatePackageNamesForExecution`, which **rejects the whole operation**
rather than silently dropping an unsafe name — a real, approved,
about-to-execute command must never silently differ from what was shown
to the admin. This is a whitelist, not an escaping scheme: every
character the spec calls out (`; & | $ \` > < ( ) newline`) is
structurally impossible to match the pattern, so no package name can
break out of the command string regardless of what a compromised/buggy
upstream package-name source might contain. Covered by
`TestValidatePackageNamesForExecution_RejectsInjectionAttempts`
(`internal/services/update_execution_command_test.go`), which feeds it
`"nginx; rm -rf /"`, `"nginx && whoami"`, `"$(whoami)"`, backtick-`whoami`,
newline-injection, pipes, and redirects — all rejected.

## 6. SSH execution

`RemoteExecutor.ExecuteStreaming` (`internal/services/remote_executor.go`)
is new: unlike the existing `Execute` (fully buffered, used by every
read-only discovery/monitoring/scan command), it invokes a callback once
per complete output line as it arrives, via a small `lineWriter` that
splits on `\n`. This lets the worker persist and broadcast output
incrementally instead of only after the whole command finishes. Every
other caller in the codebase keeps using the original buffered `Execute`
unchanged.

## 7. Sudo/privilege requirements

`internal/services/privilege.go`'s `DetectPrivilegeMode` runs two cheap,
read-only commands on the just-opened SSH connection: `whoami` (if
`root`, `DIRECT_ROOT`) then, if not root, `sudo -n true` (exit 0 →
`SUDO_NOPASSWD`; anything else → `UNSUPPORTED`). `-n` is
non-interactive-only — sudo never prompts for a password here. `UNSUPPORTED`
fails the operation immediately with "Configured SSH user requires an
interactive sudo password, which is not supported," before any update
command is ever built or sent. The detected mode is cached on
`vms.privilege_mode` for display only; it is **always** re-detected fresh
at execution time, never read back and trusted.

## 8. Async workers

`UpdateExecutionWorker` (`internal/services/update_execution_worker.go`)
mirrors the fixed-worker-pool-draining-a-channel shape established by
`PackageScanScheduler`/`DockerDiscoveryScheduler` (Steps 7-8), but is fed
by HTTP-created jobs (`Enqueue`) instead of a ticker. Two independent
limits: `UPDATE_WORKERS` (pool size — how many operations can be
dequeued/processed concurrently) and `MAX_CONCURRENT_UPDATES` (a
semaphore gating how many can actually be connected-and-running at once,
which may be smaller). Per-VM exclusivity needs no in-memory guard: the
database transactional claim (§9) already guarantees at most one
non-terminal operation per VM exists, so the pool can never be handed two
jobs for the same VM concurrently — different VMs run fully in parallel.

## 9. Operation locking (the database-level claim)

`GetActiveOperationForResourceLocked` (`sql/queries/update_execution.sql`)
row-locks (`FOR UPDATE`) any non-terminal (`PENDING`/`CONNECTING`/
`RUNNING`/`VERIFYING`) operation for a VM, called inside
`Store.WithTx` alongside `CreateUpdateOperation` and the plan's
`EXECUTING` transition — all inside one transaction, committed before any
SSH activity starts. Two concurrent `execute` requests for the same VM
therefore cannot both succeed: the second's `SELECT ... FOR UPDATE` either
finds the first's row (rejected with `ErrUpdateAlreadyExecuting`) or waits
on the row lock and then finds it. This is designed for future
multi-instance deployment — the database, not an in-memory mutex, is the
authoritative lock (an in-memory mutex could still be layered on top as a
local optimization, but none is needed today since Postgres already
serializes this correctly).

## 10. Live execution logs

`GET /api/update-operations/:id/logs/stream` is a WebSocket, reusing
Step 8's exact established pattern (`gorilla/websocket`, the
`Hijack()`-fixed logging middleware, `CheckOrigin` against
`FRONTEND_ORIGIN`, a client-disconnect-detecting read goroutine). Unlike
Docker's stream (which polls a single latest-value cache every tick),
this one polls `operation_logs` for rows past a per-connection
`sequence_number` cursor (`ListOperationLogsAfter`) — an append-only
tail rather than a latest sample — and closes itself with a final
`{"type":"done"}` frame once the operation reaches a terminal status.
The worker writes to `operation_logs` incrementally as
`ExecuteStreaming`'s callback fires (§6), bounded by
`UPDATE_LOG_MAX_BYTES`: once an operation's persisted output exceeds that
budget, further lines are dropped from the database (a single `SYSTEM`
note announces the truncation) — this only affects what's stored, never
the exit code or downstream verification logic. `GET
/api/update-operations/:id/logs` returns the full persisted history in
one response for a client that doesn't need the live tail (e.g. loading
an already-completed operation).

## 11. Verification (never trust the exit code)

After the update command completes (or the connection drops — see §13),
the worker re-connects if needed and queries the VM directly for each
selected package's actual installed version (`dpkg-query -W`/`rpm -q`,
scoped to just the selected package names, reusing the exact
`ParseDpkgQuery`/`ParseRPMQA` parsers Step 7 already wrote). Each package
gets an `update_operation_results` row: `VERIFIED` (installed version
equals the plan's target version), `FAILED` (still equals the pre-update
version — nothing changed), or `UNKNOWN` (installed something else, or
the version couldn't be read at all — never guessed). The operation's
final status is entirely evidence-based:

```
verified == total        → SUCCESS
0 < verified < total      → PARTIAL
verified == 0              → FAILED
```

`POST /api/update-operations/:id/verify` (admin-only) re-runs this same
check on demand — useful after an `INTERRUPTED` operation — without ever
re-executing the update command or changing `operations.status`.

## 12. Partial failures

A `PARTIAL` operation means some but not all selected packages verified
as updated. The UI shows "N selected / N succeeded / N failed" from
`update_operation_results`; the linked plan becomes `PARTIAL`. No
automatic retry is ever attempted — an admin must review the results and
logs, then create a new plan for whatever remains (§16).

## 13. SSH disconnect handling

If `ExecuteStreaming` returns a transport-level error (not a clean exit —
the SSH session itself failed), the worker does **not** assume the update
failed: the remote command may still be running or may have already
completed. It proceeds straight to the `VERIFY` step, attempting one
reconnect. If reconnect succeeds, verification runs exactly as in §11 and
the real per-package evidence decides the outcome. If reconnect also
fails, the operation becomes `INTERRUPTED` (never `FAILED` — that would
claim certainty the backend doesn't have) with a message that the final
VM state must be verified manually. No second update command is ever
automatically launched.

## 14. Reboot behavior

Reboot state is only ever detected and reported, never acted on — no code
path in this project runs `reboot`, `shutdown`, or `systemctl reboot`.
After a successful update, `OSUpdateService.Scan` (Step 9, unchanged)
re-reads the VM's actual reboot-required evidence and, for a kernel
package specifically, compares running vs. installed kernel version. The
UI shows "Reboot Required" plus a `[Reboot VM]` button that intentionally
does nothing yet — a future step's responsibility.

## 15. Security controls

- **Never accept a raw command from the frontend.** `POST
  /api/update-plans/:id/execute` accepts exactly `{"confirmation": true}`
  — no `command` field exists anywhere in this request shape, checked by
  `TestCommandBuilders_NeverExecuteAnything`-style static analysis
  extended in Step 9 and the explicit injection tests in §5.
- **Explicit second confirmation**, distinct from Step 9's `Approve`: the
  frontend's Execute dialog requires a checked "I understand and want to
  execute this update" checkbox before the confirm button is enabled —
  Approve alone can never trigger execution.
- **Admin-only, end to end**: every mutating endpoint
  (`execute`/`cancel`/`verify`) is wrapped in `requireAdmin` at the
  router; `CanAccessVM` + `PermVMView` gates every read; a Member's
  request for an unauthorized VM's operation gets `404`, never `403`
  (the VM's existence is never disclosed).
- **Command hash** (`operations.command_hash`, SHA-256 of the exact
  executed string) lets an auditor confirm the executed command matches
  what was generated — not a secret, an integrity check.
- **No secrets ever logged**: SSH private keys/passphrases, credential
  ciphertext, JWTs, refresh tokens, sudo passwords, registry credentials,
  and database passwords are never written to `operation_logs`,
  `operations.summary`, or any audit metadata — the executed command
  itself never contains a secret (package names and flags only).
- **No shell-injection surface** (§5).

## 16. Audit events

Eight new actions in `internal/services/audit.go`:
`UPDATE_EXECUTION_REQUESTED`, `UPDATE_PRECHECK_STARTED`,
`UPDATE_PRECHECK_FAILED`, `UPDATE_EXECUTION_STARTED`,
`UPDATE_EXECUTION_COMPLETED`, `UPDATE_EXECUTION_FAILED`,
`UPDATE_EXECUTION_PARTIAL`, `UPDATE_VERIFICATION_COMPLETED`. Metadata
carries `user_id`/`vm_id`/`update_plan_id`/`operation_id`/`status` (and,
where relevant, `package_count`) — never command output, never
credentials.

## 17. Retry policy: never automatic

`FAILED`/`PARTIAL`/`INTERRUPTED` operations are never retried by any code
path in this project. To try again, an admin must create a new plan
(Step 9) — which snapshots a fresh `current_version`/`target_version`
from live package data — and go through the full revalidate → confirm →
execute flow again. Startup crash recovery (`RecoverInterruptedOperations`,
called once in `main.go` before the HTTP server or worker pool start
accepting work) marks any operation left `PENDING`/`CONNECTING`/`RUNNING`/
`VERIFYING` by an unclean prior shutdown as `INTERRUPTED` and its plan
`FAILED` — it never resumes or re-executes anything.

## 18. Production safety

Before any update can run against a real VM: Admin authentication +
explicit `{"confirmation": true}` + a fresh precheck pass (§3) +
fresh-at-execution-time revalidation + the database operation lock (§9) +
a command hash (§4) + an audit event (§16) — no path skips any of these.
`MAX_PACKAGES_PER_UPDATE_PLAN` bounds how large a single plan can be;
`MAX_CONCURRENT_UPDATES` bounds how many VMs can be mid-update
simultaneously, protecting against a mass accidental rollout even if many
plans were approved in advance. OS release upgrades are deliberately
**not** wired to any execution path in this step — `BuildOSReleaseCommand`
remains preview-only (Step 9); a dedicated `OS_RELEASE_UPGRADE` operation
type with its own additional confirmation is left for a future step.

## 19. Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `UPDATE_WORKERS` | `2` | Worker pool size for dequeuing update operations. |
| `MAX_CONCURRENT_UPDATES` | `2` | Global cap on simultaneously *executing* operations across all VMs. |
| `MAX_PACKAGES_PER_UPDATE_PLAN` | `100` | Plans larger than this are rejected at execution time. |
| `UPDATE_COMMAND_TIMEOUT` | `30m` | Timeout for the package-manager command itself — much longer than `SSH_COMMAND_TIMEOUT` (30s), which is for fast, fixed discovery commands only. |
| `UPDATE_LOG_MAX_BYTES` | `2097152` (2MiB) | Per-operation cap on persisted log bytes; live streaming is unaffected, only DB storage is bounded. |

`SSH_CONNECT_TIMEOUT`/`SSH_COMMAND_TIMEOUT` are reused unchanged for
connecting and for the short fixed commands (privilege detection,
verification queries, rediscovery) this step also runs.
