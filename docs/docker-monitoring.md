# Docker Discovery, Container Inventory & Live Metrics (Step 8)

Read-only Docker visibility on Linux VMs: daemon detection, full
container/image/network/volume inventory via structured JSON output, and
per-container `docker stats`-equivalent metrics — including a WebSocket
live-streaming feed for one selected container at a time. Extends Step
5's SSH infrastructure and Step 2's `docker_containers`/`docker_images`
placeholder schema. No container is ever started, stopped, restarted,
removed, execed into, or built by this step — see §9 for the complete
list of what is deliberately not implemented.

## 1. Daemon detection & status

`DockerDaemonStatus` (`internal/services/docker_client.go`) is a richer,
independently re-checked status distinct from Step 5's `docker_installed`
boolean (a "was Docker present at last VM discovery" flag that this step
never reads or writes). `DockerClient.DetectStatus` runs, in order:

1. `command -v docker` — absent → `NOT_INSTALLED`.
2. `docker version --format '{{json .}}'` — parsed regardless of exit
   code, since Docker's own CLI deliberately exits nonzero while still
   printing the client half's JSON when only the daemon half fails
   (`{"Client":{...},"Server":null}`). No `Server` section → `INSTALLED`
   (CLI present, daemon not running/reachable) unless stderr contains the
   literal phrase `permission denied`, in which case → `PERMISSION_DENIED`.
   Genuinely unparseable output → `UNAVAILABLE`/`UNKNOWN`.
3. `docker info --format '{{json .}}'` — only reached once a `Server`
   section confirmed the daemon answered. Success → `RUNNING`, with
   storage/logging/cgroup driver, cgroup version, kernel/OS/architecture,
   NCPU, and total memory captured into `vms.docker_info` (jsonb) — only
   the fields this particular Docker install actually reported, never a
   fabricated 0 for one it didn't.

`vms.docker_daemon_status`/`docker_engine_version`/`docker_api_version`/
`docker_cli_version`/`docker_info` are only ever overwritten with a real
detection result — a transient command failure (an `error` return, not a
classified status) leaves the previous values untouched, mirroring how
Step 7 handles `vms.package_manager`.

## 2. Inventory discovery

`DockerDiscoveryService.Scan` (`internal/services/docker_discovery_service.go`)
runs, once daemon status is confirmed `RUNNING`:

| Category | Commands (all via `DockerClient`, one batched call each) |
|---|---|
| Containers | `docker ps -aq` → `docker inspect <ids...>` (one call covering every ID, empty-list guarded) |
| Images | `docker images --digests --no-trunc --format '{{json .}}'` |
| Networks (+ membership) | `docker network ls -q` → `docker network inspect <ids...>` |
| Volumes | `docker volume ls -q` → `docker volume inspect <names...>` |

Every command asks for structured JSON; none of Step 8's own code parses
a pretty-printed terminal table. Several JSON fields are still
human-formatted strings Docker itself produces (byte sizes like
`"512MiB"`, dates like `"2024-01-15 10:30:00 +0000 UTC"`) — parsed by
dedicated helpers in `docker_parse.go` (`ParseDockerSize`, the
`dockerImagesCreatedAtLayout` constant), a Docker CLI limitation, not a
choice to parse pretty output.

Container/network IDs and volume names taken from list output are
validated (hex-only for IDs, Docker's own naming character set for
volumes) before ever being placed into a follow-up command line — these
values come from Docker's own output rather than user input, but this
project treats every remote-sourced value used to build a command as
untrusted until validated.

**Multiple tags, one image ID** (spec's explicit warning): `docker_images`
is keyed `(vm_id, image_id, repository, tag)`, not `(vm_id, image_id)` —
`myapp:1.2` and `myapp:latest` pointing at the same image ID are two
distinct, fully retained rows, never collapsed into one silently
overwriting the other.

**Soft-delete, never hard-delete**: containers/images/networks/volumes no
longer seen by a scan get `removed_at` set (`Mark*RemovedSince`), keeping
their metric/discovery history queryable. The one exception is
`docker_container_networks` (per-container network membership) — current-
state-only, not a history table, so a scan simply deletes and re-inserts
a container's membership rows wholesale rather than tracking their
removal separately.

## 3. Container detail: what is collected, and what is deliberately not

From `docker inspect`, only these fields are extracted into
`docker_containers`:

- Identity: container ID, name (leading `/` stripped), image
  repository:tag, image ID
- State: structured `status` enum (`CREATED`/`RUNNING`/`RESTARTING`/
  `EXITED`/`PAUSED`/`DEAD`/`REMOVING`/`UNKNOWN` — corrected from an
  earlier placeholder schema that included the non-Docker value
  `STOPPED`), the raw human-readable `state` string alongside it,
  `health` (`HEALTHY`/`UNHEALTHY`/`STARTING`/`NO_HEALTHCHECK`/`UNKNOWN` —
  a container with no configured healthcheck is `NO_HEALTHCHECK`, never
  `UNHEALTHY`), `restart_count`, `platform`
- `command`: the full invoked command, joining Docker's own `Path` (the
  binary) and `Args` (its arguments) — a real bug caught during live
  verification (§8) where only `Args` was captured, showing `"3600"`
  instead of `"sleep 3600"`.
- Timestamps: `created_at_remote`, `started_at_remote` (Docker's
  zero-time sentinel `0001-01-01T00:00:00Z` — used for "never
  started"/"never finished" — is treated as absent, not a real time)
- Ports: container port/protocol/host IP/host port only
- Mounts: source/destination/read-only/type only
- Network membership: per-network name/IP/gateway/MAC, sourced from the
  container's own `NetworkSettings.Networks` map (richer than `docker
  network inspect`'s membership map, which lacks gateway/MAC) — no
  second command needed for the common case

**Never collected, anywhere in this step, under any circumstance:**

- Container environment variables (`docker inspect`'s `.Config.Env`) —
  can contain passwords, tokens, API keys, database credentials.
- The full raw `docker inspect` result — only the explicitly-approved
  fields above are ever extracted and stored.
- `~/.docker/config.json` or any Docker registry/config credential.

## 4. Container metrics

`DockerMetricsService.CollectAll` (`internal/services/docker_metrics_service.go`)
runs `docker stats --no-stream --format '{{json .}}'` **exactly once per
cycle**, covering every currently-running container on the VM in that one
command — never one SSH connection or one `docker stats` call per
container (mandatory batching). `--no-stream` makes Docker itself perform
the correct two-sample CPU-percent delta internally, so the backend never
recomputes it from a single counter.

`docker stats`' own `Container` field is a short/truncated ID; matching
against `docker_containers.container_id` (the full ID from `docker
inspect`) is done by prefix match (`matchContainerByShortID`). A stats
line with no matching inventory row (a container started after the last
discovery scan) is skipped rather than guessed at.

**No fabricated memory limit**: Docker reports an enormous sentinel value
(~9.2×10¹⁸ bytes) for `MemUsage`'s limit half when a container has no
real cgroup memory limit — `dockerNoMemoryLimitThreshold` (`1 << 62`)
catches this, storing `NULL` for `memory_limit_bytes`/`memory_percent`
rather than a nonsensical percentage. Verified live: a container in the
Docker-in-Docker test environment reporting `"0B / 0B"` memory correctly
stores raw `0` usage with `HasMemoryLimit = false` — the pipeline reports
exactly what Docker itself provided, even when that's uninformative,
rather than inventing something more interesting.

`docker_container_metric_snapshots` stores only the raw cumulative
counters `docker stats` reports (network rx/tx, block read/write) — rates
are deliberately **not** precomputed at collection time; they're computed
on demand from two consecutive rows by `ComputeDockerByteRate`
(`docker_parse.go`), called from the REST history endpoint and the
overview handler, never from `DockerMetricsService`. A counter that goes
backwards between two samples (the container restarted, resetting its
cumulative counters) yields no rate for that pair, not a negative one.

## 5. Live streaming (WebSocket)

`GET /api/vms/:id/docker/containers/:containerId/stats/stream`
(`internal/handlers/docker_stream.go`) pushes one JSON frame per
`DOCKER_STATS_STREAM_INTERVAL` (default 1s) for a single selected
container. The architecture that makes "5 browser viewers never means 5
SSH connections" possible, with no pub/sub hub needed:

```
DockerMetricsScheduler (DOCKER_METRICS_INTERVAL, e.g. 15s)
    → one SSH connection, one `docker stats` call per VM per cycle
    → DockerMetricsCache.Set(containerDBID, stats, capturedAt)   [shared, in-memory, thread-safe]

Each WebSocket connection (its own goroutine, ticking at DOCKER_STATS_STREAM_INTERVAL)
    → DockerMetricsCache.Get(containerDBID)   [read-only, never triggers SSH]
    → write one JSON frame
```

The cache is keyed by the container's DB row ID (which already uniquely
identifies one container on one VM) rather than a `(vm_id,
container_id)` composite — simpler, same guarantee. A connection with
nothing cached yet gets a `{"type":"waiting",...}` frame instead of a
fabricated sample. Verified live with three simultaneous WebSocket
viewers of the same container: each received independent frames from the
one shared cache, with no additional SSH activity.

This is a metrics feed only — no Docker exec/console terminal exists
here or anywhere in this step (see §9).

**A real middleware bug caught during live verification**: the request-
logging middleware's `responseWriter` wrapper embedded `http.ResponseWriter`
but didn't implement `http.Hijacker`, so every WebSocket upgrade request
routed through it failed with an HTTP 500 (the type assertion
`w.(http.Hijacker)` inside `gorilla/websocket`'s `Upgrade()` failed
against the wrapper struct, even though the real underlying
`ResponseWriter` supports hijacking). Fixed by adding a `Hijack()` method
to `middleware.responseWriter` that delegates to the underlying writer.

## 6. Three independent scheduler cadences

Never combined, each with its own worker pool and overlap guard
(structurally identical to Step 6's `MonitoringScheduler`/Step 7's
`PackageScanScheduler` — fixed goroutine pool draining a job channel, a
`sync.Map` per-VM in-flight guard that skips rather than queues an
overlapping cycle, `Run(ctx)` blocking on a `sync.WaitGroup` for graceful
shutdown):

| Scheduler | Interval (default) | Workers (default) | What it does |
|---|---|---|---|
| `DockerDiscoveryScheduler` | `DOCKER_SCAN_INTERVAL` = 10m | `DOCKER_SCAN_WORKERS` = 2 | Full inventory scan (§2) |
| `DockerMetricsScheduler` | `DOCKER_METRICS_INTERVAL` = 15s | `DOCKER_METRICS_WORKERS` = 3 | `docker stats` for all running containers (§4) |
| (WebSocket push, not a scheduler) | `DOCKER_STATS_STREAM_INTERVAL` = 1s | — | Reads the cache only (§5) |

`DockerDiscoveryScheduler.ScanNow` (the admin's `POST .../docker/scan`
button) shares the scheduler's overlap guard plus a 30-second manual-
trigger debounce — verified live: an immediate second scan attempt
returns `429` with `ErrDockerScanRateLimited`.

`DockerRetentionService` (`internal/services/docker_retention.go`) runs
daily, deleting `docker_container_metric_snapshots` rows older than
`DOCKER_METRICS_RETENTION_DAYS` (default 7). Only that one table is ever
touched — never `audit_logs`, `operations`, `operation_logs`, or the
inventory tables (those soft-delete via `removed_at`, not a retention
window).

## 7. Authorization

Every `GET /api/vms/:id/docker*` endpoint — REST and the WebSocket
upgrade alike — independently authenticates and checks
`AuthorizationService.CanAccessVM(user, vmID, vm.view)` before doing
anything else (404, not 403, on failure — existence must not leak,
matching every VM-scoped endpoint since Step 3). `POST .../docker/scan`
is additionally `RequireRole(ADMIN)` at the router.

**Every container-scoped endpoint** (`GET .../containers/:containerId`,
`.../metrics/current`, `.../metrics/history`, and the WebSocket stream)
additionally verifies the requested container belongs to the requested
VM via `GetDockerContainerByID(id, vm_id)` — a container that genuinely
exists but on a *different* VM must 404 exactly like one that doesn't
exist at all, never revealing it exists elsewhere. Verified live: a
container fixture created under VM-B, requested as
`VM-A/docker/containers/<VM-B's container id>` (REST) and
`ws://.../VM-A/docker/containers/<VM-B's container id>/stats/stream`
(WebSocket) both correctly 404 rather than serving VM-B's data or leaking
its existence.

## 8. Live end-to-end verification

Verified against a real Docker-in-Docker test container (a privileged
`ubuntu:22.04` container with `openssh-server` + `docker.io` installed,
`dockerd` started manually with `--storage-driver=vfs` — the default
`overlay2` driver fails to mount nested inside this particular Docker
Desktop/WSL2 host environment). Real resources created inside it: two
containers (`nginx:alpine` with a published port and a volume mount,
`alpine:latest sleep 3600`), an image tagged twice (`nginx:alpine` /
`nginx:e2e-test`, same image ID), a user-defined bridge network, and a
named volume.

Confirmed end-to-end: daemon status `NOT_INSTALLED`→`RUNNING` transition
via `docker_installed` (Step 5) and `docker_daemon_status` (Step 8)
agreeing; full inventory scan (2 containers/3 images/4 networks incl.
Docker's 3 built-in ones/1 volume); container detail with correct
port/mount/network-membership/command parsing; `docker stop` correctly
reflected as `EXITED` on the next scan, excluded from the next metrics
cycle; `docker stats` metrics flowing into both the REST current/history
endpoints (with rate computed as `0` between unchanging samples, and
correctly *absent* on the very first row of a history query) and the
WebSocket stream (single viewer and 3 simultaneous viewers); stopping
`dockerd` correctly reported as `INSTALLED` (not erasing existing
inventory data) and correctly recovering to `RUNNING` with the same
counts once restarted; the full IDOR matrix (§7); the manual-scan rate
limit (§6).

Two real bugs were caught and fixed during this live verification, both
documented above: the `Path`+`Args` command-parsing bug (§3) and the
WebSocket `Hijack()` middleware bug (§5). A third classification bug was
also caught and fixed: `isDockerPermissionError`'s `"dial unix"`
substring check was broad enough to misclassify "daemon not running,
socket file doesn't exist" (a normal `INSTALLED` state) as
`PERMISSION_DENIED` — narrowed to only the literal `"permission denied"`
phrase Docker actually emits for that specific condition.

## 9. What is deliberately not implemented

No Docker mutation of any kind: start, stop, restart, remove
(container/image), pull, push, exec, run, build, prune, network
create/remove, or volume create/remove. No Docker exec/console terminal.
No recommendation-engine integration (Step 7's `PACKAGE_UPDATE`
recommendation pattern is not extended to Docker in this step — this
step only provides the underlying data). All of these belong to future
operation-management steps.

## 10. Commands used (complete list)

| Purpose | Command |
|---|---|
| Detect binary | `command -v docker` |
| Version | `docker version --format '{{json .}}'` |
| Daemon info | `docker info --format '{{json .}}'` |
| List container IDs | `docker ps -aq` |
| Inspect containers | `docker inspect <ids...>` |
| List images | `docker images --digests --no-trunc --format '{{json .}}'` |
| List network IDs | `docker network ls -q` |
| Inspect networks | `docker network inspect <ids...>` |
| List volume names | `docker volume ls -q` |
| Inspect volumes | `docker volume inspect <names...>` |
| Container stats | `docker stats --no-stream --format '{{json .}}'` |

## 11. Known limitations

- `docker stats`' short container ID is matched against the full ID by
  prefix — a container `docker stats` reports that discovery hasn't seen
  yet (started between scan cycles) is skipped for that one metrics
  cycle rather than guessed at; it's picked up once the next discovery
  scan runs.
- No per-container metrics-collection opt-out — every running container
  on a `RUNNING`-daemon VM is included in each metrics cycle.
- Rate computation in `.../metrics/history` walks the returned page only
  — a rate at the very edge of a paginated window has no visibility into
  the row just outside that window.
- The Docker-in-Docker test environment's `vfs` storage driver (needed
  for this particular nested-virtualization host) does not report
  meaningful CPU/memory statistics for lightly-loaded containers — this
  is a property of that specific test environment, not a parsing gap;
  the pipeline correctly reports whatever Docker itself provides.
