# Deploying Infra Hub Center

Everything here runs the published images from
[docker.io/infrahubcenter](https://hub.docker.com/u/infrahubcenter) --
nothing is built on the target server. All images are multi-arch
(linux/amd64, linux/arm64) and tagged with the release version (`1.0.0`)
plus `latest`.

| Image | Role |
|---|---|
| `infrahubcenter/infrahub-api` | Go API + schedulers; runs migrations, seed and first-admin creation on start |
| `infrahubcenter/infrahub-ui` | Web console |
| `infrahubcenter/infrahub-gateway` | nginx entry point: `/api/*` (incl. WebSockets) to the API, everything else to the console |
| `infrahubcenter/infrahub-docker-agent` | Agent for Docker hosts |
| `infrahubcenter/infrahub-vm-agent` | Agent for Linux VMs (metrics + journal logs) |
| `infrahubcenter/infrahub-k8s-agent` | In-cluster Kubernetes agent |
| `infrahubcenter/infrahub-site` | Public marketing site |
| `postgres:16-alpine` (optional) | Built-in database -- or use a managed PostgreSQL via `DATABASE_URL` |

## Docker Compose

```bash
mkdir -p ~/infrahub && cd ~/infrahub
curl -fsSLO https://raw.githubusercontent.com/infrahubcenter/infrahub-deploy/main/deploy/docker/docker-compose.yml
curl -fsSL https://raw.githubusercontent.com/infrahubcenter/infrahub-deploy/main/deploy/docker/.env.example -o .env

sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(openssl rand -hex 24)|" .env
sed -i "s|^JWT_SECRET=.*|JWT_SECRET=$(openssl rand -hex 48)|" .env
sed -i "s|^SSH_CREDENTIAL_ENCRYPTION_KEY=.*|SSH_CREDENTIAL_ENCRYPTION_KEY=$(openssl rand -base64 32)|" .env
nano .env        # PUBLIC_URL, BOOTSTRAP_ADMIN_EMAIL, BOOTSTRAP_ADMIN_PASSWORD (12+ chars)

docker compose up -d
curl -s http://localhost/api/health
```

`PUBLIC_URL` must be the address browsers **and agents** use to reach the
server (its IP or domain -- not `localhost` when agents run elsewhere).
Behind HTTPS, set `PUBLIC_URL=https://...` and `COOKIE_SECURE=true`.

**Database -- built-in or managed.** `.env.example` enables the built-in
PostgreSQL container (`COMPOSE_PROFILES=postgres`). For a managed database
(AWS RDS/Aurora, Google Cloud SQL, Azure Database for PostgreSQL, or your
own PostgreSQL 14+ server), delete that line and set:

```bash
DATABASE_URL=postgres://infrahub:<password>@<db-host>:5432/infrahub?sslmode=require
```

The postgres container is then not started at all; the API creates every
table in the (empty) database on first start.

Upgrade: change `INFRAHUB_VERSION` in `.env`, then
`docker compose pull && docker compose up -d`.

## Kubernetes

```bash
kubectl create namespace infrahub

# Managed database:
kubectl -n infrahub create secret generic infrahub-secrets \
  --from-literal=database-url='postgres://infrahub:<password>@<db-host>:5432/infrahub?sslmode=require' \
  --from-literal=jwt-secret="$(openssl rand -hex 48)" \
  --from-literal=ssh-credential-encryption-key="$(openssl rand -base64 32)" \
  --from-literal=bootstrap-admin-password='<first-admin-password>'

# ...or built-in database: use these two keys instead of the database-url above
#   PGPW=$(openssl rand -hex 24)
#   --from-literal=postgres-password="$PGPW"
#   --from-literal=database-url="postgres://infrahub:$PGPW@infrahub-postgres:5432/infrahub?sslmode=disable"
# and: kubectl apply -f https://raw.githubusercontent.com/infrahubcenter/infrahub-deploy/main/deploy/kubernetes/postgres.yaml

curl -fsSLO https://raw.githubusercontent.com/infrahubcenter/infrahub-deploy/main/deploy/kubernetes/infrahub.yaml
nano infrahub.yaml   # PUBLIC_URL and BOOTSTRAP_ADMIN_EMAIL in the ConfigMap
kubectl apply -f infrahub.yaml
kubectl -n infrahub get pods,svc
```

## Individual containers

Each service is its own image, so it can run on any orchestrator (ECS,
Nomad, Swarm, plain Docker):

| Container | Image | Port | Required settings |
|---|---|---|---|
| infrahub-api | `docker.io/infrahubcenter/infrahub-api:1.0.0` | 8080 | `DATABASE_URL`, `JWT_SECRET`, `SSH_CREDENTIAL_ENCRYPTION_KEY`, `PUBLIC_URL`, `INFRAHUB_CONFIG_DIR=/etc/infrahub` (env-only config) |
| infrahub-ui | `docker.io/infrahubcenter/infrahub-ui:1.0.0` | 3000 | optional `INFRAHUB_PLAN`, `INFRAHUB_MARKETING_URL` |
| infrahub-gateway | `docker.io/infrahubcenter/infrahub-gateway:1.0.0` | 80 | optional `INFRAHUB_API_UPSTREAM` (default `infrahub-api:8080`), `INFRAHUB_UI_UPSTREAM` (default `infrahub-ui:3000`) |
| postgres (optional) | `postgres:16-alpine` | 5432 | `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` |

Only the gateway needs a published port. Full `docker run` examples are on
the site's installation page (Method 3).

The gateway Service is `type: LoadBalancer`. With an Ingress controller,
switch it to `ClusterIP` and apply [kubernetes/ingress.yaml](kubernetes/ingress.yaml).

## Building the images yourself

Each image builds from its own repository's `Dockerfile`
(`infrahub-api`, `infrahub-ui`, `infrahub-site`, `infrahub-docker-agent`, `infrahub-k8s-agent`, `infrahub-vm-agent`), and
the gateway from [gateway/](gateway/):

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -t docker.io/infrahubcenter/infrahub-gateway:1.0.0 --push deploy/gateway
```

## Hosting the console separately (e.g. Vercel) with a private backend

The console can run on its own host while the API stays on your server:

- **Console** (`infrahub-ui`) settings: `INFRAHUB_BACKEND_URL` (the API's
  address, server-side only), `INFRAHUB_PROXY_KEY` (shared secret),
  `INFRAHUB_WS_BASE_URL` (the API's public `wss://` address). Browsers call
  the console's own `/api/*`, which proxies to the API with the key, so the
  login cookie stays on the console's domain and the key never reaches the
  browser. WebSockets go straight to the API with a 2-minute ticket.
- **API** settings: the same `INFRAHUB_PROXY_KEY` (every non-WebSocket
  request without it is refused, except health checks) and `FRONTEND_ORIGIN`
  listing each console origin, comma-separated. Set `APP_BASE_URL` and
  `OAUTH_REDIRECT_BASE_URL` to the console's address.
- **Gateway**: pass the same `INFRAHUB_PROXY_KEY` so a local console behind
  it keeps working.
