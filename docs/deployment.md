# Deployment (Step 20)

How to run Infra Hub Center outside of local development: architecture,
configuration, health checks, graceful shutdown, container images, and a
backup/recovery strategy. This step does not assume a specific cloud
provider — every configurable value is an environment variable (see
`infrahub-api/.env.example` for the optional ones, and
`infrahub-api/production.ini.enc` for the required, secret-shaped ones --
§2 below explains the split), and the container images built here run
anywhere Docker does.

## 1. Deployment architecture

```
Internet / internal network
          |
          v
     Reverse proxy (nginx / Caddy / your load balancer -- TLS
     termination, the single public entry point)
          |
          +---- Next.js frontend  (infrahub-ui/Dockerfile,  port 3000)
          |
          +---- Go backend API    (infrahub-api/Dockerfile, port 8080)
                    |
                    +---- PostgreSQL (this application's own database)
                    |
                    +---- VM / SSH               (admin-registered)
                    +---- Docker (over SSH)       (admin-registered)
                    +---- External databases      (admin-registered)
                    +---- S3-compatible storage    (admin-registered)
```

Neither Dockerfile bundles a reverse proxy or TLS certificate handling —
that's expected to sit in front of both services. `FRONTEND_ORIGIN` (CORS)
and `COOKIE_SECURE` (both in `infrahub-api/production.ini.enc`) must match
whatever origin and scheme (https in production) the proxy actually
exposes the frontend at.

## 2. Environment configuration

Required, secret-shaped values live in
`infrahub-api/development.ini.enc`/`production.ini.enc` (see either
file's own header comment, and `internal/config/encrypted_env.go`) --
every secret VALUE inside is AES-256-GCM encrypted (wrapped as
`ENC(...)`), which is what makes these files safe to commit, unlike the
plaintext `.env` this project used before. Everything else -- connection
pooling, every monitoring cadence, alert thresholds, and the Step 20
additions below, none of it secret -- is a plain environment variable
with a built-in default; see `infrahub-api/.env.example` for the full
documented list and `infrahub-ui/.env.example` for the frontend's two
variables.

Three backend variables are required — the server refuses to start
without them (`internal/config/config.go`'s `Load` fails fast rather than
running with an insecure default):

- `DATABASE_URL` — this application's own PostgreSQL connection string.
- `JWT_SECRET` — signs access tokens. Rotating it invalidates every
  existing session immediately.
- `SSH_CREDENTIAL_ENCRYPTION_KEY` — AES-256 key (base64, 32 bytes,
  generate with `go run ./cmd/gen-encryption-key`) that encrypts every
  stored secret (SSH private keys, database passwords, S3 secret keys)
  before it reaches PostgreSQL. **Back this up separately from the
  database** — see §5 below; losing it makes every stored credential
  permanently unrecoverable, by design.

Step 20 added three more, all optional with safe defaults:

- `MAX_REQUEST_BODY_BYTES` (default `2097152`, 2 MiB) — caps every
  request body via `middleware.MaxBody`.
- `LOGIN_RATE_LIMIT_ATTEMPTS` / `LOGIN_RATE_LIMIT_WINDOW` (default `10`
  per `5m`) — per-source-IP brute-force protection on
  `POST /api/auth/login` only (`internal/middleware/ratelimit.go`).

`APP_ENV=production` (vs. the `development` default) changes exactly one
thing directly: `COOKIE_SECURE` defaults to `true` instead of `false`
(still overridable either way). Everything else that differs between a
local and a production deployment — CORS origin, log verbosity via the
standard library's `slog` JSON handler already in use, every monitoring
cadence — is controlled by its own explicit variable, not inferred from
`APP_ENV`.

## 3. Health checks

- **`GET /api/live`** — liveness. Always `{"status":"ok"}`, touches
  nothing. Use this for a restart-on-failure probe.
- **`GET /api/health`** — readiness. `{"status":"ok","database":"ok"}`
  (200) when this backend's own PostgreSQL connection pool is reachable,
  `{"status":"degraded","database":"unavailable"}` (503) otherwise. Use
  this for a load-balancer/traffic-routing probe.

Neither depends on any VM, standalone database, or object storage the
application merely *monitors* — one unreachable piece of managed
infrastructure can never make the platform itself report unhealthy (see
`internal/handlers/health.go`).

## 4. Graceful shutdown

`cmd/server/main.go` listens for `SIGINT`/`SIGTERM`
(`signal.NotifyContext`), stops accepting new connections
(`http.Server.Shutdown`, 10s deadline), and only then returns from `run()`
— which blocks on a `sync.WaitGroup` covering all 17 background
schedulers/workers (VM/Docker/database/object-storage monitoring, package
scanning, alert evaluation, update/reboot/database-operation execution
workers, retention sweeps), every one of which selects on the same
`ctx.Done()` and exits cleanly rather than being killed mid-cycle. No
change was needed here for Step 20 — this was already in place since
Step 6 and extended consistently through every later background worker.

## 5. Backup & recovery

This application does not include automated backup tooling; back up the
following using your existing PostgreSQL backup process
(`pg_dump`/`pg_basebackup`/your managed database provider's snapshots):

- **The `vmcc` PostgreSQL database** — every table this application owns:
  users/roles/permissions, projects/groups/resources, encrypted
  credentials, monitoring history, alerts, audit logs, operation records.
  Standard PostgreSQL backup/recovery practices apply directly (this
  project makes no unusual demands on the backup process — no
  `LISTEN`/`NOTIFY` state, no advisory locks held outside a single
  transaction, no extension beyond `pgcrypto`/`uuid-ossp`-equivalent
  built-ins used by the migrations).
- **`SSH_CREDENTIAL_ENCRYPTION_KEY`, separately from the database** — the
  `credentials`/`standalone_database_credentials`/
  `standalone_object_storage_credentials` tables only ever hold
  ciphertext (see `docs/ssh-architecture.md` and
  `docs/security-hardening.md` §Secret Management). Restoring a database
  backup without this exact key makes every stored credential
  permanently undecryptable — there is no recovery path around that, by
  design. Store it in the same secrets manager/vault your deployment
  otherwise uses for `JWT_SECRET`, not alongside routine database backups.
- **`JWT_SECRET`** — not required for data recovery (losing it only
  invalidates existing sessions, forcing every user to log in again), but
  keep it stable across a restore if you want existing sessions to
  survive.

Recovery considerations:

- Restoring an older database snapshot naturally rolls back
  monitoring/alert/audit history to that point — expected, not a bug.
- After restoring, run `go run ./cmd/migrate status` (or the equivalent
  `./migrate status` inside the backend container) before starting the
  application, to confirm the restored schema's migration version matches
  what this codebase expects; run `up` if it's behind.
- A restored database paired with the *wrong*
  `SSH_CREDENTIAL_ENCRYPTION_KEY` will not error loudly at startup —
  every decrypt attempt (e.g. the next scheduled VM monitoring cycle,
  or an admin opening a database's credential) will fail individually.
  Confirming the key matches before bringing traffic back is a manual
  step operators must perform, not something this application can
  self-verify.

## 6. Container images

`infrahub-api/Dockerfile` and `infrahub-ui/Dockerfile` are new in Step 20
(neither existed before). Both are multi-stage, produce a small final
image, run as a non-root user, and never bake a secret into a layer —
every secret VALUE is AES-256-GCM encrypted in the `.ini.enc` file that
does get baked in (see §2 above); only `INFRAHUB_MASTER_KEY` itself is
supplied at container-start, via environment variables, never a file.
Neither replaces local development: `README.md`'s "Start the Go
backend"/"Start the Next.js frontend" sections (`go run ./cmd/server`,
`npm run dev`) are unaffected by either file's existence. To run the
published images instead of building from source, use
[deploy/docker](../deploy/docker/docker-compose.yml) or
[deploy/kubernetes](../deploy/kubernetes/infrahub.yaml) -- see
[deploy/README.md](../deploy/README.md).

```bash
# Build (from the repo root)
docker build -t infrahub-api ./infrahub-api
docker build --build-arg NEXT_PUBLIC_API_BASE_URL=https://api.example.com \
  -t infrahub-ui ./infrahub-ui

# Or bring up the full stack (Postgres + backend + frontend) at once --
# see docker-compose.prod.yml's own header comment for required variables.
docker compose -f docker-compose.prod.yml up -d --build

# Run migrations inside the built backend image (the compiled `migrate`
# binary and the migrations/ directory both travel with the image):
docker compose -f docker-compose.prod.yml exec infrahub-api ./migrate up
```

`infrahub-ui/Dockerfile` bakes `NEXT_PUBLIC_API_BASE_URL` into the client
JavaScript bundle at *build* time (Next.js's own behavior for any
`NEXT_PUBLIC_*` variable, unrelated to this project) — rebuild the image
if that URL ever needs to change, setting the environment variable at
container start has no effect on it.

`docker-compose.yml` (unchanged, still local-development-only: just
Postgres) and `docker-compose.prod.yml` (new: Postgres + backend +
frontend, all built from source) are deliberately separate files so
`docker compose up` during day-to-day development is unaffected by the
production compose file's existence.

The Docker/Kubernetes/VM Agents are a separate concern entirely -- they
run on the machines/clusters being *monitored*, not as part of this
stack, and are already built and published to Docker Hub rather than
built by an operator deploying InfraHub itself. See
`infrahub-agents/README.md` for what each one is and how to rebuild/push
a new version when their code changes.
