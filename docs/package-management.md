# Linux Package Discovery, Update Detection & Recommendations (Step 7)

Read-only Linux package inventory: which packages are installed, which
have updates available, which of those are security updates -- and a
generated `PACKAGE_UPDATE` recommendation per outstanding update.
Extends Step 5's SSH infrastructure and Step 2's `packages`/
`package_updates`/`recommendations` placeholder schema; no package is
ever installed, upgraded, or removed by this step.

## 1. Supported package managers

| Family | Detected as | Distros |
|---|---|---|
| APT/DPKG | `APT` | Ubuntu, Debian, Linux Mint, Pop!_OS, Raspbian, elementary OS, Kali, Zorin, KDE neon |
| DNF/RPM | `DNF` | Fedora, RHEL 8+, Rocky Linux, AlmaLinux, current CentOS |
| YUM/RPM | `YUM` | RHEL/CentOS 7, Amazon Linux 2 |
| none found | `UNSUPPORTED` | anything else -- never fails VM monitoring or marks the VM offline |

## 2. Detection

`PackageManagerDetector.Detect` (`internal/services/package_manager.go`)
prefers Step 5's already-discovered `distribution_id`
(`vms.distribution_id`, from `/etc/os-release`'s `ID` field) to pick a
short, specific probe order — an Ubuntu VM only ever runs one `command -v
apt-get` check, never also checks for dnf/yum. Only a VM with an
unrecognized or empty distribution ID falls back to probing all three
families (`apt-get`, `dnf`, `yum` in that order) — still a small, bounded
set of read-only `command -v` checks, never an install/upgrade command.

The detected value is stored on `vms.package_manager`
(`APT`/`DNF`/`YUM`/`UNSUPPORTED`). A detection failure — or a scan that
never got far enough to detect anything (e.g. the SSH connection itself
failed) — never overwrites a previously-successful detection: the
service only writes the new value when it actually detected a real
package manager, or there was never a valid value stored before.

## 3. Installed package discovery

One command, one SSH session, machine-readable output only:

- **APT**: `dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n'`
- **RPM family**: `rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\t%{SUMMARY}\n'`

Descriptions are intentionally **not** collected for APT: dpkg's
`${Description}` field is multi-line, which would break the one-line-per-
package parsing format entirely, and there's no single-line equivalent
guaranteed present across the dpkg-query versions this project targets.
RPM's `%{SUMMARY}` *is* collected, since the RPM format spec guarantees
it's single-line.

Packages are matched by `(vm_id, name, architecture)` — the existing
uniqueness constraint from Step 2's schema — so `libfoo:amd64` and
`libfoo:i386` are always tracked as distinct rows, never collapsed.

## 4. Available update detection

- **APT**: `apt-get update` (metadata refresh) then `apt list --upgradable`.
- **DNF/YUM**: `dnf check-update` / `yum check-update` — these tools have
  no metadata-only verb distinct from check-update; the refresh happens
  as a side effect of the same command (spec-mandated: "use the
  appropriate metadata operation without applying package changes").
  `check-update`'s exit code is non-standard: `0` = no updates, `100` =
  ran fine and updates exist, anything else = a real error.

None of `apt upgrade`, `apt install`, `apt remove`, `dnf/yum update`,
`dnf/yum install`, or `dnf/yum remove` are ever executed by this
application, in this step or any other.

## 5. Security update detection

Only real package-manager/repository evidence is used — never a guess
from a package's name:

- **APT**: `apt list --upgradable`'s output includes the repository
  pocket a package's update comes from (e.g. `nginx/jammy-security ...`).
  Contains `-security` → `CONFIRMED`. Its absence is **not** treated as
  proof an update isn't security-related (Ubuntu sometimes ships fixes
  via `-updates` too) — it's `UNKNOWN`, never `NOT_SECURITY`, without
  stronger evidence.
- **DNF/YUM**: a second command, `dnf/yum check-update --security`,
  filters check-update's own result set to security-relevant packages
  (same `name.arch`/`version-release`/`repo` format — no fragile RPM
  NEVRA-string parsing needed to cross-reference). Present there →
  `CONFIRMED`; if the `--security` variant itself fails (older `yum`
  without the security plugin, etc.) every update from the main
  check-update result simply stays `UNKNOWN` — a soft degradation, never
  a failed scan.

`severity` has no real signal from any of these commands beyond
"security or not" — so it's `UNKNOWN` for a plain update, and elevated to
`HIGH` (not automatically `CRITICAL`, per spec) only for a `CONFIRMED`
security update, reflecting elevated priority without claiming evidence
that doesn't exist.

## 6. Version comparison

Never a plain string comparison (`"1.10" < "1.9"` is wrong lexically).
`internal/services/package_version.go` implements each ecosystem's own
documented algorithm:

- **Debian** (`CompareDebianVersions`): dpkg's
  `[epoch:]upstream_version[-debian_revision]` algorithm exactly —
  epoch compared numerically first, then an alternating non-digit/digit
  comparison of upstream_version and debian_revision, with `~` sorting
  before everything (including the empty string) for pre-release
  encoding like `1.2.3~rc1`.
- **RPM** (`CompareRPMVersions`/`CompareRPMFull`): the classic
  `rpmvercmp` algorithm — alternating alpha/numeric segment comparison,
  numeric always outranking alpha at the same position, leading zeros
  ignored in numeric segments — plus `~` pre-release support (RPM ≥
  4.10). Release is compared as a tiebreaker only after version compares
  equal, per spec's explicit `openssl 3.0.7-25.el9_2` example. Known
  limitation: `^` (post-release, RPM ≥ 4.15) is not implemented — a rare,
  newer extension.

Both are unit-tested directly against documented edge cases (epoch
dominance, the `1.9`/`1.10` lexical trap, tilde pre-releases, leading
zeros) in `package_version_test.go`.

## 7. Package scan scheduler

`PackageScanScheduler` (`internal/services/package_scheduler.go`) is
structurally identical to Step 6's `MonitoringScheduler`: a fixed pool of
`PACKAGE_SCAN_WORKERS` goroutines (default 2) drains a job channel, a
`sync.Map` overlap guard skips (never queues) a VM whose previous scan is
still running, and `Run` blocks on a `sync.WaitGroup` until every worker
has actually returned for graceful shutdown. The interval
(`PACKAGE_SCAN_INTERVAL`, default `6h`) is far longer than monitoring's
`60s` — package inventories change far less often than CPU/RAM, and a
full scan is a much heavier operation (multiple sequential SSH commands,
including a real network-bound repository fetch for APT).

Two entry points share the same worker/overlap infrastructure:

- **`Scan`** (`POST .../packages/scan`, and the scheduled cycle): full
  flow -- detect, list installed (sync), refresh metadata, check updates,
  sync `package_updates` + recommendations.
- **`RefreshUpdates`** (`POST .../packages/refresh`): metadata refresh +
  update check only, against the already-known inventory -- no
  re-listing of installed packages. Both are debounced 30 seconds per VM
  on top of the overlap guard (spec §23's "no unlimited rapid requests"),
  since even the overlap guard alone doesn't stop a client from
  hammering the endpoint between fast-failing attempts.

## 8. Authorization

Every `GET /api/vms/:id/packages*` endpoint checks
`AuthorizationService.CanAccessVM(user, vmID, vm.view)` individually — a
member can never read another VM's package inventory by editing the URL
(404, not 403, matching every other VM-scoped endpoint since Step 3).
`POST .../scan`, `.../refresh`, `.../:packageId/acknowledge`, and
`.../:packageId/dismiss` are all `RequireRole(ADMIN)` at the router.

The cross-VM `GET /api/recommendations` dashboard restricts a member to
exactly the VM resource IDs `AuthorizationService.GetUserVMAccess`
returns for them, applied as a SQL `= ANY(...)` filter — an admin passes
no restriction and sees every VM's recommendations. A member with zero
VM access gets an empty list and a `total` of `0`, never the global
count.

## 9. Recommendation lifecycle

`recommendations.source_type`/`source_id` (this step's schema addition)
link a `PACKAGE_UPDATE` recommendation back to the `package_updates` row
that produced it. Every scan **upserts** by that link
(`ON CONFLICT (source_type, source_id) WHERE source_id IS NOT NULL`)
rather than inserting a fresh row every cycle — a hundred scans of the
same outstanding `nginx` update produce exactly one recommendation, kept
current, not a hundred duplicates.

Status values: `NEW` → `ACKNOWLEDGED`/`DISMISSED` (admin actions) →
`RESOLVED` (automatic, once the update disappears). A `package_updates`
row not touched by the current scan (its package was upgraded, or
removed entirely) is marked `RESOLVED` — and its linked recommendation
resolved with it — rather than deleted, so the history of what was once
outstanding stays queryable. `DISMISSED` is left alone by a scan that
still finds the *same* available version (an admin's dismissal isn't
silently undone just because nothing changed); a *materially new*
situation — the available version changed, or the row had already been
`RESOLVED` — comes back as `NEW`.

## 10. Failure handling

Three distinct failure shapes, matching spec §24-25 exactly:

| What failed | `package_discovery_runs.status` | Packages table | `package_updates` |
|---|---|---|---|
| SSH connection | `FAILED` | untouched (soft-removal logic never runs) | untouched |
| Package manager detection (→ `UNSUPPORTED`) | `FAILED` | untouched | untouched |
| Installed-package listing | `FAILED` | untouched | untouched |
| Metadata refresh / update check, after a successful listing | `PARTIAL` | synced (inserted/updated/soft-removed) | untouched (no new data, nothing resolved either) |

A `PARTIAL` scan's inventory is still trustworthy and fully synced —
only the update-availability half of the picture is stale, and the API
surfaces that distinctly (`GetPackageSummaryByVM`'s counts simply don't
change; the discovery run's `error_summary` says update information
couldn't be refreshed) rather than silently pretending everything
succeeded or discarding the good half of the scan.

A soft-deleted (`removed_at` set) package is never hard-deleted — the
row, and its history, stay queryable; only listing endpoints filter it
out by default.

## 11. Security

- No package-manager command is ever built from user input — every
  command string is a Go constant. There is no
  `POST /api/vms/:id/execute` in this application, in this step or any
  other, and the frontend never sends a raw command string anywhere.
- `RefreshMetadataCommand()` (used for the admin-facing command preview)
  returns the exact fixed string that will run — never something
  constructed from a request body.
- **Sudo**: never attempted automatically. If the configured SSH user
  lacks permission for `apt-get update`/`dnf check-update`/`yum
  check-update`, the operation fails with a clear, specific message
  (`internal/services/package_manager_impl.go`'s `isPrivilegeError` /
  `privilegeErrorMessage`) rather than silently retrying with an elevated
  command. Verified live against a real Ubuntu container in a
  non-privileged state (see the Step 7 delivery summary's integration
  test result).
- Package-manager tool output never contains credentials, but
  `safeCommandError` still bounds error message length as a defensive
  habit, and nothing from stdout/stderr is ever written to
  `audit_logs.metadata` — only structured, safe fields (package name,
  status, counts).

## 12. Commands used (complete list)

| Purpose | APT | DNF | YUM |
|---|---|---|---|
| Detect | `command -v apt-get` | `command -v dnf` | `command -v yum` |
| List installed | `dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n'` | `rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\t%{SUMMARY}\n'` | same as DNF |
| Refresh metadata | `apt-get update` | *(no separate verb — see check-update)* | *(same)* |
| Check updates | `apt list --upgradable` | `dnf check-update` | `yum check-update` |
| Check security updates | *(derived from `apt list --upgradable`'s pocket field)* | `dnf check-update --security` | `yum check-update --security` |

## 13. Known limitations

- Severity beyond "security or not" is never available from any of these
  commands — every non-security update is `UNKNOWN` severity, by design,
  not an oversight.
- RPM's `^` post-release marker (RPM ≥ 4.15) is not implemented in the
  version comparator — extremely rare in practice.
- No sudo/privilege-escalation strategy is implemented; a read-only SSH
  user without metadata-refresh permission will always see `PARTIAL`
  scans until that's addressed operationally (grant the user the
  specific, narrow permission it needs) or a future step adds a
  configurable privilege strategy.
- `package_versions_history` (an optional table Step 7's spec allowed
  skipping) was not implemented — the current `package_updates`/
  `package_discovery_runs` tables already answer "what's the situation
  now" and "did scans succeed," and a dedicated version-history table
  wasn't justified by any UI this step actually needs; it can be added
  later without disrupting this schema.
- No install/upgrade/remove execution of any kind — deliberately out of
  scope for this step (see Step 7 spec §64's documented future flow:
  recommendation → admin review → command preview → confirmation →
  execution → verification → audit, none of which is built yet).
