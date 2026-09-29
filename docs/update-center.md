# Update Center: OS/Kernel/Reboot Detection & Update Planning (Step 9)

Read-only OS release, kernel, and reboot-requirement detection alongside
Step 7's existing package-update data, plus admin-only update *planning*
(select packages, preview the exact command that would apply them,
review a pre-update checklist) — never update *execution*. Extends
Step 5's SSH infrastructure, Step 7's `packages`/`package_updates`/
`recommendations` schema (never duplicated), and the pre-existing
`operations` table (a Step-2 placeholder already shaped for exactly this
purpose). **This step never runs `apt upgrade`, `apt install`,
`dnf update`, `yum update`, a reboot, or any other system-mutating
command — anywhere, under any circumstance.** Execution is Step 10.

## 1. Architecture

```
VM → Package Discovery (Step 7, reused) → OS Update Detection → Package
Update Detection (Step 7, reused) → Kernel Detection → Reboot Detection →
Recommendation Engine (Step 7, reused) → Update Plan → Admin Review →
Step 10 Execution
```

OS/kernel/reboot detection is deliberately **not** a new ticking
scheduler — it rides on Step 7's existing `PackageScanScheduler` cadence
(`PACKAGE_SCAN_INTERVAL`, default 6h). `PackageScanScheduler.
SetOSUpdateService` wires `OSUpdateService.Scan` in as a follow-up step
after every package scan cycle, scheduled or manual (`POST .../updates/
refresh` calls the same `ScanNow` Step 7 already rate-limits/overlap-
guards, then runs the OS-update scan). No second scheduler, no second
worker pool.

## 2. OS update detection

`OSUpdateService.Scan` (`internal/services/os_update_service.go`) re-reads
`/etc/os-release` fresh on every scan — the same "detect independently,
never trust a stale flag" discipline Step 8 established for Docker daemon
status — rather than reusing Step 5's discovery snapshot.

**Distribution release upgrades** (Ubuntu only): `do-release-upgrade -c`
is Ubuntu's own read-only check — it is documented to never perform the
upgrade itself, only report whether one is available (`"New release
'24.04' available."`). No universal, safe, read-only equivalent exists
for Debian or the RPM family without additional tooling (e.g. `leapp`,
which itself makes system changes just by being installed) — those
report `UNKNOWN`, never a guessed value.

`release_channel` (`stable`/`LTS`/`non-LTS`/`unknown`) is inferred from
real evidence only: Ubuntu's own `VERSION` field literally contains the
substring `"LTS"` for LTS releases. Every non-Ubuntu distribution reports
`unknown` — there is no equivalent signal to read.

`update_type` is `RELEASE` when `do-release-upgrade -c` finds a new
release; every other case (already latest, or the check couldn't run) is
`status: UNKNOWN`, never a guessed `PATCH`/`MINOR`. There is no safe,
read-only mechanism to distinguish an in-place point-release bump
(e.g. `24.04.3` → `24.04.4`) from the aggregate effect of ordinary
package updates — `/etc/os-release`'s `VERSION` field is fixed at image
build time and does not track this live, so `PATCH`/`MINOR` are never
fabricated from any command this step runs.

`os_updates` is one upserted row per VM (mirrors `vms.docker_daemon_
status`/`package_manager`'s "current known state" shape), not a history
table — reshaped from a Step-2 placeholder in migration `018_update_
center.sql` to `current_version`/`available_version`/`update_type`/
`status`/`release_channel`, dropping the placeholder's stale `severity`/
`reboot_required`/`recommendation_status` columns (severity now derives
from real package-update evidence at recommendation-creation time;
reboot state is its own concept, see §4).

## 3. Kernel detection

One new command per scan: `uname -r` (the running kernel). Everything
else reuses Step 7's already-synced `packages`/`package_updates` data —
**no duplicate package-update records are ever created** (spec's explicit
requirement). Kernel package names are matched by convention per family:

| Family | Pattern | Version source |
|---|---|---|
| APT | `linux-image-<version>` (excludes the `linux-image-generic` meta-package) | The package **name**'s own version suffix — directly comparable to `uname -r`'s output, since Debian/Ubuntu's naming convention guarantees they match character-for-character |
| DNF/YUM | `kernel` / `kernel-core` | The package's `installed_version` column |

The newest installed kernel-package version and the newest *pending*
kernel-package update (if any) are compared, via `CompareKernelVersions`
(`internal/services/os_update_parse.go`) — a purpose-built numeric-segment
comparator for kernel ABI strings like `6.8.0-40-generic`, not Debian/RPM
package-version syntax, since a kernel ABI string isn't one. If the
newest known kernel differs from the running one, `vms.kernel_available`
is set and reboot detection (§4) treats this as its own independent
signal, separate from any OS-level reboot-required indicator.

## 4. Reboot detection

Two independent kinds of evidence, combined (never a guess when neither
is available — `UNKNOWN`, not `NOT_REQUIRED`):

1. **Kernel mismatch** (§3): the installed kernel differs from the
   running one → `REQUIRED`, reason `"Kernel update is installed but
   requires reboot to become active."` (spec's exact wording).
2. **Distribution-native indicator**, read-only:
   - **Debian/Ubuntu**: `/var/run/reboot-required` (existence) and
     `/var/run/reboot-required.pkgs` (contents, if present) — spec's
     exact named paths.
   - **RPM family**: `needs-restarting -r` — exit `0` = no restart
     needed, `1` = needed. Absent tooling (no `yum-utils`/`dnf-utils`)
     → `UNKNOWN`, never guessed.

`vms.reboot_status`/`reboot_reason` are the VM's single current-known
state (like `docker_daemon_status`), re-detected and overwritten each
scan — never a history table.

## 5. Update plans

`update_plans`/`update_plan_items` (migration `018_update_center.sql`).
Step 9 only ever produces `DRAFT`, `READY`, or `CANCELLED` — `APPROVED`/
`EXECUTING`/`COMPLETED`/`FAILED`/`STALE` are declared in the schema for
Step 10's execution flow but **no Step 9 code path ever sets them**.

- `POST /api/vms/:id/update-plans` (`UpdatePlanService.CreatePlan`)
  creates a `DRAFT` plan. Every selected package is re-validated
  server-side: must belong to this VM, must currently have an active
  update. **The client-submitted `target_version` is never trusted or
  stored** — the backend always resolves and snapshots the database's own
  `package_updates.available_version` at creation time (spec's explicit
  "Do not trust target version from frontend"). The snapshot (`update_
  plan_items`) protects the plan from silently drifting if a later scan
  changes the package's metadata (§7).
- `POST /api/update-plans/:id/validate` runs the full precheck (§6) as a
  **pure read-only diagnostic** — it never mutates `status`.
- `POST /api/update-plans/:id/approve` re-runs the same precheck as a
  precondition and, only if every blocking check passes, transitions
  `DRAFT` → `READY`. **This never executes anything** — approval means
  "an admin reviewed this," not "run it."
- `POST /api/update-plans/:id/cancel` moves any non-terminal plan to
  `CANCELLED`.

## 6. Pre-update checklist

`UpdatePlanService.vmLevelPrechecks`/`informationalPrechecks`. Only a
small, deliberately narrow set of checks can actually **block** a plan
from becoming `READY` (`PrecheckFail`) — everything else is `WARN`/`INFO`
and always displayed but never blocking, per spec's explicit "do not
automatically block every update based on health" and "do not define an
arbitrary minimum [disk space] without configuration":

| Check | Can block? | Evidence |
|---|---|---|
| SSH credential configured | Yes | `HasSSHCredential` |
| VM reachable | Yes | A plain SSH connectivity test (open + immediately close — mirrors `POST .../connection-test`, never runs a command) |
| Package manager detected | Yes | `vms.package_manager` |
| No conflicting update operation | Yes | `operations` WHERE `operation_type IN ('OS_UPDATE','PACKAGE_UPDATE') AND status = 'RUNNING'` (§8) |
| Every selected item still available, no duplicates | Yes | Re-checked against current `package_updates` |
| Package metadata freshness | No (WARN) | `package_discovery_runs`' latest `completed_at` vs `UPDATE_METADATA_STALE_AFTER` |
| VM monitoring health | No (WARN) | `DeriveDisplayHealth` (Step 6, reused) |
| Disk space | No (INFO only) | Latest `vm_filesystems` root-mount row — raw numbers displayed, no pass/fail threshold |
| Reboot state | No (INFO only) | `vms.reboot_status`/`reboot_reason` |

## 7. Stale plan detection

`ValidatePlan` compares each snapshotted item's `target_version` against
the package's **current** `package_updates.available_version`. A mismatch
(or the update disappearing entirely) sets `stale: true` in the response
— surfaced as a `WARN` precheck item and a dedicated `stale_items` list,
never silently re-resolved or hidden. `STALE` is declared in the schema's
status enum for a future step to actually transition into; Step 9 only
ever *reports* staleness.

## 8. Concurrency lock (prepared, not yet used)

**This project already has an `operations`/`operation_logs` table pair**
(migration `010_operations.sql`, a Step-2 placeholder) with exactly the
shape spec's `update_operations` describes as "new" — `operation_type`
already includes `'OS_UPDATE'`/`'PACKAGE_UPDATE'`, and it already has
`command_preview`/`started_at`/`completed_at`/`exit_code`/`summary`.
Rather than create a duplicate, parallel table (this step's own "do not
recreate existing architecture" instruction), migration `018` adds a
nullable `operations.update_plan_id` link instead. `GetRunningUpdate
OperationByResource` is the query Step 10's concurrency lock will use;
Step 9 itself never creates a `RUNNING` row, so this check always passes
today, but the query and the precheck slot for it already exist.

## 9. Command generation — never execution

`UpdateCommandBuilder` (`internal/services/os_update_command_builder.go`)
is a pure string-generation interface with **no `*RemoteExecutor` or
`*ssh.Client` anywhere in the file** — structurally incapable of running
anything, not just "doesn't happen to":

| Family | Package/kernel update command | OS release command |
|---|---|---|
| APT | `apt-get install --only-upgrade <names...>` (`--only-upgrade` refuses to *install* anything not already present) | `do-release-upgrade` (Ubuntu only; marked `high_risk: true` in the API response) |
| DNF | `dnf upgrade <names...>` | none (`ok: false`) |
| YUM | `yum update <names...>` | none (`ok: false`) |

Package names are validated against a safe character set before being
placed in the generated string (mirrors Step 8's "validate every
remote-sourced value used to build a command, regardless of origin").
`TestCommandBuilders_NeverExecuteAnything` statically parses this file's
own AST and raw source, asserting no `.Execute(...)` call, no
`RemoteExecutor`/`SSHService` reference, and none of the forbidden
mutation verbs (`apt install`, `apt remove`, `reboot`, `shutdown`, ...)
appear anywhere in it — the explicit spec-mandated "no execution" test.

## 10. Authorization

Every `GET /api/updates*`/`GET /api/vms/:id/updates*` endpoint checks
`vm.view` individually (404, not 403, on failure). `GET /api/updates`
(global) restricts a MEMBER to exactly the VMs `GetUserVMAccess` returns
— the summary "totals" cards are computed **from that same restricted
row set**, never a separately-fetched global count (verified live: a
member with one authorized VM out of two never sees the other VM's
security-update count in their totals).

**Every update-plan endpoint is admin-only end to end** — create,
view, list, validate, approve, cancel (spec's explicit "Keep update
planning Admin-only"). A member with `vm.view` on the VM a plan belongs
to still gets `403` on `GET /api/update-plans/:id`.

A package selected from a *different* VM than the one in the URL is
rejected (`400`), never silently accepted or cross-linked — the same
IDOR discipline established for Docker containers in Step 8, applied
here to `packages`/`package_updates` rows.

## 11. Audit events

`UPDATE_SCAN_STARTED`/`COMPLETED`/`FAILED`, `UPDATE_PLAN_CREATED`/
`VALIDATED`/`APPROVED`/`CANCELLED`. Metadata carries `update_plan_id`,
selected/security-update counts, and plan status — verified live that no
audit event metadata ever contains an SSH private key, password, or the
raw (untrusted) client-submitted `target_version` value.

## 12. Live end-to-end verification

Verified against a real Ubuntu 22.04 SSH-reachable test container (real
`apt` state, genuine `jammy-updates`/`jammy-security` pocket data,
identical setup to Step 7's own verification):

- **OS release detection**: `do-release-upgrade -c` against this
  container's real, unmodified release-upgrades metadata correctly
  reported `24.04.4 LTS` available from `22.04.5 LTS` — `update_type:
  RELEASE`, `release_channel: LTS` (from the real `"...LTS..."` substring
  in `VERSION`), all genuine evidence, nothing fabricated.
- **No-privilege-escalation behavior** (Step 7, reused, reconfirmed):
  running as a non-root SSH user, the package-update *check* correctly
  came back `PARTIAL` with the exact documented message ("this
  application never attempts automatic privilege escalation") rather
  than silently sudo-escalating — inventory (184 packages) still synced
  successfully despite the update-check half failing.
- **Real security update through the full plan lifecycle**: re-run as
  root, `libssl3`'s genuine `jammy-security` update was detected and
  carried through create → validate → approve, with the exact backend-
  resolved target version and the exact generated `apt-get install
  --only-upgrade ...` preview — see the Step 9 delivery summary for the
  full transcript.
- **Reboot detection**: correctly `NOT_REQUIRED` (no
  `/var/run/reboot-required` file existed).
- **Kernel detection environment limitation**: this container shares its
  Docker host's kernel (`uname -r` reports the host's WSL2 kernel, e.g.
  `6.6.87.2-microsoft-standard-WSL2`) rather than running its own — no
  `linux-image-*`/`kernel-core` package inside the container will ever
  match it, so `kernel_available` correctly stays empty rather than
  fabricating a mismatch. This is a property of testing inside a
  container, not a gap in the detection logic itself, which is exercised
  and correct against real `packages`/`package_updates` data (§3).
- **IDOR matrix, admin-only enforcement, member-scoped global list with
  no leaked totals, stale-plan detection, and the terminal-status
  transition guard**: all verified via 21 passing HTTP integration tests
  (`internal/server/updates_test.go`) against a real Postgres instance.

## 13. Known limitations

- Kernel-update detection cannot be end-to-end verified inside a
  container test environment (§12) — the underlying comparison logic is
  unit-tested and exercised against real Step 7 package data, but a
  genuine "installed kernel differs from running kernel, reboot
  required" scenario needs a real (non-containerized) VM to observe.
- OS release-upgrade detection is Ubuntu-only; Debian and every RPM
  family always report `UNKNOWN` for this specific check — no safe,
  universal, read-only mechanism exists for them (§2).
- `PATCH`/`MINOR` OS update types are never produced — no safe read-only
  signal distinguishes an in-place point-release bump from ordinary
  package updates (§2).
- The package-update *check* half of a refresh (not the installed-
  package inventory half) still requires the configured SSH user to have
  passwordless permission for the package manager's metadata-refresh
  command (`apt-get update`/etc.) — inherited from Step 7, unchanged
  here; this step's refresh flow surfaces that as a `PARTIAL` status with
  a specific message rather than silently escalating privileges.
- No execution of any kind — Step 10's explicit scope.
