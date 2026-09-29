# VM Monitoring (Step 6)

Real, read-only Linux VM metrics: CPU, memory, swap, storage, filesystem,
network, load average, uptime, process summary, and a derived health
status. Extends Step 5's SSH/discovery infrastructure — it does not
duplicate credential handling, host-key verification, or SSH connection
logic.

## 1. Architecture

```
Next.js  →  Go API (handlers/vm_monitoring.go)
              ↓ reads only
          PostgreSQL (monitoring_snapshots, vm_filesystems, vm_network_snapshots)
              ↑ writes
MonitoringScheduler → VMMonitoringService (Collect) → SSHService → RemoteExecutor
                                                   ↓
                                          monitoring_parse.go (pure parsers)
```

The browser never talks to a VM. It only ever calls the Go API, which
reads whatever the background scheduler already collected and stored.
There is no `POST` that opens an SSH connection synchronously inside an
HTTP request for monitoring — the closest thing is the admin's
`POST /monitoring/collect`, which still goes through the same
`VMMonitoringService.Collect` the scheduler uses, just triggered
out-of-band instead of on a timer.

Layering (mirrors Step 5's SSH/discovery stack exactly):

```
MonitoringScheduler
  → VMMonitoringService.Collect
    → SSHService.Connect          (Step 5, reused unchanged)
    → RemoteExecutor.Execute      (Step 5, reused unchanged)
    → monitoring_parse.go         (ProcStat/MemInfo/LoadAvg/Uptime/DF/NetDev/PS parsers)
    → monitoring_health.go        (ComputeSnapshotHealth / DeriveDisplayHealth)
    → repository (sqlc queries in sql/queries/monitoring.sql)
```

Parsing is deliberately separate from SSH: every parser in
`internal/services/monitoring_parse.go` is a pure function from raw
command stdout to a typed struct, unit-tested against fixture strings
with no VM involved (`monitoring_parse_test.go`).

## 2. Monitoring scheduler

`internal/services/monitoring_scheduler.go`. Starts with the backend
(`cmd/server/main.go` launches `scheduler.Run(ctx)` in a goroutine using
the same signal-cancellable `context.Context` the HTTP server shuts down
with) and stops gracefully: `Run` blocks on a `sync.WaitGroup` until every
worker goroutine has actually returned, and `main.go`'s `defer
background.Wait()` blocks server shutdown until that happens — so a
`SIGTERM` never kills an in-flight SSH session mid-command.

On start, and then every `VM_MONITOR_INTERVAL`, the scheduler queries
`ListMonitoringEnabledVMs` (active resources, `monitoring_enabled = true`,
with an SSH credential configured) and pushes each VM's resource ID onto a
buffered channel. A small fixed pool of `VM_MONITOR_WORKERS` goroutines
(started once, not per cycle) drains that channel.

A `sync.Map` (`inFlight`) keyed by resource ID prevents overlapping
collection for the same VM (spec's backpressure requirement): if the
previous cycle's collection for VM-01 is still running when the next
tick fires, VM-01 is simply not re-enqueued into a second collection —
it's picked up again on a later cycle. This is a skip, never a queue: no
unbounded backlog can build up for a slow VM.

One VM's connection failure never stops the scheduler: `Collect` always
returns a `MonitoringResult` (or a database error only if a write itself
failed), and the worker loop logs and moves on to the next job
regardless of the previous outcome.

## 3. Worker pool

`VM_MONITOR_WORKERS` (default 5) goroutines are created exactly once,
in `MonitoringScheduler.Run`, and read from a single shared `chan
uuid.UUID`. This bounds the maximum number of concurrent SSH connections
to the configured worker count regardless of how many VMs exist — 500
monitoring-enabled VMs with 5 workers means at most 5 SSH sessions open
at any instant, not 500. No goroutine is spawned per VM or per cycle;
the same 5 (or N) goroutines are reused for the life of the process.

## 4. SSH collection

`VMMonitoringService.Collect` (`internal/services/monitoring.go`) opens
**one** SSH connection per VM per cycle via `SSHService.Connect` — the
exact same method Step 5's connection-test and discovery use, so
credential decryption and host-key verification are never reimplemented
here. Each metric command then runs as its own SSH *session* over that
one connection (via `RemoteExecutor.Execute`, also unchanged from Step
5) — never a second TCP/SSH connection per command. The connection is
closed (`defer client.Close()`) once every command has run.

Fixed, backend-authored, read-only commands only:

| Metric | Command |
|---|---|
| CPU | `cat /proc/stat` |
| Memory | `cat /proc/meminfo` |
| Load average | `cat /proc/loadavg` |
| Uptime | `cat /proc/uptime` |
| Filesystems | `df -PkT` |
| Network | `cat /proc/net/dev` |
| Process summary | `ps -eo stat=` |

None of these are ever built from user input, and there is no
arbitrary-execution endpoint anywhere near this code path
(`POST /api/vms/:id/execute` does not exist, in this step or any prior
one).

## 5. CPU calculation

`/proc/stat`'s aggregate `cpu ` line reports monotonically increasing
jiffie counters (user, nice, system, idle, iowait, irq, softirq, steal)
since boot — not an instantaneous percentage. CPU usage is **always** a
delta between two samples (`ComputeCPUUsage` in `monitoring_parse.go`):

```
total_delta = total(current) - total(previous)
idle_delta  = idle(current)  - idle(previous)
usage_percent = 100 * (1 - idle_delta / total_delta)
```

user/system/iowait/idle percentages are each `100 * delta / total_delta`
for their own counter, clamped to `[0, 100]`. `total_delta <= 0` (first
sample, or a counter reset from a reboot between samples) returns
`ok=false`, and the caller stores SQL `NULL` for every CPU percentage
field rather than a fabricated number — the next cycle computes a real
value once a second sample exists.

**Where the "previous sample" comes from**: the previous cycle's full raw
counter set (all 8 fields) is persisted as JSON in
`monitoring_snapshots.cpu_raw_jiffies` — a text column, internal-only,
never returned by any API. Storing only `total`/`idle` would not be
enough, since computing next cycle's user/system/iowait percentages needs
every counter, not just the two used in the headline `usage_percent`
formula. `CountCPUCores` derives the live core count by counting `cpuN`
lines in the same `/proc/stat` read, rather than trusting a possibly-stale
value from an earlier discovery run.

## 6. Memory calculation

From `/proc/meminfo`: `memory_used_bytes = MemTotal - MemAvailable`,
`usage_percent = used / total * 100`. **`MemAvailable` is used, never
`MemFree`** — `MemFree` doesn't account for reclaimable cache/buffers and
significantly overstates memory pressure on any real Linux system.
Swap: `swap_used_bytes = SwapTotal - SwapFree`. A VM with `SwapTotal = 0`
(no swap configured) reports `swap.configured: false` in the API — this
is valid, successfully-collected data, not a monitoring failure.

## 7. Storage calculation

`df -PkT` (POSIX portable output, 1K blocks, filesystem-type column).
Every filesystem is parsed into `(mount_point, filesystem, type,
total/used/available_bytes, usage_percent)`; `ParseDF` also merges the
occasional two-line wrap `df` produces when a device name is unusually
long (common with Docker's `overlay2` mounts).

**Filtering** (`FilterFilesystems`, blocklist by type, not an allowlist):
excluded types are `proc, sysfs, devtmpfs, devpts, tmpfs, cgroup, cgroup2,
mqueue, pstore, securityfs, debugfs, configfs, fusectl, hugetlbfs,
tracefs, binfmt_misc, autofs, rpc_pipefs, nsfs, bpf` — pure kernel
bookkeeping filesystems that never represent real disk capacity. Using a
blocklist rather than an allowlist is deliberate: it means a filesystem
type this list doesn't anticipate (ext4, xfs, btrfs, zfs, nfs, ntfs,
vfat, and — explicitly — Docker's own `overlay`/`overlay2` storage) is
never accidentally hidden, satisfying the spec's explicit warning against
hiding real Docker storage.

The root filesystem (`/`) is always looked for specifically and
surfaced as `storage.total_bytes/used_bytes/usage_percent` on the
snapshot itself (spec's "always try to identify `/` and make it
prominent"); the full per-mount breakdown lives in `vm_filesystems`
(Step 2's placeholder table, reused as-is — this step just adds the
`(vm_id, mount_point, captured_at DESC)` index it needed). If the `df`
command fails outright, the API's `filesystems` field is simply absent
and the frontend renders "Storage information unavailable" — never a
fabricated value.

## 8. Network calculation

`/proc/net/dev`'s per-interface counters are cumulative since the
interface came up, exactly like `/proc/stat`'s CPU counters. `lo` is
dropped at the parser level (`ParseNetDev`), not merely excluded from
aggregates — there's no monitoring use for storing it per VM. Rates
(`ComputeNetworkRate`) are a delta against each interface's own previous
row in `vm_network_snapshots`, divided by the wall-clock time between the
two captures:

```
rx_bytes_per_sec = (rx_bytes_now - rx_bytes_prev) / elapsed_seconds
```

An interface's first-ever sample has no previous row, so its rate is
`NULL`; a negative delta (interface reset/replaced) is clamped to zero
rather than reported as negative throughput. The snapshot's aggregate
`network_rx_rate_bytes`/`network_tx_rate_bytes` sum every interface's
computed rate (excluding any interface whose rate wasn't computable this
cycle); per-interface detail (including errors/dropped) lives in
`vm_network_snapshots`, never inside `monitoring_snapshots` itself.

## 9. Health calculation

`HealthStatus` (`HEALTHY | WARNING | CRITICAL | UNKNOWN | OFFLINE`) is
deliberately a different vocabulary from `resources.status`
(`UNKNOWN/ONLINE/OFFLINE/WARNING/ERROR/DISABLED`) and
`vms.connection_status` — a VM can be `connection_status: CONNECTED` and
`health: CRITICAL` (disk almost full) at the same time; monitoring never
touches `resources.status` for a threshold breach, only
`RecordConnectionOutcome` (Step 5, unchanged) ever does that, and only for
actual connection failures.

Disk and memory are evaluated against `VM_DISK_WARNING_PERCENT` /
`_CRITICAL_PERCENT` and `VM_MEMORY_WARNING_PERCENT` / `_CRITICAL_PERCENT`
directly from the current sample. **CPU deliberately is not** — a single
temporary spike must not flip health (explicit requirement). The chosen
approach: look at up to the 3 most recent CPU samples (newest first,
including the one just computed). WARNING/CRITICAL from the CPU
dimension is only reported when **at least 2 consecutive** of those
samples all breach the respective threshold; a lone spike, or fewer than
2 samples of history (a VM's first or second collection ever), reports
HEALTHY from the CPU dimension. Overall health is the worst of the three
dimensions that were actually collected this cycle — a dimension that
failed to collect is excluded from the comparison, not treated as
CRITICAL or forced to UNKNOWN.

`OFFLINE` is never stored on a snapshot — a snapshot only exists because
the SSH connection that produced it succeeded. It's derived at **read
time** instead (`DeriveDisplayHealth`, in the `GET
.../monitoring/current` handler): no snapshot ever → `UNKNOWN`; the VM's
current `connection_status != CONNECTED` → `OFFLINE` regardless of how
healthy the last successful snapshot looked; otherwise, the stored health
from the latest snapshot.

## 10. Stale metrics

`VM_MONITOR_STALE_AFTER` (default `5m`) is returned to the frontend as
`stale_after_seconds` on every `GET .../monitoring/current` response —
one source of truth, not a duplicated constant on both sides. The
frontend compares `now - captured_at` against it: past the threshold (and
the VM isn't already showing `OFFLINE`), the UI shows "Metrics may be
stale"; `OFFLINE` (derived per §9) shows "Monitoring unavailable"
instead, since at that point there's a known reason data isn't current,
not just an aging snapshot.

## 11. Retention

`internal/services/monitoring_retention.go`. A `RetentionService` ticks
every 24 hours (not on every monitoring cycle) and deletes rows older
than `VM_MONITOR_RETENTION_DAYS` (default 30) from exactly four tables:
`monitoring_snapshots`, `vm_filesystems`, `vm_network_snapshots`,
`vm_monitoring_runs`. `audit_logs`, `operations`, and `operation_logs` are
never touched — they have no retention policy of their own yet, and nothing in
this step introduces one for them. Unlike the monitoring scheduler,
retention does **not** run an initial pass immediately on startup — an
unattended deletion the instant the server restarts would be a surprising
side effect of an operational action, whereas prompt monitoring data is
actively useful right after a restart.

## 12. Failure handling

Every collection cycle creates a `vm_monitoring_runs` row (`RUNNING` →
`SUCCESS`/`PARTIAL`/`FAILED`) — this answers "did the collection
succeed?", a separate question from "what did it collect?" (the snapshot
tables). If the SSH connection itself fails: the run is marked `FAILED`,
`RecordConnectionOutcome` updates `connection_status`/`resources.status`
exactly as a failed connection-test or discovery would, and — critically
— **no snapshot row is written at all**. Previous history is never
deleted or overwritten; `GET .../monitoring/current` simply keeps showing
the last successful snapshot's data (with `OFFLINE` health layered on
top, per §9) until a connection succeeds again.

If the connection succeeds but only some commands do (partial network
outage mid-cycle, a command timing out): the run is marked `PARTIAL`,
and every field that *did* parse successfully is still written — a
single failed metric never discards the rest of the cycle's data. Only
if literally every command failed is the run marked `FAILED` despite a
successful connection.

## 13. Security

- Monitoring reuses `SSHService`/`CredentialService` unchanged — there is
  no second code path that decrypts a private key or dials a VM.
- No monitoring API response, database column, or log line ever contains
  a private key, decrypted credential, or ciphertext. `docs/ssh-architecture.md`'s
  guarantees are untouched by this step.
- Every `GET /api/vms/:id/monitoring/*` and `POST .../collect` endpoint
  individually checks `AuthorizationService.CanAccessVM(user, vmID,
  vm.view)` — a member can never read another VM's metrics by editing the
  URL (404, not 403, on an unauthorized ID — same disclosure policy as
  every other VM-scoped endpoint since Step 3).
- `POST .../monitoring/collect` is admin-only (`RequireRole(ADMIN)`) and
  rate-limited per VM (a 10-second debounce plus the overlap guard from
  §2) — a member cannot trigger collection under any circumstances, and
  an admin cannot flood a VM with rapid manual triggers.
- A disabled (`monitoring_enabled = false`) or deactivated
  (`resources.status = DISABLED`) VM is excluded from
  `ListMonitoringEnabledVMs` and is never scheduled — though a direct
  manual `POST .../collect` on an explicitly-disabled VM is still
  possible for an admin (the toggle governs the *scheduler*, not a hard
  block on the collect endpoint, matching how a deactivated VM still
  allows an admin to reactivate it through other endpoints).
- Logs record `vm_id`/`resource_id`, outcome, and `duration_ms` — never
  command output, connection strings, or anything credential-shaped.

## 14. Configuration

All environment variables (see also the root `README.md`):

| Variable | Default | Meaning |
|---|---|---|
| `VM_MONITOR_INTERVAL` | `60s` | How often the scheduler runs a full cycle |
| `VM_MONITOR_WORKERS` | `5` | Max concurrent SSH collections |
| `VM_MONITOR_STALE_AFTER` | `5m` | Age past which the UI marks metrics stale |
| `VM_MONITOR_RETENTION_DAYS` | `30` | How long snapshot/run history is kept |
| `VM_CPU_WARNING_PERCENT` / `_CRITICAL_PERCENT` | `80` / `90` | CPU health thresholds (2-consecutive-sample rule, §9) |
| `VM_MEMORY_WARNING_PERCENT` / `_CRITICAL_PERCENT` | `80` / `90` | Memory health thresholds |
| `VM_DISK_WARNING_PERCENT` / `_CRITICAL_PERCENT` | `80` / `90` | Disk (root filesystem) health thresholds |
| `NEXT_PUBLIC_MONITORING_REFRESH` (frontend) | `30s` | How often the monitoring page polls `GET .../monitoring/current` |

None of these are hardcoded anywhere else in the application — every
consumer reads them from `internal/config.Config`
(`cmd/server/main.go` wires them into `HealthThresholds`,
`MonitoringScheduler`, and `RetentionService`) or, on the frontend, from
`process.env.NEXT_PUBLIC_MONITORING_REFRESH`.

## Out of scope for this step

Interactive terminal, arbitrary command execution, package/OS updates,
Docker operations, and any *automatic remediation* (restarting services,
killing processes, deleting files, cleaning Docker, resizing disks,
restarting the VM, modifying configuration) remain explicitly out of
scope — monitoring here is strictly read-only. A future Recommendation
Engine can consume the health/threshold data this step exposes (e.g. a
sustained `DISK_WARNING`), but that engine itself is not implemented
here — only the data it would need already exists.

## Production considerations (documented, not implemented)

- A real secret manager instead of the single `SSH_CREDENTIAL_ENCRYPTION_KEY`
  (unchanged from Step 5's note on this).
- Per-metric alerting/notification delivery, once a Recommendation Engine exists.
- A dedicated monitoring agent on the VM (push model) as an alternative
  to this step's pull-over-SSH model, for VMs where opening inbound SSH
  from the control plane isn't desirable.
- SSH connection pooling across cycles (today, one connection is opened
  and closed per VM per cycle — simple and correct, but not the most
  efficient at very large fleet sizes).
- Finer-grained per-VM rate limiting/queueing if `VM_MONITOR_WORKERS`
  needs to scale well past single digits.
