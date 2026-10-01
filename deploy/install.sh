#!/usr/bin/env bash
# Infra Hub Center -- one-command installer for a Linux server.
#
#   curl -fsSL https://raw.githubusercontent.com/infrahubcenter/infrahub-deploy/main/deploy/install.sh | sudo bash
#
# What it does:
#   1. installs Docker Engine + Compose if they're missing (Docker's official script)
#   2. puts the compose file and settings in /opt/infrahub
#   3. generates every secret, asks for your address and the first admin
#   4. starts Infra Hub Center and waits until it answers
# Run it again later to upgrade -- your settings and data are kept.
#
# Unattended (no questions), e.g. from cloud-init:
#   curl -fsSL .../install.sh | sudo bash -s -- --yes \
#     --url https://infrahub.example.com --admin-email you@example.com
#
# Options:
#   --url URL              address people and agents use (default: http://<server IP>)
#   --admin-email EMAIL    first admin account (default: admin@<hostname>)
#   --admin-password PASS  12+ characters (default: generated and shown at the end)
#   --license KEY          license key for a paid plan (default: free Community)
#   --database-url URL     use your managed PostgreSQL instead of the built-in one
#   --port PORT            host port for the web console (default 80)
#   --dir DIR              install folder (default /opt/infrahub)
#   --version TAG          image tag (default 1.0.0)
#   --yes                  don't ask anything, use the values above / defaults
set -euo pipefail

DEPLOY_RAW="${INFRAHUB_DEPLOY_RAW:-https://raw.githubusercontent.com/infrahubcenter/infrahub-deploy/main/deploy}"
DIR=/opt/infrahub
URL="" ADMIN_EMAIL="" ADMIN_PASSWORD="" LICENSE="" DATABASE_URL="" PORT=80 VERSION=1.0.0 ASSUME_YES=0

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok() { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }
die() { printf '\n\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    --admin-email) ADMIN_EMAIL="$2"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
    --license) LICENSE="$2"; shift 2 ;;
    --database-url) DATABASE_URL="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,30p' "$0" 2>/dev/null || echo "see https://infrahub-site.vercel.app/install"; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
done

# Questions work even when the script is piped into bash (curl ... | bash).
TTY=""
if [ "$ASSUME_YES" = 0 ] && [ -r /dev/tty ] && { : < /dev/tty; } 2>/dev/null; then TTY=/dev/tty; fi
ask() { # ask VAR "Question" "default" [secret]
  local var="$1" question="$2" default="$3" secret="${4:-}" answer=""
  if [ -n "$TTY" ]; then
    if [ -n "$secret" ]; then
      read -r -s -p "    $question: " answer < "$TTY"; echo > "$TTY"
    else
      read -r -p "    $question [$default]: " answer < "$TTY"
    fi
  fi
  printf -v "$var" '%s' "${answer:-$default}"
}

rand_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
rand_b64() { head -c "$1" /dev/urandom | base64 | tr -d '\n'; }

# set_env KEY VALUE: set (or add) KEY=VALUE in .env without any escaping trouble.
set_env() {
  KEY="$1" VALUE="$2" awk 'BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VALUE"]; done = 0 }
    $0 ~ "^#? *" k "=" { if (!done) { print k "=" v; done = 1 }; next }
    { print }
    END { if (!done) print k "=" v }' .env > .env.tmp && chmod 600 .env.tmp && mv .env.tmp .env
}

echo
bold "Infra Hub Center installer"
echo "    Monitoring, logs, patching and access control for VMs, Docker, Kubernetes, databases and S3."

# ---------------------------------------------------------------- checks
step "Checking this server"
[ "$(uname -s)" = Linux ] || die "this installer is for Linux servers. On Windows or macOS install Docker Desktop and follow the Docker Compose steps at https://infrahub-site.vercel.app/install"
[ "$(id -u)" = 0 ] || die "please run as root: curl -fsSL .../install.sh | sudo bash"
case "$(uname -m)" in x86_64|amd64|aarch64|arm64) ok "Linux $(uname -m)" ;; *) die "unsupported CPU $(uname -m) -- images are built for x86_64 and arm64" ;; esac
command -v curl >/dev/null || die "curl is required (apt install curl / dnf install curl)"
mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
if [ "$mem_mb" -gt 0 ] && [ "$mem_mb" -lt 3500 ]; then warn "${mem_mb} MB RAM -- 4 GB or more is recommended"; else ok "${mem_mb} MB RAM"; fi

# ---------------------------------------------------------------- docker
step "Docker"
if ! command -v docker >/dev/null; then
  echo "    Docker isn't installed -- installing it with Docker's official script (takes a minute)..."
  curl -fsSL https://get.docker.com | sh >/tmp/infrahub-docker-install.log 2>&1 || die "Docker install failed -- see /tmp/infrahub-docker-install.log"
  ok "Docker installed"
fi
if command -v systemctl >/dev/null && [ -d /run/systemd/system ]; then systemctl enable --now docker >/dev/null 2>&1 || true; fi
docker info >/dev/null 2>&1 || die "Docker is installed but not running -- start it (systemctl start docker) and run this again"
docker compose version >/dev/null 2>&1 || die "the Docker Compose plugin is missing -- install docker-compose-plugin and run this again"
ok "$(docker --version | cut -d, -f1), compose $(docker compose version --short 2>/dev/null)"

# ---------------------------------------------------------------- files
mkdir -p "$DIR"
cd "$DIR"
if [ -f .env ]; then
  step "Existing install found in $DIR -- upgrading (settings and data are kept)"
  curl -fsSL "$DEPLOY_RAW/docker/docker-compose.yml" -o docker-compose.yml || die "couldn't download the compose file"
  [ "$VERSION" != 1.0.0 ] && set_env INFRAHUB_VERSION "$VERSION"
  docker compose pull -q
  docker compose up -d --remove-orphans
  URL="$(grep '^PUBLIC_URL=' .env | cut -d= -f2-)"
  PORT="$(grep '^INFRAHUB_HTTP_PORT=' .env | cut -d= -f2- || echo 80)"
  UPGRADED=1
else
  step "Downloading Infra Hub Center to $DIR"
  curl -fsSL "$DEPLOY_RAW/docker/docker-compose.yml" -o docker-compose.yml || die "couldn't download the compose file from $DEPLOY_RAW"
  curl -fsSL "$DEPLOY_RAW/docker/.env.example" -o .env || die "couldn't download the settings template"
  chmod 600 .env
  ok "docker-compose.yml and .env"

  # ------------------------------------------------------------ settings
  step "Settings"
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  [ -n "$ip" ] || ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' || true)
  default_url="http://${ip:-your-server-ip}"
  [ "$PORT" != 80 ] && default_url="$default_url:$PORT"
  [ -n "$URL" ] || ask URL "Address people will open (domain or IP)" "$default_url"
  case "$URL" in http://*|https://*) ;; *) URL="http://$URL" ;; esac
  URL="${URL%/}"
  [ -n "$ADMIN_EMAIL" ] || ask ADMIN_EMAIL "Admin email" "admin@$(hostname 2>/dev/null || echo infrahub).local"
  GENERATED_PASSWORD=0
  if [ -z "$ADMIN_PASSWORD" ]; then
    ask ADMIN_PASSWORD "Admin password (12+ characters, Enter = generate one)" "" secret
  fi
  if [ -z "$ADMIN_PASSWORD" ]; then
    ADMIN_PASSWORD="$(rand_b64 18 | tr -d '/+=' | cut -c1-20)"
    GENERATED_PASSWORD=1
  fi
  [ "${#ADMIN_PASSWORD}" -ge 12 ] || die "the admin password needs at least 12 characters"
  case "$ADMIN_PASSWORD" in *"'"*) die "the admin password can't contain a single quote (')" ;; esac

  set_env INFRAHUB_VERSION "$VERSION"
  set_env PUBLIC_URL "$URL"
  set_env INFRAHUB_HTTP_PORT "$PORT"
  case "$URL" in https://*) set_env COOKIE_SECURE true ;; esac
  set_env JWT_SECRET "$(rand_hex 48)"
  set_env SSH_CREDENTIAL_ENCRYPTION_KEY "$(rand_b64 32)"
  set_env BOOTSTRAP_ADMIN_EMAIL "$ADMIN_EMAIL"
  set_env BOOTSTRAP_ADMIN_PASSWORD "'$ADMIN_PASSWORD'" # quoted: $ and # stay literal
  [ -n "$LICENSE" ] && set_env INFRAHUB_LICENSE_KEY "$LICENSE"
  if [ -n "$DATABASE_URL" ]; then
    set_env COMPOSE_PROFILES ""
    set_env DATABASE_URL "$DATABASE_URL"
    ok "using your PostgreSQL"
  else
    set_env POSTGRES_PASSWORD "$(rand_hex 24)"
    ok "built-in PostgreSQL with a generated password"
  fi
  ok "secrets generated, settings saved to $DIR/.env (private, chmod 600)"

  # ------------------------------------------------------------ start
  step "Starting Infra Hub Center (first start downloads the images)"
  docker compose pull -q
  docker compose up -d
fi

# ---------------------------------------------------------------- health
step "Waiting for it to answer"
healthy=0
for _ in $(seq 1 90); do
  if curl -fsS "http://localhost:$PORT/api/health" 2>/dev/null | grep -q '"status":"ok"'; then healthy=1; break; fi
  sleep 2
done
if [ "$healthy" = 1 ]; then
  ok "running"
else
  warn "not answering yet -- check: cd $DIR && docker compose logs --tail 50 infrahub-api"
fi

# ---------------------------------------------------------------- done
echo
bold "Infra Hub Center is ready"
echo
echo "    Open:      $URL"
if [ "${UPGRADED:-0}" = 1 ]; then
  echo "    Upgraded:  sign in with your existing account"
else
  echo "    Sign in:   $ADMIN_EMAIL"
  if [ "${GENERATED_PASSWORD:-0}" = 1 ]; then
    echo "    Password:  $ADMIN_PASSWORD"
    echo "               (generated -- write it down; you can change it under Settings)"
  else
    echo "    Password:  the one you entered"
  fi
fi
echo
echo "    Settings:  $DIR/.env"
echo "    Logs:      cd $DIR && docker compose logs -f"
echo "    Upgrade:   run this installer again"
echo "    Stop:      cd $DIR && docker compose down     (data is kept)"
case "$URL" in http://*) echo; echo "    Tip: put HTTPS in front (Caddy, nginx or your load balancer), then set PUBLIC_URL=https://... and COOKIE_SECURE=true in .env and run: docker compose up -d" ;; esac
echo
