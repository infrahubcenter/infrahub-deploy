# Infra Hub Center agents

Three independent, small Go programs that run **on the machine/cluster
being monitored** -- never on the InfraHub server itself. Each is its
own Go module with its own `Dockerfile`, unrelated to `infrahub-api`'s
own build.

| Folder | Runs on | What it does |
|---|---|---|
| [infrahub-docker-agent](https://github.com/infrahubcenter/infrahub-docker-agent) | a Docker host | reports container/image/network/volume state and host system metrics, streams container logs |
| [infrahub-k8s-agent](https://github.com/infrahubcenter/infrahub-k8s-agent) | inside a Kubernetes cluster | reports pod/node/namespace state, streams pod logs |
| [infrahub-vm-agent](https://github.com/infrahubcenter/infrahub-vm-agent) | a VM | pushes OS-level metrics, reads the systemd journal for logs |

All three connect *out* to the InfraHub backend over a WebSocket
(`INFRAHUB_BACKEND_URL` + a per-resource bearer token), so no inbound
port needs to be opened on the monitored host/cluster.

## Installing an agent (end users)

Don't build these Dockerfiles yourself. Each agent is already built and
pushed to Docker Hub (docker.io/infrahubcenter); the InfraHub UI generates the token and the exact
command to run:

- Docker host: **Manage Host -> Install Agent** gives a `docker run ...` command.
- VM: the VM's **Configure -> VM Agent** section gives the same.
- Kubernetes: **Manage Cluster -> Install Agent** gives a `kubectl apply -f -`
  manifest (see `deploy/manifest.yaml` in infrahub-k8s-agent for the template
  it's based on -- a Deployment + ServiceAccount + Secret, not a single
  `docker run`, since it needs in-cluster API access).

### VM Agent without Docker (native systemd service)

For VMs that don't run Docker, `install.sh` in infrahub-vm-agent installs
the agent as the `infrahub-vm-agent` systemd service. It detects apt
(Ubuntu/Debian), dnf (RHEL/Rocky/Alma/Fedora/Amazon Linux 2023), yum
(CentOS 7/Amazon Linux 2) or zypper (SUSE). On x86_64 it downloads the
prebuilt release binary; on arm64 (or with `--from-source`, from a
checkout) it installs gcc, pkg-config, libsystemd headers and Go and
builds it. Use the backend URL and token from the console's VM Agent
`docker run` command:

```bash
curl -fsSL https://raw.githubusercontent.com/infrahubcenter/infrahub-vm-agent/main/install.sh \
  | sudo bash -s -- --backend-url '<INFRAHUB_BACKEND_URL>' --token '<INFRAHUB_AGENT_TOKEN>'
journalctl -u infrahub-vm-agent -f

# Remove:
curl -fsSL https://raw.githubusercontent.com/infrahubcenter/infrahub-vm-agent/main/install.sh | sudo bash -s -- --uninstall
```

The same binary reads `/host/...` paths when containerized and the real
`/proc`, `/var/log/journal`, `/run/log/journal` when native.

## Releasing a new agent version (maintainers)

```bash
# in infrahub-docker-agent (same for infrahub-k8s-agent / infrahub-vm-agent)
docker buildx build --platform linux/amd64,linux/arm64 \
  -t docker.io/infrahubcenter/infrahub-docker-agent:<version> --push .
```

**Always push a
real version tag**, then update the pinned tag so new installs pick it up:

- `infrahub-api/internal/services/docker_agent_install.go` -- `dockerAgentImage`
- `infrahub-api/internal/services/vm_agent_install.go` -- `vmAgentImage`
- `infrahub-ui/src/lib/agent-install-command.ts` -- `DOCKER_IMAGE_BY_OS`
- `infrahub-k8s-agent/deploy/manifest.yaml` -- the Deployment's `image:`

Native VM agent binaries are attached to the
[infrahub-vm-agent releases](https://github.com/infrahubcenter/infrahub-vm-agent/releases)
(`infrahub-linux-os-agent-amd64`, `infrahub-windows-os-agent.exe`,
`infrahub-mac-os-agent-{amd64,arm64}`).

Installed agents don't auto-update; reinstall with a freshly generated
command to pick up a new version.
