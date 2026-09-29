# Infra Hub Center

**Infrastructure Monitoring & Operations Platform.** Manages VMs (SSH
discovery, OS/kernel, packages, controlled reboot), Docker (containers,
images, metrics), standalone databases (PostgreSQL/MySQL/MariaDB/
MongoDB/Redis/Valkey monitoring, performance, browser, logs), and the
controlled remediation layer built on top of it (Step 14's Admin-only,
backend-templated database operations) -- all under a Project → Group →
resource authorization model with a Member/Admin permission system and
an append-only audit log. See "Roadmap" below for what's intentionally
still out of scope.

## Repositories and images

| Repository | Contents | Image (docker.io) |
|---|---|---|
| [infrahub-deploy](https://github.com/infrahubcenter/infrahub-deploy) | This repo: compose files, Kubernetes manifests, gateway, docs | `infrahubcenter/infrahub-gateway` |
| [infrahub-api](https://github.com/infrahubcenter/infrahub-api) | Go backend | `infrahubcenter/infrahub-api` |
| [infrahub-ui](https://github.com/infrahubcenter/infrahub-ui) | Next.js console | `infrahubcenter/infrahub-ui` |
| [infrahub-docker-agent](https://github.com/infrahubcenter/infrahub-docker-agent) | Agent for Docker hosts | `infrahubcenter/infrahub-docker-agent` |
| [infrahub-k8s-agent](https://github.com/infrahubcenter/infrahub-k8s-agent) | In-cluster Kubernetes agent + manifest | `infrahubcenter/infrahub-k8s-agent` |
| [infrahub-vm-agent](https://github.com/infrahubcenter/infrahub-vm-agent) | Linux/Windows/macOS VM agent, native installer, release binaries | `infrahubcenter/infrahub-vm-agent` |
| [infrahub-site](https://github.com/infrahubcenter/infrahub-site) | Public marketing site | `infrahubcenter/infrahub-site` |

**Install from the published images:** see [deploy/README.md](deploy/README.md)
(Docker Compose or Kubernetes). The sections below cover local
development, with `infrahub-api` and `infrahub-ui` cloned next to this
repository.

## 1. Requirements

- [Go](https://go.dev/dl/) 1.26+
- [Node.js](https://nodejs.org/) 20+ and npm
- [Docker](https://www.docker.com/) with Docker Compose

## 2. Start PostgreSQL

From the repository root:

```bash
docker compose up -d
```

This starts a local PostgreSQL 16 instance on `localhost:5432` with a health
check. Credentials come from environment variables (see below); if unset,
the defaults in `docker-compose.yml` are used for local development only.

To stop it:

```bash
docker compose down
```

## 3. Start the Go backend (infrahub-api)

```bash
cd infrahub-api
# development.ini.enc already ships with working dev values (every secret
# ENC(...)-encrypted) -- see its own header comment. You just need the
# master key that decrypts it:
go run ./cmd/gen-encryption-key > .master.key   # local dev only, gitignored -- see below
go run ./cmd/migrate up            # apply database migrations
go run ./cmd/seed                  # seed roles + permissions (idempotent)
go run ./cmd/bootstrap-admin       # create the first ADMIN (fails if one already exists)
go run ./cmd/server
```

The server reads its required, secret-shaped configuration from
`development.ini.enc`/`production.ini.enc` (see §5 below), and everything
else from plain environment variables (or a legacy `.env`, still read as a
best-effort optional-tuning source). It verifies the database connection on
startup and listens on `http://localhost:8080` by default. See
[Database](#database) for migrations/seeding and
[Authentication & Authorization](#authentication--authorization) for login
and access control.

## 4. Start the Next.js frontend (infrahub-ui)

```bash
cd infrahub-ui
cp .env.example .env.local   # edit values if needed
npm install
npm run dev
```

The frontend is available at `http://localhost:3000`.

## 5. Environment variables

### `infrahub-api/development.ini.enc` / `production.ini.enc`

The handful of REQUIRED, secret-shaped values (`DATABASE_URL`,
`JWT_SECRET`, `BOOTSTRAP_ADMIN_*`, `SSH_CREDENTIAL_ENCRYPTION_KEY`) live
here, not in a plaintext `.env` — every secret VALUE is AES-256-GCM
encrypted (wrapped as `ENC(...)`), which is what makes these two files
safe to commit. Only the one master key that decrypts them
(`INFRAHUB_MASTER_KEY`) needs to stay out of git: as a real environment
variable in production, or a local, gitignored `infrahub-api/.master.key`
file for development convenience. See
`infrahub-api/development.ini.enc`'s own header comment,
`internal/config/encrypted_env.go`, and:

```bash
cd infrahub-api
go run ./cmd/gen-encryption-key                                   # generate a master key
INFRAHUB_MASTER_KEY=<key> go run ./cmd/encrypt-config-value "the secret value"   # encrypt one value
```

### `infrahub-api/.env` (optional tuning only)

Everything below is a plain, non-secret environment variable with a
built-in default in the Go code itself — nothing here is required, and
none of it needs encrypting. Set via a real OS environment variable, or
(for local development) a legacy `infrahub-api/.env`, still read as a
best-effort source alongside `development.ini.enc`.

`APP_ENV`, `DATABASE_URL`, `JWT_SECRET`, `BOOTSTRAP_ADMIN_*`, and
`SSH_CREDENTIAL_ENCRYPTION_KEY` moved to
`development.ini.enc`/`production.ini.enc` above — they're not set here
anymore. Everything below still is:

| Variable                      | Description                                                          |
| ----------------------------- | ---------------------------------------------------------------------- |
| `APP_PORT`                    | Port the HTTP server listens on (default 8080)                       |
| `DB_MAX_CONNS`                | Max pool connections (default 10)                                    |
| `DB_MIN_CONNS`                | Min idle pool connections (default 2)                                |
| `DB_CONNECT_TIMEOUT_SECONDS`  | Connection/ping timeout in seconds (default 5)                       |
| `FRONTEND_ORIGIN`             | Origin allowed by CORS (default `http://localhost:3000`)             |
| `ACCESS_TOKEN_TTL_MINUTES`    | Access token lifetime (default 15)                                   |
| `REFRESH_TOKEN_TTL_DAYS`      | Refresh token lifetime (default 7)                                   |
| `COOKIE_SECURE`               | Overrides the `Secure` cookie flag; defaults to `false` only when `APP_ENV=development` |
| `SSH_CONNECT_TIMEOUT`          | Max time to establish a TCP+SSH connection to a VM (default `10s`, Go duration syntax) |
| `SSH_COMMAND_TIMEOUT`          | Max time for a single discovery command to run over SSH (default `30s`) |
| `VM_MONITOR_INTERVAL`          | How often the background scheduler collects metrics for every monitored VM (default `60s`) |
| `VM_MONITOR_WORKERS`           | Max concurrent SSH monitoring collections (default `5`) |
| `VM_MONITOR_STALE_AFTER`       | Age past which the UI marks metrics "may be stale" (default `5m`) |
| `VM_MONITOR_RETENTION_DAYS`    | How long monitoring history is kept before the daily cleanup job deletes it (default `30`) |
| `VM_CPU_WARNING_PERCENT` / `VM_CPU_CRITICAL_PERCENT` | CPU health thresholds (default `80` / `90`) |
| `VM_MEMORY_WARNING_PERCENT` / `VM_MEMORY_CRITICAL_PERCENT` | Memory health thresholds (default `80` / `90`) |
| `VM_DISK_WARNING_PERCENT` / `VM_DISK_CRITICAL_PERCENT` | Disk (root filesystem) health thresholds (default `80` / `90`) |
| `PACKAGE_SCAN_INTERVAL`        | How often the background scheduler scans installed packages/updates for every eligible VM (default `6h`) |
| `PACKAGE_SCAN_WORKERS`         | Max concurrent SSH package scans (default `2`) |
| `PACKAGE_SCAN_COMMAND_TIMEOUT` | Max time for a single package-manager command (`apt-get update`, `dnf check-update`, ...) — longer than `SSH_COMMAND_TIMEOUT` since these are real network-bound repository fetches (default `90s`) |
| `DOCKER_SCAN_INTERVAL`         | How often the background scheduler runs a full Docker inventory scan (containers/images/networks/volumes) for every eligible VM (default `10m`) |
| `DOCKER_SCAN_WORKERS`          | Max concurrent SSH Docker inventory scans (default `2`) |
| `DOCKER_METRICS_INTERVAL`      | How often `docker stats` is collected for every running container on each Docker-enabled VM — one SSH connection and one command per VM per cycle, never per-container (default `15s`) |
| `DOCKER_METRICS_WORKERS`       | Max concurrent SSH Docker metrics collections (default `3`) |
| `DOCKER_STATS_STREAM_INTERVAL` | Push cadence for the live container-metrics WebSocket — reads the shared metrics cache only, never opens its own SSH connection (default `1s`) |
| `DOCKER_METRICS_RETENTION_DAYS` | How long container metric history is kept before the daily cleanup job deletes it (default `7`) |
| `DOCKER_METRICS_STALE_AFTER`   | Age past which the API/UI marks a container's cached metrics "may be stale" (default `60s`) |
| `UPDATE_METADATA_STALE_AFTER`  | Age past which the Update Center's pre-update checklist warns that package information may be stale and should be rescanned (default `1h`) — OS/kernel/reboot detection itself has no separate interval; it rides on `PACKAGE_SCAN_INTERVAL` |
| `UPDATE_WORKERS`               | Worker pool size for dequeuing update-execution operations (default `2`) |
| `MAX_CONCURRENT_UPDATES`       | Global cap on simultaneously *executing* update operations across all VMs combined (default `2`) |
| `MAX_PACKAGES_PER_UPDATE_PLAN` | Update plans with more selected packages than this are rejected at execution time (default `100`) |
| `UPDATE_COMMAND_TIMEOUT`       | Timeout for the package-manager command itself — much longer than `SSH_COMMAND_TIMEOUT` since real installs can take minutes (default `30m`) |
| `UPDATE_LOG_MAX_BYTES`         | Per-operation cap on persisted execution-log bytes; live streaming is unaffected, only database storage is bounded (default `2097152`, 2MiB) |
| `REBOOT_WORKERS`               | Worker pool size for dequeuing controlled-reboot operations (default `2`) |
| `MAX_CONCURRENT_VM_OPERATIONS` | Cap on simultaneously *executing* reboot operations, deliberately separate from `MAX_CONCURRENT_UPDATES` (default `3`) |
| `REBOOT_TIMEOUT`               | Overall wall-clock budget from SSH disconnect to a confirmed reconnect before giving up (default `10m`) |
| `REBOOT_INITIAL_WAIT`          | Fixed wait after sending the reboot command before the first reconnect attempt (default `10s`) |
| `REBOOT_MAX_RECONNECT_ATTEMPTS` | Hard cap on reconnect attempts, independent of `REBOOT_TIMEOUT` (default `12`) |
| `DATABASE_DISCOVERY_INTERVAL`, `DATABASE_DISCOVERY_WORKERS` | Unused since the standalone rework — databases are configured manually (`POST /api/databases`), never auto-discovered; kept only so an unset env var doesn't error, not read by any active scheduler |
| `DATABASE_METRICS_INTERVAL`    | How often metrics are collected for each monitoring-enabled database, over its own direct TCP/TLS connection (default `15s`) |
| `DATABASE_METRICS_WORKERS`     | Max concurrent database metrics collections (default `3`) |
| `DATABASE_METRICS_RETENTION_DAYS` | How long database metric history is kept before the daily cleanup job deletes it (default `7`) |
| `DATABASE_METRICS_STALE_AFTER` | Age past which the API/UI marks a database's cached metrics "may be stale" (default `60s`) |
| `DATABASE_CONNECTION_WARNING_PERCENT` / `DATABASE_CONNECTION_CRITICAL_PERCENT` | Connection-utilization health thresholds (default `80` / `95`) |
| `DATABASE_MEMORY_WARNING_PERCENT` / `DATABASE_MEMORY_CRITICAL_PERCENT` | Memory-utilization health thresholds (default `80` / `95`) |
| `DATABASE_CONNECTION_TIMEOUT`  | Overall budget for one connect+check/collect cycle against a database instance (default `10s`) |
| `DATABASE_QUERY_TIMEOUT`       | Per-remote-command budget within that cycle (default `5s`) |
| `DATABASE_SLOW_QUERY_MS`       | A query's average latency above this is flagged slow; also the query-latency-p95 threshold (default `1000`) |
| `DATABASE_LONG_RUNNING_QUERY_SECONDS` | Session duration threshold for "long-running" classification (default `60`) |
| `DATABASE_QUERY_METRICS_RETENTION_DAYS` | Retention specifically for the (potentially high-volume) query-metrics table, separate from the common/deep metrics retention above (default `7`) |
| `DATABASE_DEEP_METRICS_INTERVAL` | How often expensive query-ranking/lock/replication/storage-growth metrics are collected — a separate, much slower cadence from `DATABASE_METRICS_INTERVAL` (default `60s`) |
| `DATABASE_DEEP_METRICS_WORKERS` | Max concurrent deep-metrics collections (default `2`) |
| `DATABASE_MONITOR_MAX_CONNECTIONS` | Cap on simultaneous fast+deep monitoring connections combined, regardless of configured worker counts (default `3`) |
| `DATABASE_QUERY_TEXT_CAPTURE`  | Whether normalized (never raw) query text is ever stored at all (default `false`) |
| `DATABASE_QUERY_TEXT_MAX_BYTES` | Truncation bound for stored query text when capture is enabled (default `4096`) |
| `DATABASE_CACHE_HIT_WARNING_PERCENT` / `DATABASE_CACHE_HIT_CRITICAL_PERCENT` | Cache hit ratio thresholds, Postgres/MySQL/MariaDB only (default `95` / `90`) |
| `DATABASE_LOCK_WARNING_COUNT`  | Blocked-session count that triggers a lock-contention recommendation (default `3`) |
| `DATABASE_ALERT_COOLDOWN`      | Reserved for a future notification channel; recommendation flapping is already prevented by threshold hysteresis (default `15m`) |
| `DATABASE_GROWTH_WARNING_PERCENT` | Projected 7-day storage growth percentage that triggers a growth recommendation (default `20`) |
| `DATABASE_OPERATION_WORKERS`   | Worker pool size for dequeuing confirmed database operations (default `2`) |
| `MAX_CONCURRENT_DATABASE_OPERATIONS` | Cap on simultaneously *executing* database operations, deliberately separate from the VM-side reboot/update caps (default `3`) |
| `DATABASE_OPERATION_TIMEOUT`  | Overall budget for one operation's validate-connect-execute-verify cycle before it's marked `TIMEOUT` (default `300s`) |
| `DATABASE_OPERATION_LOG_MAX_BYTES` | Per-operation cap on persisted live-output-log bytes (default `1048576`, 1MiB) |
| `ALERT_EVAL_INTERVAL`          | How often the alert engine evaluates every enabled rule (default `30s`) |
| `ALERT_STREAM_INTERVAL`        | Push interval for the `/api/alerts/stream` WebSocket (default `15s`) |
| `ALERT_NOTIFICATION_COOLDOWN`  | Minimum gap between repeat notifications for the same (alert, channel, recipient) while an alert stays active (default `15m`) |
| `ALERT_NOTIFICATION_MAX_RETRIES` | Bounded retry attempts for a transient notification-delivery failure, never indefinite (default `3`) |
| `ALERT_WEBHOOK_TIMEOUT`        | Timeout for one webhook notification POST (default `10s`) |
| `ALERT_RETENTION_DAYS`         | How long terminal (RESOLVED/SUPPRESSED) alerts are kept before the daily cleanup job deletes them -- ACTIVE/ACKNOWLEDGED alerts are never touched regardless of age (default `90`) |
| `NOTIFICATION_RETENTION_DAYS`  | How long notification delivery records are kept (default `90`) |

#### Generate a dev encryption key

```bash
cd infrahub-api
go run ./cmd/gen-encryption-key
```

Encrypt the printed value with `go run ./cmd/encrypt-config-value` and paste
the result into `development.ini.enc`/`production.ini.enc` as
`SSH_CREDENTIAL_ENCRYPTION_KEY=ENC(...)`. Generate a fresh one per
environment — never reuse a dev key in staging or production. The server
refuses to start without this variable set.

### `infrahub-ui/.env.local`

| Variable                  | Description                        |
| -------------------------- | ----------------------------------- |
| `NEXT_PUBLIC_API_BASE_URL` | Base URL of the backend API         |
| `NEXT_PUBLIC_MONITORING_REFRESH` | How often the monitoring page polls for new data (default `30s`) — the backend's own collection interval (`VM_MONITOR_INTERVAL`) is separate |

### Root `.env` (optional, for `docker compose`)

For local development's Postgres-only `docker-compose.yml`:

| Variable            | Description                  |
| -------------------- | ----------------------------- |
| `POSTGRES_DB`        | Database name                 |
| `POSTGRES_USER`      | Database user                 |
| `POSTGRES_PASSWORD`  | Database password             |

For the full-stack `docker-compose.prod.yml` (see
[docs/deployment.md](docs/deployment.md)), the same
file (or your shell environment) additionally needs `INFRAHUB_MASTER_KEY`
and `NEXT_PUBLIC_API_BASE_URL` — this is docker compose's own
`${...}`-substitution environment, distinct from
`infrahub-api/development.ini.enc`/`production.ini.enc`, which the
backend container decrypts for its own application config.

Never commit a real `INFRAHUB_MASTER_KEY` or `POSTGRES_PASSWORD` — only
placeholder `.env.example` templates are tracked in git.
`development.ini.enc`/`production.ini.enc` are the exception: they're
safe to commit since every secret value inside is already encrypted.

## 6. Health check

Once the backend is running:

```bash
curl http://localhost:8080/api/health
```

Expected response when the database is reachable (HTTP 200):

```json
{ "status": "ok", "database": "ok" }
```

If PostgreSQL is unavailable, the same endpoint returns HTTP 503:

```json
{ "status": "degraded", "database": "unavailable" }
```

`GET /api/health` is a **readiness** check (is this backend itself ready
to serve requests). `GET /api/live` is a separate **liveness** check --
always `{"status":"ok"}`, no database or other dependency touched -- for
an orchestrator that needs to tell "the process is alive" apart from "its
database happens to be reachable right now." Neither ever depends on any
VM/database/object-storage resource the application merely monitors; see
[docs/deployment.md](docs/deployment.md).

## 7. Project structure

```
.
├── infrahub-api/
│   ├── cmd/
│   │   ├── server/              # main API entrypoint
│   │   ├── migrate/             # goose migration runner (up/down/status/redo)
│   │   ├── seed/                # idempotent reference-data seeder
│   │   ├── bootstrap-admin/     # one-time first-ADMIN creation
│   │   └── gen-encryption-key/  # prints a fresh SSH_CREDENTIAL_ENCRYPTION_KEY
│   ├── internal/
│   │   ├── config/           # environment/config loading
│   │   ├── database/
│   │   │   ├── connection.go # pgx pool creation + tuning
│   │   │   └── generated/    # sqlc-generated queries + models (DO NOT EDIT)
│   │   ├── handlers/         # HTTP handlers (auth, users, access, projects,
│   │   │                     # groups, resources, vms, vm_ssh, vm_monitoring,
│   │   │                     # vm_packages, recommendations, my-access, health)
│   │   ├── httpx/            # shared JSON response helpers
│   │   ├── middleware/       # logging, recovery, CORS, auth/role gates
│   │   ├── models/           # domain types (expanded in a later step)
│   │   ├── pgutil/           # pgtype <-> plain Go type conversions
│   │   ├── repository/       # Store: shared pool + transaction helper
│   │   ├── server/           # router wiring (used by cmd/server and tests)
│   │   └── services/         # password/token/auth/authorization/audit +
│   │                         # project/group/resource/vm/access management +
│   │                         # encryption/credential/hostkey/ssh/discovery +
│   │                         # monitoring (scheduler/collector/parsers/health/retention) +
│   │                         # packages (manager/detector/parsers/version-compare/scheduler)
│   ├── migrations/           # numbered goose SQL migrations
│   ├── sql/queries/          # hand-written SQL that sqlc generates from
│   ├── sqlc.yaml
│   ├── go.mod
│   └── go.sum
├── infrahub-ui/               # Next.js App Router application
│   └── src/
│       ├── app/
│       │   ├── (shell)/       # authenticated pages: dashboard, my-access,
│       │   │                  # admin/users, projects (+ groups), vms
│       │   │                  # (+ monitoring, packages), recommendations
│       │   ├── login/
│       │   └── forbidden/
│       ├── components/
│       │   ├── auth/          # AuthProvider, RouteGuard
│       │   ├── layout/        # sidebar, header, role-aware nav
│       │   └── ui/            # shadcn/ui components
│       ├── lib/api.ts         # typed backend API client
│       └── proxy.ts           # coarse cookie-presence route gate (Next 16's middleware.ts)
├── infrahub-agents/            # agents that run on monitored hosts/clusters/VMs,
│   │                            # NOT part of the app stack above -- see its own README
│   ├── infrahub-docker-agent/
│   ├── infrahub-k8s-agent/
│   └── infrahub-vm-agent/
├── docs/
│   ├── database-architecture.md
│   ├── authorization.md
│   ├── ssh-architecture.md
│   ├── vm-monitoring.md
│   └── package-management.md
└── docker-compose.yml         # local PostgreSQL
```

## Database

The schema is defined entirely in SQL migrations under `infrahub-api/migrations/`
and applied with [goose](https://github.com/pressly/goose) (via
`infrahub-api/cmd/migrate`, so no separate CLI install is required). Query code is
generated by [sqlc](https://sqlc.dev) from `infrahub-api/sql/queries/*.sql` into
`infrahub-api/internal/database/generated/`.

For the full entity-relationship model, the resource/authorization
hierarchy, and design rationale, see
[docs/database-architecture.md](docs/database-architecture.md).

### Run migrations

```bash
cd infrahub-api
go run ./cmd/migrate up
```

### Roll back migrations

```bash
go run ./cmd/migrate down     # roll back one migration
go run ./cmd/migrate status   # show applied/pending migrations
```

### Regenerate sqlc code

After editing anything in `infrahub-api/sql/queries/` or `infrahub-api/migrations/`:

```bash
cd infrahub-api
go run github.com/sqlc-dev/sqlc/cmd/sqlc@latest generate
```

### Seed development data

```bash
cd infrahub-api
go run ./cmd/seed
```

This creates the `ADMIN` and `MEMBER` roles and the fixed permission catalog
if they don't already exist (safe to run repeatedly). It never creates a
user account — admin/user creation is implemented in the authentication
step.

## Authentication & Authorization

Login is cookie-based (HttpOnly access + refresh tokens, Argon2id password
hashing). Authorization is deny-by-default and VM-scoped: an ADMIN sees
everything; a MEMBER sees only VMs granted directly or via group
membership — never by project membership alone. See
[docs/authorization.md](docs/authorization.md) for the full model,
including the 404-vs-403 disclosure policy and the console (`vm.connect`)
authorization primitive a future SSH step will use.

```bash
curl -i -c cookies.txt -X POST http://localhost:8080/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"<BOOTSTRAP_ADMIN_EMAIL>","password":"<BOOTSTRAP_ADMIN_PASSWORD>"}'

curl -b cookies.txt http://localhost:8080/api/auth/me
```

## Infrastructure Management

Admins manage the Project → Group → Resource hierarchy from `/projects`
and `/vms`. Registering a VM (`/vms/new`) only records its configuration
(address, SSH port, username) with status `UNKNOWN` — it never connects to
anything on its own; connecting and discovering the VM's real state is a
separate, explicit step (see [SSH Connectivity & Discovery](#ssh-connectivity--discovery)
below). Deactivating a project, group, or VM
never deletes history (audit/monitoring/operation records are untouched)
and, for groups/VMs, immediately stops granting *new* access without
disturbing other independent grants — see
[docs/authorization.md](docs/authorization.md#6-deactivation-and-effective-access-step-4).

```bash
curl -b cookies.txt -X POST http://localhost:8080/api/projects \
  -H "Content-Type: application/json" -d '{"name":"Backend"}'
```

## SSH Connectivity & Discovery

Admins can attach an SSH private key to a registered VM, test connectivity,
and run a one-shot, read-only discovery pass that fills in OS/kernel/
CPU/memory/storage/Docker information. Full architecture — encryption
format, the trust-on-first-use host-key model, the connection/discovery
status-mapping tables, and production considerations — is documented in
[docs/ssh-architecture.md](docs/ssh-architecture.md). Summary:

- **Credential storage**: `POST`/`PUT /api/vms/:id/credentials/ssh` accepts
  an OpenSSH/PEM private key (unencrypted only — a passphrase-protected key
  is rejected with a clear `"passphrase-protected SSH keys are not
  currently supported"` error), validates it, encrypts it with AES-256-GCM
  under `SSH_CREDENTIAL_ENCRYPTION_KEY`, and stores only the ciphertext. No
  endpoint ever returns the key; responses only ever confirm
  `credential_configured: true/false`.
- **Host-key trust**: the first connection to a VM returns
  `HOST_KEY_UNKNOWN` with the presented fingerprint; an admin must
  explicitly call `POST /api/vms/:id/host-key/trust` to accept it (which
  independently re-dials the host rather than trusting anything the client
  sent). If a previously-trusted host key ever changes, connections stop
  with `HOST_KEY_CHANGED` until an admin reviews and re-trusts it.
- **Connection testing**: `POST /api/vms/:id/connection-test` opens a real
  SSH connection (via `golang.org/x/crypto/ssh`, never by shelling out) and
  reports host/port/username/latency on success, or a safe classified error
  (`SSH_AUTHENTICATION_FAILED`, `SSH_CONNECTION_TIMEOUT`,
  `SSH_CONNECTION_REFUSED`, etc.) on failure — never raw library output.
- **Discovery**: `POST /api/vms/:id/discover` runs a fixed set of read-only
  commands (`cat /etc/os-release`, `uname -r`/`-m`, `hostname`, `nproc`,
  `/proc/meminfo`, `df`, a Docker existence check) over the same
  connection. Partial failures are recorded per-field rather than failing
  the whole run, and a failed discovery never erases previously-known-good
  data.

```bash
# 1. Register a VM (see Infrastructure Management above), then:
curl -b cookies.txt -X POST http://localhost:8080/api/vms/<id>/credentials/ssh \
  -H "Content-Type: application/json" \
  -d '{"ssh_private_key":"-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----\n"}'

curl -b cookies.txt -X POST http://localhost:8080/api/vms/<id>/connection-test
# -> {"status":"host_key_unknown","host_key":{"host":"...","fingerprint":"SHA256:..."}}

curl -b cookies.txt -X POST http://localhost:8080/api/vms/<id>/host-key/trust
curl -b cookies.txt -X POST http://localhost:8080/api/vms/<id>/connection-test
# -> {"status":"connected","host":"...","latency_ms":...}

curl -b cookies.txt -X POST http://localhost:8080/api/vms/<id>/discover
```

Members with `vm.view` may read `GET /api/vms/:id/connection-status` and
`GET /api/vms/:id/discovery` for VMs they're authorized on (same
404-not-403 policy as everywhere else), but cannot configure credentials,
test connections, trust host keys, or trigger discovery.

## VM Monitoring

Once a VM has SSH configured, a background scheduler collects real CPU,
memory, swap, storage, filesystem, network, load average, uptime, and
process-summary metrics on a fixed interval, entirely over the same SSH
connection/credential machinery as above — the browser never talks to a
VM directly, only to the Go API, which reads whatever the scheduler
already stored. Full architecture — the CPU/memory/network delta math,
the health-threshold rules (including why a single CPU spike doesn't flip
health), filesystem filtering, staleness, retention, and failure handling
— is documented in [docs/vm-monitoring.md](docs/vm-monitoring.md).
Summary:

- **Scheduler**: a fixed pool of `VM_MONITOR_WORKERS` goroutines collects
  every `monitoring_enabled` VM with SSH configured, every
  `VM_MONITOR_INTERVAL`. One VM's failure never stops the others; a VM
  still being collected is skipped (never queued twice) if the next cycle
  fires before the previous one finishes.
- **Real data only**: every metric comes from a live `/proc` read or
  `df`/`ps` over SSH — nothing is ever fabricated. CPU% and network
  rates require two samples (they're deltas over time), so a VM's very
  first collection reports them as absent rather than a guess.
- **Health**: `GET /api/vms/:id/monitoring/current` returns a
  `HEALTHY`/`WARNING`/`CRITICAL`/`UNKNOWN`/`OFFLINE` status derived from
  `VM_CPU_*`/`VM_MEMORY_*`/`VM_DISK_*_PERCENT` thresholds — independent
  of (and never overwriting) the VM's connection/resource status.
- **History**: `GET /api/vms/:id/monitoring/history?from=&to=&limit=` is
  bounded (24h default range, 30-day max) and feeds the monitoring page's
  charts.
- **Manual collection**: `POST /api/vms/:id/monitoring/collect`
  (admin-only, rate-limited) triggers one immediate cycle — the
  `[Collect Now]` button on `/vms/:id/monitoring`.
- **Retention**: a daily job deletes monitoring history older than
  `VM_MONITOR_RETENTION_DAYS` — never audit logs or operations.

```bash
curl -b cookies.txt http://localhost:8080/api/vms/<id>/monitoring/current
curl -b cookies.txt -X POST http://localhost:8080/api/vms/<id>/monitoring/collect
curl -b cookies.txt "http://localhost:8080/api/vms/<id>/monitoring/history?limit=100"
```

Members with `vm.view` may read both GET endpoints for VMs they're
authorized on (same 404-not-403 policy as everywhere else); only admins
can toggle `monitoring_enabled` on a VM or trigger manual collection.

## Package Management

A background scheduler (much less frequent than monitoring — every
`PACKAGE_SCAN_INTERVAL`, default 6h) discovers each VM's installed Linux
packages, checks for available updates, classifies which are security
updates from real package-manager evidence, and generates deduplicated
`PACKAGE_UPDATE` recommendations. **Strictly read-only**: no package is
ever installed, upgraded, or removed by this application. Full
architecture — detection, version comparison (never plain string
comparison), security classification, the scan/refresh distinction, and
failure handling — is documented in
[docs/package-management.md](docs/package-management.md). Summary:

- **Supported**: APT/DPKG (Ubuntu, Debian, ...), DNF/RPM (Fedora, RHEL
  8+, Rocky, AlmaLinux), YUM/RPM (RHEL/CentOS 7, Amazon Linux 2) — detected
  from the VM's actual `/etc/os-release`, never assumed. An unsupported
  package manager doesn't fail VM monitoring or mark the VM offline.
- **Scan vs. refresh**: `POST /api/vms/:id/packages/scan` (admin-only)
  does a full cycle — list installed packages, refresh repository
  metadata, check updates. `POST /api/vms/:id/packages/refresh`
  (admin-only) re-checks updates against the already-known inventory
  without re-listing packages — the lighter, more frequent operation.
  Both are rate-limited per VM.
- **Real data only**: every package/version comes from `dpkg-query`/`rpm
  -qa` output; every update from `apt list --upgradable`/`dnf`/`yum
  check-update`. Security classification is `UNKNOWN`, never guessed,
  without real repository evidence.
- **No duplicate recommendations**: repeated scans update the existing
  `PACKAGE_UPDATE` recommendation in place; one resolved automatically
  once the package is upgraded (or removed) and no longer shows the
  update.

```bash
curl -b cookies.txt http://localhost:8080/api/vms/<id>/packages/summary
curl -b cookies.txt -X POST http://localhost:8080/api/vms/<id>/packages/scan
curl -b cookies.txt "http://localhost:8080/api/vms/<id>/packages?search=nginx"
curl -b cookies.txt http://localhost:8080/api/recommendations
```

Members with `vm.view` may read package information for VMs they're
authorized on; `GET /api/recommendations` is restricted to a member's
authorized VMs by the backend (never trust a client-side filter for
this) — only admins can trigger a scan/refresh or acknowledge/dismiss an
update.

## Docker Monitoring

Two independent background schedulers (never combined) give read-only
Docker visibility on any VM with a running Docker daemon: a slow
inventory scan (every `DOCKER_SCAN_INTERVAL`, default 10m) discovers
containers/images/networks/volumes via structured JSON `docker` CLI
output, and a fast metrics collector (every `DOCKER_METRICS_INTERVAL`,
default 15s) runs `docker stats` — one SSH connection and one command per
VM per cycle, covering every running container at once, never one
connection per container. Full architecture — daemon detection, what's
collected vs. deliberately never collected, the metrics/rate-computation
split, the WebSocket live-streaming design, and the real bugs caught
during live verification — is documented in
[docs/docker-monitoring.md](docs/docker-monitoring.md). Summary:

- **Strictly read-only**: no container is ever started, stopped,
  restarted, removed, execed into, or built. No Docker exec/console
  terminal exists in this application.
- **Security-critical**: container environment variables and Docker
  registry/config credentials (`~/.docker/config.json`) are never
  collected or exposed — only explicitly-approved, non-sensitive fields
  are extracted from `docker inspect`'s output.
- **Live metrics**: `GET /api/vms/:id/docker/containers/:containerId/stats/stream`
  is a WebSocket pushing one selected container's cached metrics every
  `DOCKER_STATS_STREAM_INTERVAL` (default 1s) — multiple simultaneous
  viewers share the same collector and cache, never opening additional
  SSH connections.
- **IDOR-safe**: every container-scoped endpoint (REST and WebSocket
  alike) verifies the requested container actually belongs to the
  requested VM — a container that exists on a different VM 404s exactly
  like one that doesn't exist at all.

```bash
curl -b cookies.txt http://localhost:8080/api/vms/<id>/docker
curl -b cookies.txt -X POST http://localhost:8080/api/vms/<id>/docker/scan
curl -b cookies.txt http://localhost:8080/api/vms/<id>/docker/containers
curl -b cookies.txt http://localhost:8080/api/vms/<id>/docker/containers/<containerId>/metrics/current
```

Members with `vm.view` may read Docker information for VMs they're
authorized on; only admins can trigger a scan.

## Update Center

OS release, kernel, and reboot-requirement detection alongside Step 7's
existing package-update data, plus admin-only update *planning*: select
packages, preview the exact command that would apply them, review a
pre-update checklist — **never execution**. OS/kernel/reboot detection
rides on Step 7's existing package-scan scheduler cadence rather than a
new one. Full architecture — detection mechanisms and their honest
limitations, the pre-update checklist's pass/warn/info distinctions,
stale-plan detection, and the real live-verification results (including
a genuine security update carried through the full create → validate →
approve lifecycle with nothing actually installed) — is documented in
[docs/update-center.md](docs/update-center.md). Summary:

- **Never executes an update**: no `apt`/`dnf`/`yum` install/upgrade
  command, no reboot, ever. `UpdateCommandBuilder` only ever generates a
  preview *string* — it has no SSH capability at all, verified by a
  dedicated static test that parses its own source.
- **Never trusts the client**: `POST /api/vms/:id/update-plans` always
  resolves the package's target version from the database itself, never
  from the request body (verified live against a deliberately falsified
  client-submitted version).
- **Admin-only end to end**: every update-plan endpoint — create, view,
  list, validate, approve, cancel — requires ADMIN; members can only read
  update status for VMs they're authorized on, with the same
  never-leak-a-global-count discipline as `/recommendations`.
- **Honest about limitations**: OS release-upgrade detection only works
  for Ubuntu (no safe, universal, read-only mechanism exists for
  Debian/RPM); `PATCH`/`MINOR` OS update types are never fabricated,
  since no safe signal distinguishes them from ordinary package updates.

```bash
curl -b cookies.txt http://localhost:8080/api/vms/<id>/updates/summary
curl -b cookies.txt -X POST http://localhost:8080/api/vms/<id>/updates/refresh
curl -b cookies.txt -X POST http://localhost:8080/api/vms/<id>/update-plans -d '{"items":[{"package_id":"<id>"}]}'
curl -b cookies.txt -X POST http://localhost:8080/api/update-plans/<id>/approve
```

## Update Execution

The first write path in this project: an Admin-approved, Admin-*confirmed*
update plan (Step 9, above) can be executed, running a real
`apt-get`/`dnf`/`yum` upgrade over SSH against exactly the packages
selected — nothing else. Full architecture — the state machine, command
generation/hashing, injection prevention, live log streaming, SSH-
disconnect/crash recovery, and the real live-verification results
(a genuine security update installed, verified via a direct SSH check,
against a disposable test VM) — is documented in
[docs/update-execution.md](docs/update-execution.md). Summary:

- **Never accepts a raw command from the frontend**: `POST
  /api/update-plans/:id/execute` takes exactly `{"confirmation": true}` —
  the backend always generates, validates, and hashes the command itself.
- **Two explicit authorizations, not one**: Step 9's `Approve` (DRAFT →
  READY) is deliberately separate from this step's `Execute`, which
  requires its own confirmation and a checked "I understand and want to
  execute this update" box in the UI.
- **Revalidated immediately before execution**: an approved plan is never
  executed on trust — prechecks re-run fresh right before the database
  claims the VM, and again inside the worker right before connecting.
- **One active operation per VM, enforced by the database**: a
  transactional row lock (`FOR UPDATE`), not just a UI button, so two
  concurrent execute requests for the same VM can never both proceed;
  different VMs execute fully in parallel.
- **Never trusts a nonzero-or-zero exit code**: every selected package's
  *actual installed version* is queried directly from the VM after the
  command runs, and that evidence — never the exit code alone — decides
  SUCCESS/PARTIAL/FAILED.
- **Never auto-reboots, never auto-retries**: reboot state is detected and
  reported only; a failed/partial/interrupted operation always requires a
  new plan and a new explicit execution, never an automatic re-run.

```bash
curl -b cookies.txt -X POST http://localhost:8080/api/update-plans/<id>/execute -d '{"confirmation":true}'
curl -b cookies.txt http://localhost:8080/api/update-operations/<id>
curl -b cookies.txt http://localhost:8080/api/update-operations/<id>/results
```

## Controlled VM Reboot

The second and last write path in this project: an Admin-confirmed
reboot of a real VM, never triggered automatically by `reboot_required`
becoming `true`, by a completed update, or by any scheduler. Full
architecture — the reconnect-with-backoff strategy, the multi-signal
verification logic (boot ID, uptime, kernel, OS, Docker, containers,
packages, reboot-required state) that never fabricates a `SUCCESS`, and
the real live-verification results against a disposable test VM — is
documented in [docs/vm-reboot.md](docs/vm-reboot.md). Summary:

- **Never accepts a raw command**: `POST /api/vms/:id/reboot` takes only
  `{"confirmation": true, "reason": "..."}` — the backend always chooses
  `systemctl reboot` or `reboot`, with a privilege prefix resolved
  server-side.
- **Admin-only, with no grant path**: `vm.reboot` exists in the
  permission catalog but is deliberately never made grantable to a
  Member — only an ADMIN's unconditional authorization bypass can ever
  trigger it.
- **Cross-operation exclusivity**: a VM can never have an update and a
  reboot active at the same time, in either order — enforced by a real
  database transaction, not just a UI button.
- **Never assumes success from SSH reconnecting alone**: boot ID and
  uptime must show genuine evidence of a real reboot before anything is
  reported as verified; a kernel-update reboot specifically fails, with
  an exact message, if the new kernel never actually became active.
- **Never auto-retries, never auto-reboots again**: `TIMEOUT`/`FAILED`/
  `UNKNOWN` operations require an explicit new reboot request; a
  `[Retry Verification]` action re-checks the VM's real state without
  ever sending another reboot command.

```bash
curl -b cookies.txt -X POST http://localhost:8080/api/vms/<id>/reboot -d '{"confirmation":true}'
curl -b cookies.txt http://localhost:8080/api/reboot-operations/<id>
curl -b cookies.txt http://localhost:8080/api/reboot-operations/<id>/results
```

## Database Monitoring

**Standalone, not VM-attached.** A database is a first-class resource
under a Project (optionally a Group) — `Project → Databases`, alongside
`Project → Groups → VMs`, never a VM child and never reached over SSH.
Postgres, MySQL, MariaDB, MongoDB, Redis, and Valkey are all connected
directly via TCP/TLS using each engine's own official Go driver
(`pgx`, `go-sql-driver/mysql`, `mongo-driver`, `go-redis`). Monitoring
itself is still **strictly read-only** — no SQL console, no arbitrary
query/command execution, no database mutation of any kind — every query
this layer runs is backend-defined and hardcoded (see "Database
Operations" below for the separate, explicitly-confirmed remediation
layer that *is* allowed to change a small, fixed set of things).

- **Discovers, never assumes**: connection status, health, and monitoring
  state are tracked as independent facts — a database can be `CONNECTED`
  yet report a `WARNING` health at the same time.
- **Least-privilege monitoring credentials**: a dedicated, encrypted
  `standalone_database_credentials` table; passwords are never returned
  by any API response, only a username and a `credential_configured`
  boolean.
- **A Member's access is explicit and layered**: group membership grants
  only `database.view`/`database.performance` by default —
  `database.browser`/`database.logs`/`database.query_details` must each
  be granted individually, and remediation (`database.operations.*`,
  see below) is Admin-only with no grant path at all.
- **Never fabricates a metric**: a metric that couldn't be read is simply
  absent, never a fake zero; cumulative counters are converted to real
  rates using the previous snapshot, with restart detection so a counter
  reset is never reported as a negative rate.

```bash
curl -b cookies.txt -X POST http://localhost:8080/api/databases \
  -d '{"project_id":"<id>","type":"POSTGRESQL","host":"db.internal","port":5432,"database_name":"app"}'
curl -b cookies.txt http://localhost:8080/api/databases
curl -b cookies.txt http://localhost:8080/api/databases/<id>/metrics/current
```

## Database Performance Monitoring

Still strictly read-only. A second, much slower collection cycle layered
on top of the fast one above — expensive query rankings, lock/wait
detail, replication lag, and storage growth are collected on
`DATABASE_DEEP_METRICS_INTERVAL` (default `60s`), entirely separate from
the cheap `DATABASE_METRICS_INTERVAL` (`15s`) cycle, so a slow or failing
deep collection can never delay or disrupt basic connection/health
monitoring.

- **Query text is private by default**: `DATABASE_QUERY_TEXT_CAPTURE`
  defaults to `false` — only a query's fingerprint and numeric stats
  (calls/latency/rows) are ever stored. Even when capture is enabled, the
  text is shown only to an Admin or a Member explicitly granted
  `database.query_details`.
- **Health with reasons, never a bare score**: "WARNING — Connection
  utilization is 86%. 2 sessions are blocked. Query p95 latency is
  1800ms." is more useful and more honest than a single 0–100 number.
- **A hard cap on monitoring's own footprint**:
  `DATABASE_MONITOR_MAX_CONNECTIONS` bounds how many simultaneous
  connections this application's own fast+deep monitoring combined can
  ever open to a target database, regardless of configured worker counts.
- **Observation feeds remediation, but never triggers it**: a blocked
  session or slow query surfaces here as a recommendation only — turning
  that into an actual `pg_terminate_backend`/`KILL`/etc. call always
  requires an Admin to explicitly review and confirm it through the
  Database Operations layer below; nothing in this monitoring layer can
  cause it on its own.

```bash
curl -b cookies.txt http://localhost:8080/api/databases/<id>/performance
curl -b cookies.txt http://localhost:8080/api/databases/<id>/queries
curl -b cookies.txt http://localhost:8080/api/databases/<id>/locks
curl -b cookies.txt http://localhost:8080/api/databases/performance
```

## Database Operations

Admin-only, explicitly-confirmed remediation layered on top of the
read-only monitoring above — never automatic, never arbitrary. Flow:
**Recommendation → Review → Operation Plan → Confirmation → Execute →
Live Output → Result → Audit.** Full architecture — the per-engine
capability tables, validation checklist, timeout/exclusivity handling,
and audit events — is documented in
[docs/database-operations.md](docs/database-operations.md). Summary:

- **A small, closed set of backend-defined templates**: cancel query /
  terminate session (PostgreSQL, MySQL/MariaDB), kill operation
  (MongoDB), kill client / background save (Redis, Valkey), plus
  PostgreSQL `VACUUM`/`ANALYZE` — never arbitrary SQL, Redis, MongoDB, or
  shell commands, and every command is shown to the Admin verbatim
  (`command_preview`) before it can be confirmed.
- **Admin-only, no grant path at all**: unlike every other database
  permission, `database.operations.view/execute/cancel/retry` are never
  granted by group membership or a direct grant — mirroring `vm.reboot`'s
  precedent exactly.
- **Operation-queue exclusivity**: at most one operation may be
  confirmed/running against a given database at a time, enforced by a
  row-locked transactional claim, the same pattern Step 11's reboot
  exclusivity uses.
- **A bounded timeout, never a stuck "RUNNING" forever**:
  `DATABASE_OPERATION_TIMEOUT` (default `300s`) bounds the whole
  validate-connect-execute-verify window.
- **Verifies its own outcome**: after executing, the backend reconnects
  and re-checks health, distinguishing "Operation successful; database is
  healthy" from "...but the database requires attention" in the result.

```bash
curl -b cookies.txt http://localhost:8080/api/databases/<id>/operations/capabilities
curl -b cookies.txt -X POST http://localhost:8080/api/databases/<id>/operations/preview \
  -d '{"operation_type":"VACUUM","parameters":{}}'
curl -b cookies.txt -X POST http://localhost:8080/api/databases/<id>/operations \
  -d '{"operation_type":"VACUUM","parameters":{},"reason":"scheduled maintenance"}'
curl -b cookies.txt -X POST http://localhost:8080/api/databases/<id>/operations/<operationId>/confirm
```

## Central Alerts & Notifications

Connects the read-only monitoring/recommendations layer above to a
stateful alert lifecycle and a notification system — never a remediation
trigger. Flow: **VM/Docker/Database → Metrics → Health/Recommendation →
Alert Rule → Alert → Notification → Admin/authorized user.** Full
architecture — duration/hysteresis gating, deduplication, the
notification-provider interface, engine resilience, and authorization —
is documented in [docs/alerts.md](docs/alerts.md). Summary:

- **Kept separate from recommendations**: a recommendation is advisory
  (Step 7/13, no duration gate); an alert is a stateful,
  threshold+duration-gated, deduplicated lifecycle (`ACTIVE` →
  `ACKNOWLEDGED`/`RESOLVED`/`SUPPRESSED`) that drives real notifications.
- **No alert from a single bad sample**: a rule's condition must hold
  continuously for its configured `duration_seconds` before an alert is
  created; a flapping metric resets the breach timer instead of
  accumulating toward one.
- **Hysteresis, not flapping WARNING → RESOLVED → WARNING**: an optional
  `recovery_threshold` (e.g. trigger at CPU > 90%, resolve at CPU < 75%)
  — recovery itself is never duration-gated, one good sample resolves
  immediately.
- **One ongoing issue, one alert**: identity is the alert rule itself,
  enforced by both the evaluation engine and a database-level unique
  constraint — never one alert per evaluation cycle.
- **A small, extensible notification-provider interface**: `IN_APP` and
  a real `WEBHOOK` POST (exactly `alert_id`/`severity`/`resource`/
  `alert_type`/`current_value`/`threshold`/`status`/`timestamp`, never a
  credential) are wired up today; `EMAIL`/`SLACK`/`TEAMS` are valid
  channel values with no registered provider yet, never a fabricated
  delivery.
- **Never automatic remediation**: an alert only notifies — Step 14's
  database operations remain the only execution path in this project,
  always Admin-reviewed and explicitly confirmed.

```bash
curl -b cookies.txt http://localhost:8080/api/alerts?status=ACTIVE
curl -b cookies.txt http://localhost:8080/api/alerts/summary
curl -b cookies.txt -X POST http://localhost:8080/api/alert-rules \
  -d '{"resource_id":"<id>","alert_type":"VM_HIGH_CPU","condition":">","threshold":90,"duration_seconds":300,"severity":"WARNING","enabled":true}'
curl -b cookies.txt -X POST http://localhost:8080/api/alerts/<id>/acknowledge
curl -b cookies.txt http://localhost:8080/api/notifications
```

## Object Storage

A first-class resource (AWS S3 / DigitalOcean Spaces / MinIO / any generic
S3-compatible endpoint), monitored directly over the S3 API — never a VM
child, never SSH. Full architecture — credential handling, the fast/deep
metrics split, bucket security facts, and the read-only object browser —
is documented in [docs/object-storage.md](docs/object-storage.md). Summary:

- **Connection**: endpoint, region, access key ID, secret key, bucket, and
  an optional base path. The secret key is encrypted at rest with the same
  `SSH_CREDENTIAL_ENCRYPTION_KEY` every other credential in this project
  uses, and is never returned in any API response.
- **Monitoring**: a fast, HeadBucket-only reachability/latency cycle, plus
  a slower deep cycle for bucket security facts (versioning/encryption/
  public-access/object-lock), growth tracking, and CloudWatch metrics
  (AWS only).
- **Read-only browser**: object listing/prefix navigation, metadata,
  short-lived presigned-URL download, and text/JSON preview — no write,
  delete, or upload S3 call exists anywhere in this feature.

```bash
curl -b cookies.txt http://localhost:8080/api/object-storage
curl -b cookies.txt http://localhost:8080/api/object-storage/<id>/security
curl -b cookies.txt http://localhost:8080/api/object-storage/<id>/objects
```

## Users, Permissions & Access Control

`/admin/users` (search/filter/pagination, role changes) and `/permissions`
(the cross-resource-type direct-grant ledger for VM/Database/Object
Storage) on top of the authorization model every earlier step already
enforces — no new grant mechanism, no dynamic roles. Full details,
including the 404-vs-403 IDOR disclosure policy and the last-active-admin/
self-demotion safety invariants, are documented in
[docs/authorization.md §11](docs/authorization.md#11-step-18-central-user-management-roles-permissions--resource-access-control).

## Central Monitoring Dashboard

`GET /api/monitoring/{overview,resources,timeline}` — a unified,
cross-resource-type view (VM/Database/Object Storage/Docker health,
Alerts, Recommendations) reusing the exact same authorized-resource merge
every other endpoint uses, so an unauthorized resource can never appear in
it. Documented in
[docs/authorization.md §12](docs/authorization.md#12-step-19-central-infrastructure-monitoring--observability-dashboard).

## Security, Hardening & Deployment

Step 20 is a review-and-harden pass over Steps 1–19, not a new feature —
see [docs/security-hardening.md](docs/security-hardening.md) for what was
audited, what was already correct, and what was changed. Running this in
production (Docker images, environment configuration, health checks,
backup/recovery) is covered in [docs/deployment.md](docs/deployment.md).

## Roadmap

Step 20 (this step) is the final step of the current implementation plan:
it hardens Steps 1–19, it does not add new resource types or execution
paths. Every resource type planned for this application (VM, Docker,
standalone database, object storage) now has monitoring, and authorization
is enforced server-side for all four — see
[docs/authorization.md](docs/authorization.md) (VM, plus §11's Step 18
extension to Database/Object Storage) and
[docs/object-storage.md](docs/object-storage.md).

This project intentionally does **not** include, by design, not as a gap:
an interactive web terminal or any arbitrary command execution (the only
write paths anywhere in this project are the exact, backend-generated,
Admin-confirmed package-update, reboot, and database-remediation commands
described in [docs/update-execution.md](docs/update-execution.md),
[docs/vm-reboot.md](docs/vm-reboot.md), and
[docs/database-operations.md](docs/database-operations.md) — never a
client-supplied command, never anything else); OS *release* upgrade
execution (Step 9's `do-release-upgrade` command remains preview-only);
Docker *mutation* of any kind (inventory/metrics only, never
start/stop/restart — see
[docs/docker-monitoring.md](docs/docker-monitoring.md)); database
*mutation* or a SQL/command console beyond Step 14's small, closed
remediation template set (never arbitrary SQL/Redis/MongoDB/shell,
database restart, or schema changes); and destructive object-storage
operations (the browser is read-only end to end — see
[docs/object-storage.md](docs/object-storage.md)).

Known, accepted limitations after the Step 20 hardening pass — see
[docs/security-hardening.md](docs/security-hardening.md) for the full
list and reasoning:

- The frontend has dark-mode CSS scaffolding (`dark:` Tailwind classes)
  but no theme provider or toggle wired up yet — every page renders in
  light mode only.
- The in-memory login rate limiter (`internal/middleware/ratelimit.go`) is
  per-process: it resets on restart and does not coordinate across
  multiple backend replicas. Fine for this project's single-instance
  deployment model; a horizontally-scaled deployment would need a shared
  store instead.
- A handful of read-only WebSocket streams (database metrics/performance,
  update/reboot/database-operation logs) check authorization once at
  connect time, not on every subsequent push; a permission revoked
  mid-stream doesn't proactively cut an already-open connection. The
  exposure window is bounded in practice (log streams end when their
  operation reaches a terminal status; metric streams only ever serve
  already-authorized-at-connect-time data), but it is not enforced the way
  a REST call's per-request check is.
