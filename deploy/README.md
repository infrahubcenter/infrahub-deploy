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
| `infrahubcenter/infrahub-vm-agent` | Agent for Linux VMs (also tagged `infrahub-{linux,windows,mac}-os-agent`) |
| `infrahubcenter/infrahub-k8s-agent` | In-cluster Kubernetes agent |
| `infrahubcenter/infrahub-site` | Public marketing site |

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

Upgrade: change `INFRAHUB_VERSION` in `.env`, then
`docker compose pull && docker compose up -d`.

## Kubernetes

```bash
kubectl create namespace infrahub
kubectl -n infrahub create secret generic infrahub-secrets \
  --from-literal=postgres-password="$(openssl rand -hex 24)" \
  --from-literal=jwt-secret="$(openssl rand -hex 48)" \
  --from-literal=ssh-credential-encryption-key="$(openssl rand -base64 32)" \
  --from-literal=bootstrap-admin-password='<first-admin-password>'

curl -fsSLO https://raw.githubusercontent.com/infrahubcenter/infrahub-deploy/main/deploy/kubernetes/infrahub.yaml
nano infrahub.yaml   # PUBLIC_URL and BOOTSTRAP_ADMIN_EMAIL in the ConfigMap
kubectl apply -f infrahub.yaml
kubectl -n infrahub get pods,svc
```

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
