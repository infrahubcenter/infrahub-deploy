# SSH Connectivity, Credential Encryption & Discovery Architecture

Step 5 adds the first real infrastructure connectivity: encrypted SSH
credential storage, trust-on-first-use host-key verification, connection
testing, and a first basic discovery pass. It does not add an interactive
terminal, package/Docker/database/S3 operations, or arbitrary command
execution -- see the layering below and `internal/services/discovery.go`'s
fixed command list.

## 1. Layering

```
HTTP Handler (internal/handlers/vm_ssh.go)
    │
    ├─ AuthorizationService   (GET endpoints: is this caller allowed to see this VM?)
    │
    ├─ CredentialService      (encrypt/decrypt SSH private keys)
    ├─ HostKeyService         (trust-on-first-use verification)
    ├─ SSHService             (Connect / TestConnection, using the two above)
    │     └─ RemoteExecutor   (run one fixed command per SSH session, with timeout)
    └─ VMDiscoveryService     (orchestrates SSHService + RemoteExecutor, parses output, persists)
          └─ repository.Store → PostgreSQL
```

No SSH code lives in a handler. Every write operation the handlers expose
is admin-only; the two read endpoints (`connection-status`, `discovery`)
go through the same `AuthorizationService.CanAccessVM` check as
`GET /api/vms/:id` (Step 3), including its 404-not-403 policy.

## 2. Credential encryption

`internal/services/encryption.go` (`EncryptionService`) implements
AES-256-GCM. Storage format:

```
base64( nonce ‖ ciphertext ‖ tag )
```

The nonce is generated fresh per `Encrypt` call (`crypto/rand`) and
prepended to the ciphertext, so no nonce-reuse bookkeeping is needed and
the stored blob is fully self-describing -- `Decrypt` just reads the first
`gcm.NonceSize()` bytes back off the front. GCM authenticates on every
`Decrypt`; a tampered or wrong-key ciphertext fails closed with a generic
"authentication failed" error, never a partial/garbage plaintext.

**The key** (`SSH_CREDENTIAL_ENCRYPTION_KEY`, base64, 32 bytes) lives only
in the environment -- never in PostgreSQL, never in git. Generate one with
`go run ./cmd/gen-encryption-key`. Losing it makes every stored credential
permanently unrecoverable; there is no recovery path by design.

`CredentialService` (`internal/services/credential.go`) is the only thing
that calls `Encrypt`/`Decrypt` for SSH keys:

- `StoreSSHPrivateKey` validates structurally (`ssh.ParsePrivateKey`),
  encrypts, and replaces any existing `SSH_PRIVATE_KEY` credential row for
  the resource atomically (delete-then-insert in one transaction) --
  "replace" is genuinely atomic, never two rows or a half-written one.
- `GetSSHSigner` is the *only* method that ever decrypts: it returns an
  `ssh.Signer` (which `SSHService` feeds straight into
  `ssh.ClientConfig.Auth`), never raw key bytes, to keep plaintext key
  material from casually flowing through more of the codebase than
  necessary.
- Nothing decrypted is ever logged, returned from an HTTP handler, or
  placed in an audit event.

**Passphrase-protected keys are not supported in this step** (Step 5 §10
allows deferring this with a clear error instead of silently failing).
`StoreSSHPrivateKey` detects one via `ssh.ParsePrivateKey`'s
`*ssh.PassphraseMissingError` and returns
`ErrPassphraseProtectedKey` → `"Passphrase-protected SSH keys are not
currently supported."` The credential model already has room for this:
`credentials.credential_type` could hold a future `SSH_PRIVATE_KEY_PASSPHRASE`
row, encrypted exactly like `SSH_PRIVATE_KEY` is now, and wiring a
passphrase through `SSHService.Connect` is additive, not a redesign.

## 3. Host-key trust (TOFU)

`ssh.InsecureIgnoreHostKey()` is never used anywhere in this codebase.
`ssh_host_keys` (migration `014_ssh_connectivity.sql`) holds one row per
VM resource: the last key an admin explicitly trusted.

`HostKeyService.VerifyCallback(resourceID)` (`internal/services/hostkey.go`)
returns the `ssh.HostKeyCallback` every `ssh.ClientConfig` in this codebase
uses:

- **No trusted row exists** → the callback returns `*HostKeyUnknownError`
  (host/port/algorithm/fingerprint), which aborts the handshake. The
  connection is refused outright; nothing is silently trusted.
- **Trusted row exists, fingerprint matches** → success;
  `last_verified_at` is touched (best-effort, never blocks the connection).
- **Trusted row exists, fingerprint differs** → the callback returns
  `*HostKeyChangedError` (old + new fingerprint). The connection is
  refused unconditionally -- nothing here ever auto-replaces a trusted
  key.

**The only way a row is ever written** is `HostKeyService.Trust`
(called by `POST /api/vms/:id/host-key/trust`, admin-only). It does
**not** accept a client-supplied fingerprint as truth -- accepting
whatever fingerprint a frontend claims to have seen would let a
compromised or MITM'd frontend trick an admin into trusting an attacker's
key. Instead, `Trust` independently re-dials `host:port` itself, performs
just the SSH key-exchange stage (never authentication), captures whatever
key the server actually presents right now, and stores that. The moment
of trust is a fresh, backend-verified network round trip, not a form
submission.

## 4. Connection lifecycle & status mapping

`SSHService.Connect` (`internal/services/ssh.go`): load VM config → load
decrypted signer via `CredentialService` → dial with
`net.Dialer.DialContext` (respects `SSH_CONNECT_TIMEOUT` and the request's
`context.Context`) → `ssh.NewClientConn` with
`HostKeyService.VerifyCallback`. `TestConnection` wraps this, measures
latency, and immediately closes -- Step 5 §18 is explicit that a
connection test must not persist monitoring data.

Every failure becomes a `*SSHError` (`internal/services/ssh_errors.go`)
with a stable `Code` and a safe, secret-free `Message` --
`INVALID_CREDENTIAL`, `SSH_AUTHENTICATION_FAILED`,
`SSH_CONNECTION_TIMEOUT`, `SSH_CONNECTION_REFUSED`, `SSH_DNS_FAILURE`,
`SSH_HOST_UNREACHABLE`, `HOST_KEY_UNKNOWN`, `HOST_KEY_CHANGED`,
`VM_NOT_CONFIGURED`. Handlers never forward a raw error string from the
SSH library or the standard library's networking stack -- only these codes
and messages.

`RecordConnectionOutcome` (`internal/services/ssh.go`) is the **one**
place that maps a connection attempt to `vms.connection_status` and
`resources.status`, shared by both `TestConnection`'s handler and
`VMDiscoveryService.Discover` (discovery always connects first):

| Outcome | `connection_status` | `resources.status` | `last_seen_at` |
| --- | --- | --- | --- |
| Success | `CONNECTED` | `ONLINE` | updated |
| Timeout / refused / DNS failure / host unreachable | `FAILED` | `OFFLINE` | unchanged |
| Auth failure / invalid credential / not configured | `FAILED` | **unchanged** | unchanged |
| Host key unknown | `HOST_KEY_UNKNOWN` | **unchanged** | unchanged |
| Host key changed | `HOST_KEY_CHANGED` | **unchanged** | unchanged |

The middle two rows are the important distinction Step 5 §38 asks for:
`resources.status` only ever says `OFFLINE` when the network genuinely
couldn't reach the host. A wrong credential or an untrusted host key says
nothing about whether the machine is up -- so `resources.status` is left
alone rather than lying that it's offline. `connection_status` is the
place that distinction actually lives (Step 5 §19: connection state and
monitoring health are different concepts, not to be confused).

`CONNECTING` exists in the `connection_status` CHECK constraint for a
future asynchronous/streaming flow but is never written by this step --
every operation here is a single blocking HTTP request/response, so
there's no in-between state to persist.

## 5. Discovery

`VMDiscoveryService.Discover` (`internal/services/discovery.go`) connects
once, then runs each fixed command through `RemoteExecutor` (one SSH
session per command; x/crypto/ssh sessions are single-use):

| Field | Command | Parser |
| --- | --- | --- |
| hostname | `hostname` | trim |
| OS | `cat /etc/os-release` | `parseOSRelease` (generic, not Ubuntu-specific) |
| kernel | `uname -r` | trim |
| architecture | `uname -m` | trim |
| CPU cores | `nproc` | `parseCPUCores` |
| memory | `cat /proc/meminfo` | `parseMemTotalBytes` (MemTotal only, not MemAvailable) |
| storage | `df -Pk /` | `parseDFTotalBytes` (root filesystem only -- see below) |
| Docker | `command -v docker` | exit code only; nonzero = not installed, not a failure |

All eight are fixed, backend-authored strings -- never built from request
input, so there is no command-injection surface. `POST /api/vms/:id/execute`
does not exist and must not be added in this step.

**Storage is the root filesystem's total capacity only**, not a sum across
every mounted filesystem: summing arbitrary mounts risks double-counting
bind mounts and overlays, and picking up volumes that aren't meaningfully
part of "this VM's storage." Per-mount detail is what the (separate,
not-yet-built) `vm_filesystems` table from Step 2 is for.

**Partial/failed discovery never destroys previously-known-good data**:
`UpdateVMDiscoveryResult`'s SQL uses `COALESCE(new_value, existing_value)`
for every column, so a `NULL` argument (a field that failed to parse)
leaves the old value untouched. One field failing never fails the whole
run -- the overall `vm_discovery_runs.status` is `SUCCESS` (all 8 fields),
`PARTIAL` (some), or `FAILED` (the SSH connection itself never succeeded,
or zero fields parsed). Every attempt -- including totally failed ones --
gets its own append-only `vm_discovery_runs` row (never overwritten), so a
past failure stays visible even after a later run succeeds.

## 6. What's explicitly out of scope (this step)

No interactive terminal/WebSocket, no arbitrary command execution, no
package/OS update detection, no Docker container/image inventory, no
database/S3 monitoring. These commands only ever read fixed, safe,
backend-authored information; nothing here writes to or modifies the
remote VM.

## 7. Production considerations (not implemented)

Documented, not built, in this step:

- A real secret manager (Vault, cloud KMS/Secrets Manager) instead of an
  application-level AES key in an environment variable.
- Centralized host-key management/rotation across many VMs.
- Stronger credential lifecycle management (rotation, expiry).
- A dedicated monitoring agent instead of ad hoc SSH commands.
- Connection pooling for SSH clients (every operation here opens and
  closes its own connection).
- Rate limiting on connection-test/discovery endpoints.
- An operation queue for long-running or bulk discovery instead of one
  blocking HTTP request per VM.
