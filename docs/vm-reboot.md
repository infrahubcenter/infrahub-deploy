# Controlled VM Reboot (Step 11)

The second and last component in this project that can actually change a
remote VM (the first being Step 10's update execution). Reboot **never**
happens automatically — not because `reboot_required` became `true`, not
after a successful update, not on any schedule. It happens only when an
authenticated ADMIN explicitly requests it, confirms a strong warning
dialog, and the backend independently re-verifies the VM is actually
ready.

## 1. Reboot architecture

```
Update completed (Step 10) → reboot_required = true → Admin opens the VM
→ sees "Reboot Required" → clicks [Reboot VM] → explicit confirmation
dialog → POST /api/vms/:id/reboot {"confirmation": true} → revalidate
(precheck) → transactional claim (locks BOTH update and reboot
exclusivity for this VM) → async worker → connect → detect privilege →
detect systemctl → send the backend-chosen reboot command → expect SSH
disconnect → wait → reconnect with backoff → multi-signal verify (boot
ID, uptime, kernel, OS, storage, Docker, containers, packages,
reboot-required) → rediscover → SUCCESS / PARTIAL / FAILED / TIMEOUT /
UNKNOWN
```

`POST /api/vms/:id/reboot` never blocks for the reboot's duration — the
transactional claim is a few fast DB round trips, returning `202` with an
`operation_id` immediately. Everything after runs on
`RebootExecutionWorker` (`internal/services/reboot_execution_worker.go`),
a bounded goroutine pool identical in shape to Step 10's
`UpdateExecutionWorker`.

Reused wholesale, never duplicated: `SSHService`/`RemoteExecutor` (Step
5), `DetectPrivilegeMode`/`PrivilegeMode` (Step 10), and
`VMDiscoveryService`/`VMMonitoringService`/`PackageService`/
`DockerDiscoveryService`/`OSUpdateService` (Steps 5-9) for every
pre/post-reboot check.

## 2. Authorization

`vm.reboot` is a new permission (`internal/services/identity.go`), seeded
into the catalog (`cmd/seed/main.go`) but **deliberately never added to
`grantableVMPermissions`** (`access.go`) — like `vm.execute`/`vm.update`
before it, it exists for forward compatibility but is never actually
grantable to a Member. `AuthorizationService.CanAccessVM` bypasses to
`true` unconditionally for `user.IsAdmin()` before checking any grant, so
in practice: ADMIN can always reboot an existing VM, MEMBER never can,
regardless of what an admin might try to grant. Every reboot-scoped
handler calls `CanAccessVM(ctx, user, vmResourceID, PermVMReboot)` for
symmetry with every other VM-scoped permission check in this project, even
though the grant path is closed — the frontend role is never trusted
(`RequireAuthentication` resolves the role fresh from the database on
every request, matching every other endpoint since Step 3).

## 3. Prechecks

`RebootExecutionService.RunPrecheck` (used both by the standalone `POST
/api/vms/:id/reboot/precheck` and internally by `RequestReboot`/`Run`)
checks: SSH configured, VM reachable, no update operation running, no
reboot already in progress, current/available kernel (informational),
reboot-required state, Docker daemon status, and disk usage — never sends
any command that could change VM state. `RequestReboot` also rejects
outright (before ever touching the VM) a request for a VM that doesn't
report `reboot_status = REQUIRED`, unless the admin explicitly chose
`reason=ADMIN_REQUEST` (a deliberate manual reboot of a healthy VM,
supported but shown with a distinct, more emphatic warning in the UI).

## 4. Operation state machine

`reboot_operations.status`: `PENDING → PRECHECK → REBOOTING →
WAITING_FOR_VM → RECONNECTING → VERIFYING → SUCCESS | PARTIAL | FAILED`,
with `TIMEOUT`/`UNKNOWN`/`INTERRUPTED` reachable from the waiting/
reconnecting/verifying phases, and `CANCELLED` reachable only from
`PENDING`/`PRECHECK` (`internal/services/reboot_operation_state.go`).
Cancellation is refused (`409`) once the reboot command has been sent —
the VM is already rebooting, and no unsafe process-killing is ever
attempted.

## 5. Reconnect strategy

After sending the reboot command, the worker waits `REBOOT_INITIAL_WAIT`
(default `10s`), then attempts reconnects with a fixed backoff sequence
(`10s, 15s, 20s, 30s, 45s, 60s`, capped at the last value for any further
attempt), up to `REBOOT_MAX_RECONNECT_ATTEMPTS` (default `12`) or until
`REBOOT_TIMEOUT` (default `10m`) elapses, whichever comes first — never
an unbounded retry loop, never a connection storm. If the VM never
reconnects, the operation becomes `TIMEOUT`, never `FAILED` — a timeout
means "we don't know," not "we know it broke."

## 6. Verification logic (never fabricate success)

`RebootExecutionService.captureSnapshot`/`verifyAndRecord`
(`internal/services/reboot_execution_run.go`) capture a real, live
"before" snapshot immediately before sending the reboot command, and a
real "after" snapshot immediately after reconnecting, then compare —
persisting one `reboot_verification_results` row per signal (spec's 10
`check_type` values: `SSH`, `BOOT_ID`, `UPTIME`, `OS`, `KERNEL`,
`STORAGE`, `DOCKER`, `CONTAINERS`, `PACKAGES`, `REBOOT_REQUIRED`). The
overall outcome uses multiple signals, never one alone:

- **Boot ID** (`/proc/sys/kernel/random/boot_id`) is the strongest
  signal a real boot cycle occurred — unchanged boot ID is always
  `FAILED`, never waved through.
- **Uptime** (`/proc/uptime`) corroborates: it must have decreased
  (reset), or it's a `WARNING`.
- **Kernel** is only *critical* (able to fail the whole operation) when
  `reason = KERNEL_UPDATE` — a manual `ADMIN_REQUEST` reboot expects the
  *same* kernel to still be running, while a kernel-update reboot expects
  a *different* one; if it's still the old one, the exact message is
  "New kernel is installed but the VM is still running the previous
  kernel."
- **OS/Docker/Containers/Reboot-required** are corroborating checks only
  — a mismatch here is `WARNING`, producing `PARTIAL`, never `FAILED` on
  its own.
- Final status: any critical check `FAILED` → `FAILED`; any critical
  check `UNKNOWN` (couldn't be read) → `UNKNOWN` (never `SUCCESS` for an
  unverified requirement); any non-critical `WARNING` → `PARTIAL`;
  otherwise `SUCCESS`.

`POST /api/reboot-operations/:id/verify` (admin-only) re-runs this exact
comparison on demand — reconstructing the "before" values from what was
already persisted as `expected_value` on each check — without ever
sending another reboot command or changing `operations`/`reboot_operations`
status beyond the verification rows themselves.

## 7. Before/after comparison

Every `reboot_verification_results` row carries a real `expected_value`
(the pre-reboot/target value) and `actual_value` (the real post-reboot
observation) — the frontend's comparison table renders these directly,
never inventing a value. Downtime is calculated as `disconnected_at →
reconnected_at` (or `→ completed_at` if reconnection never happened),
shown as "Downtime: Xm Ys"; if that can't be determined, the UI shows the
verification duration instead rather than fabricating a number.

## 8. Partial/failure handling

`PARTIAL` means the VM genuinely rebooted (boot ID changed, SSH restored)
but at least one non-critical check came back `WARNING` — e.g. Docker
didn't come back up, or fewer containers are running than before (Step
11 explicitly never auto-restarts a container — that remains a distinct,
not-yet-implemented Docker management operation). `FAILED` means a
critical check failed outright. Neither is ever automatically retried;
an admin can request `[Retry Verification]` (read-only) or start an
entirely new reboot operation from the VM page.

## 9. Cross-operation exclusivity

A VM cannot have an update operation and a reboot operation active at
the same time, in either order:

- `RebootExecutionService.RequestReboot`'s transactional claim
  (`GetActiveOperationForResourceLocked` then
  `GetActiveRebootForResourceLocked`, both inside one `Store.WithTx`)
  rejects a reboot if an update is running.
- `UpdateExecutionService.RequestExecution`'s claim was extended
  (`internal/services/update_execution_service.go`) to also check
  `GetActiveRebootForResourceLocked` before creating an update operation,
  rejecting execution if a reboot is in progress.
- Both checks happen inside the same transaction as the row's own
  creation — a real database-level lock (`FOR UPDATE`), not a UI-only
  guard, exactly matching Step 10's `MAX_CONCURRENT_UPDATES` precedent.

`RunPrecheck`'s own reboot-side check accepts an `excludeRebootOperationID`
parameter for the same reason Step 10 needed one for updates: by the time
the worker's own `PRECHECK` step re-runs this check, the operation it
belongs to already exists and is itself non-terminal, so without
excluding it, every reboot would immediately "conflict" with itself. This
exact self-conflict bug was caught live during Step 10 and is now a
standing pattern reused here from the start.

## 10. Command generation and privilege

`BuildRebootCommand` (`internal/services/reboot_command.go`) is a pure
function: `(hasSystemctl bool, privilege PrivilegeMode) -> (command,
ok)`. It prefers `systemctl reboot` when the VM has systemd (detected via
`command -v systemctl`, the same detection idiom Step 7 established),
falling back to the bare `reboot` command otherwise, with a privilege
prefix applied exactly like Step 10's `BuildExecutionCommand`: nothing
for `DIRECT_ROOT`, `sudo -n ` for `SUDO_NOPASSWD`, and outright rejection
for `UNSUPPORTED` (never an interactive sudo password prompt). There is
no `{"command": ...}` field anywhere in the reboot request shape — the
frontend can only send `confirmation` and an optional `reason`.

## 11. VM operational state

A new `vms.operational_state` column (`ONLINE`/`OFFLINE`/`REBOOTING`/
`UPDATING`/`UNKNOWN`) is deliberately kept separate from monitoring's
health state (computed from real metrics) and from `connection_status`
(a raw SSH-attempt outcome) — it answers "what is this application doing
to this VM right now," not "is it healthy" or "did the last SSH attempt
succeed." Set to `REBOOTING` when the reboot command is sent, `ONLINE`
immediately on successful reconnect (regardless of what verification
finds afterward), and `UNKNOWN` if the VM never reconnects. `RecordConnectionOutcome`
itself is intentionally never modified to special-case an in-progress
reboot — every expected disconnect and failed reconnect attempt during
the wait window still writes `connection_status=FAILED`/`resources.status=OFFLINE`
exactly as it always has; `operational_state` is the separate signal the
UI uses to show "Rebooting" instead of "Offline" during that window.

## 12. Kernel verification

The single most safety-critical comparison: for a `KERNEL_UPDATE` reboot,
the running kernel *must* differ from the pre-reboot kernel, or the
operation is `FAILED` with the exact message "New kernel is installed
but the VM is still running the previous kernel." — never silently
accepted as success just because SSH came back.

## 13. Docker verification

Docker's own installed/running/version state and a running/stopped
container count (via the pre-existing `GetDockerSummaryByVM` query, Step
8) are compared before/after. Fewer running containers than before is a
`WARNING` (containers do not automatically restart after a VM reboot,
and this project never attempts to start/stop/restart one as a side
effect of a reboot — that remains entirely out of scope here).

## 14. Package verification

Post-reboot, `PackageService.Scan` runs once (reused, never duplicated)
to confirm the package inventory is still readable; this is a "can we
still see package state" check, not a re-verification of specific
package versions — Step 10's own `update_operation_results` already owns
that for the update that necessitated the reboot in the first place.

## 15. Before/after state and reboot-required resolution

`OSUpdateService.Scan` (Step 9, extended) now also upserts/resolves a
`REBOOT_REQUIRED` recommendation (`syncRebootRecommendation`,
`internal/services/os_update_service.go`) every time it runs — whether
triggered by Update Center's own scan, Step 10's post-update
rediscovery, or Step 11's post-reboot verification. Deduplicated via the
same `source_type`/`source_id` unique-index pattern every other Step 7
recommendation uses, keyed to the VM's own resource ID, so a VM can never
accumulate more than one live `REBOOT_REQUIRED` recommendation.

## 16. Failure handling

SSH-unreachable-before-reboot, sudo-unavailable, an update already
running, a reboot already running, and the VM simply never coming back —
every one of these is handled explicitly and results in a clear,
non-generic status (`FAILED`/`TIMEOUT`/`CONFLICT`), never a silent hang
and never an automatic second reboot attempt.

## 17. Audit

Twelve new actions (`internal/services/audit.go`): `REBOOT_REQUESTED`,
`REBOOT_PRECHECK_STARTED`, `REBOOT_PRECHECK_FAILED`,
`REBOOT_COMMAND_SENT`, `REBOOT_DISCONNECTED`, `REBOOT_RECONNECT_STARTED`,
`REBOOT_RECONNECTED`, `REBOOT_VERIFICATION_STARTED`, `REBOOT_COMPLETED`
(covers both `SUCCESS` and `PARTIAL` outcomes), `REBOOT_FAILED`,
`REBOOT_TIMEOUT`, `REBOOT_VERIFICATION_RETRIED`. Metadata carries
`user_id`/`vm_id`/`reboot_operation_id`/`reason`/`status` — never SSH
keys, passwords, tokens, or credential contents.

## 18. Security

- **Never accepts a raw command**: `POST /api/vms/:id/reboot` accepts
  exactly `{"confirmation": true, "reason": "..."}` — no `command` field
  exists anywhere in this shape.
- **Explicit, distinct confirmation**: the frontend requires a checked "I
  understand the VM will temporarily become unavailable" box before the
  confirm button is enabled — this is a second, independent
  authorization from anything Step 10's Approve/Execute flow does.
- **Admin-only end to end**: every mutating endpoint
  (`reboot`/`cancel`) is `requireAdmin` at the router; every read checks
  `CanAccessVM(..., PermVMView)`, returning `404` (never `403`) for an
  unauthorized VM.
- **No shell-injection surface**: `BuildRebootCommand` takes a bool and a
  `PrivilegeMode`, nothing else — there is structurally no string input
  anywhere in its signature for a caller to inject through.

## 19. Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `REBOOT_WORKERS` | `2` | Worker pool size for dequeuing reboot operations. |
| `MAX_CONCURRENT_VM_OPERATIONS` | `3` | Cap on simultaneously *executing* reboot operations — a new, deliberately separate config from Step 10's `MAX_CONCURRENT_UPDATES`, named for the general operation-engine direction without retrofitting Step 10's already-tested worker. |
| `REBOOT_TIMEOUT` | `10m` | Overall wall-clock budget from disconnect to a confirmed reconnect before giving up (`TIMEOUT`). |
| `REBOOT_INITIAL_WAIT` | `10s` | Fixed wait after sending the reboot command before the first reconnect attempt. |
| `REBOOT_MAX_RECONNECT_ATTEMPTS` | `12` | Hard cap on reconnect attempts, independent of `REBOOT_TIMEOUT`. |

`UPDATE_LOG_MAX_BYTES` is reused unchanged for reboot log truncation
(Step 10's per-operation log-size budget); `SSH_CONNECT_TIMEOUT`/
`SSH_COMMAND_TIMEOUT` are reused unchanged for connecting and for every
short, fixed verification command this step runs.
