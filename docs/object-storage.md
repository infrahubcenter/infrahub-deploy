# Object Storage Monitoring & Browser (Step 17)

Object storage (AWS S3, DigitalOcean Spaces, MinIO, or a generic
S3-compatible endpoint) is a **first-class, standalone resource** — same
Project/Group/direct-access model as standalone databases (Step 13), same
adapter/scheduler/alert/recommendation/audit patterns, a read-only browser
instead of a query console. It is never a VM child and never reached over
SSH: the backend talks to it directly over the S3 HTTP(S) API via
`aws-sdk-go-v2`.

**Strictly read-only against the real bucket.** Nothing in this feature can
create, delete, or overwrite an object; create or delete a bucket; change a
bucket's policy, versioning, encryption, object-lock, or public-access
configuration; or run any client-supplied S3 operation. Every S3 call this
feature issues is one of `HeadBucket`, `HeadObject`, `ListObjectsV2`,
`GetObject` (read, or presigned), `GetBucketVersioning`,
`GetBucketEncryption`, `GetPublicAccessBlock`, `GetBucketPolicyStatus`, or
`GetObjectLockConfiguration` — all read-only S3 APIs, all backend-defined
and hardcoded, none accepting a client-supplied parameter beyond a
navigation prefix/key. Removing an object storage from Infra Hub Center
removes its **monitoring registration** only; the real bucket and every
object in it are never touched.

## 1. Architecture

```
Next.js → Go API → ObjectStorageService / ObjectStorageMetricsService /
ObjectStorageDeepMetricsService / ObjectStorageBrowserService →
aws-sdk-go-v2 (service/s3, service/cloudwatch) → the real bucket
```

`Project → (Group, optional) → Resource (resource_type = 'OBJECT_STORAGE')
→ object_storages`, mirroring standalone databases' shape exactly (and
sharing the generic `resources`/`resource_permissions`/`recommendations`/
`alert_rules`/`audit_logs` tables every other resource type uses — no
storage-specific authorization, alert, or audit schema exists).

The schema was deliberately pre-staged: `resources.resource_type` already
included `'OBJECT_STORAGE'`, and a placeholder `object_storages` table
(migration `005`, `provider`/`endpoint`/`region`/`bucket`/`base_path`/
`access_key_id`) already existed before Step 17. This feature's own
migrations (`026`, `027`) only add monitoring/credential/metrics columns
and tables on top of that placeholder — see §16.

One AWS SDK v2 S3 client shape serves all four providers (`s3_client.go`'s
`newS3Client`): unlike the four standalone database engines, AWS S3,
DigitalOcean Spaces, MinIO, and a generic S3-compatible endpoint all speak
the identical S3 API, so this is one client configured per-provider via
`s3.Options` overrides, never four separate adapters.

## 2. Providers & S3 compatibility

Four supported `provider` values (`object_storage_service.go`'s
`validObjectStorageProviders`): `AWS_S3`, `DIGITALOCEAN_SPACES`, `MINIO`,
`S3_COMPATIBLE`. All four get the identical capability set
(`CapabilitiesForProvider`, `object_storage_capabilities.go`) — `metrics`,
`browser`, `object_metadata`, `download`, `versioning`, `encryption` are
all `true`; `logs` is `false` for every provider (§17). The only
per-provider client difference is addressing style:

- **AWS S3**: virtual-hosted-style addressing (S3 resolves it correctly
  without help) and, uniquely, CloudWatch bucket metrics on the deep cycle
  (§6).
- **DigitalOcean Spaces / MinIO / generic S3-compatible**: path-style
  addressing (`UsePathStyle = true`) — far more reliable against a bare
  `host:port` endpoint with no wildcard DNS certificate for
  `<bucket>.<endpoint>`. Object count/size on these three always comes from
  the bounded-listing fallback (§6); no CloudWatch equivalent exists.

`TLSSkipVerify` is an explicit, per-instance admin opt-in (mirrors the
database adapters' identical flag) for a self-signed-cert MinIO/Spaces
endpoint in development — never the default, and never silently applied.

## 3. Credentials

`standalone_object_storage_credentials` (migration `026`, one row per
`object_storage_id`, `encrypted_secret_key bytea`) — a dedicated table, not
the generic `credentials` table, mirroring `standalone_database_credentials`
exactly. `access_key_id` is **not** a secret (an S3 access key ID is an
identifier, not a credential) and stays plaintext on `object_storages`
itself; only the secret access key is ever encrypted.
`StandaloneObjectStorageCredentialService` reuses the exact same
`EncryptionService` (AES-256-GCM, `SSH_CREDENTIAL_ENCRYPTION_KEY`) every
other credential in this project uses — no new encryption primitive.

An admin configures `{access_key_id, secret_access_key}` via
`POST`/`PATCH /api/object-storage`; the backend never generates or infers
one. No response DTO anywhere returns the secret key back — `GET`/`List`
responses carry only `access_key_id` (plaintext, not a secret) and
`credential_configured` (a boolean from `HasSecretKey`, which checks
existence without decrypting).

## 4. Connection testing

`POST /api/object-storage/:id/test-connection` (admin-only) runs exactly
one backend-defined, read-only `HeadBucket` probe — the request body is
empty; there is no `{"operation": ...}` field anywhere in this feature.
The probe is bounded by `OBJECT_STORAGE_CONNECTION_TIMEOUT` (default
`10s`). The outcome is always one of an 8-value `connection_status` enum
(`CONNECTED | AUTH_FAILED | ACCESS_DENIED | NOT_FOUND | TIMEOUT |
TLS_ERROR | UNAVAILABLE | UNKNOWN`) — deliberately distinct from
databases' 7-value `ConnectionTestStatus`, since `ACCESS_DENIED` and
`NOT_FOUND` are meaningful, distinct S3 outcomes with no database
equivalent (`REFUSED` collapses into `UNAVAILABLE` here). Every outcome,
including "no credential configured," is a normal, persisted status, never
an HTTP 500; only a genuine backend failure while persisting the result is
a 500. `classifyObjectStorageError`
(`object_storage_test_connection.go`) is the single place that turns a raw
AWS SDK/transport error into one of these statuses — the frontend and the
audit log only ever see the classified enum value, never the underlying
SDK error text (which can embed endpoint/query detail).

## 5. Monitoring: fast cycle

`ObjectStorageMetricsService.CollectOne` (fast/common cycle) runs a single
`HeadBucket` call per monitored storage — reachability, round-trip
latency, and an error count, **never** `ListObjectsV2` or any other
bucket-listing call. `ObjectStorageMetricsScheduler` runs this on
`OBJECT_STORAGE_METRICS_INTERVAL` (default `60s`) across
`OBJECT_STORAGE_METRICS_WORKERS` (default `3`) workers, keyed by object
storage ID, only ever enqueuing storages with `monitoring_enabled = true`
— a verbatim structural copy of `database_metrics_scheduler.go`'s
worker-pool/ticker/`sync.Map`-in-flight-guard shape.

`health_status` (`HEALTHY | WARNING | CRITICAL | UNKNOWN`) is derived by
`ComputeObjectStorageHealth`: reachable → `HEALTHY`, an unclassified probe
→ `UNKNOWN`, any classified failure → `CRITICAL`. Deliberately binary at
this tier — `WARNING` is never produced by the fast cycle alone; the deep
cycle (§6) layers public-access/encryption/growth-based severity on top of
it (§9's health-reasons endpoint shows the combined result).

## 6. Monitoring: deep cycle

`ObjectStorageDeepMetricsService.CollectDeep` runs on
`OBJECT_STORAGE_DEEP_METRICS_INTERVAL` (default `5m`) across
`OBJECT_STORAGE_DEEP_METRICS_WORKERS` (default `2`) workers — a much less
frequent, more expensive cycle that never touches `connection_status`/
`health_status`, which stay the fast cycle's exclusive responsibility.
Each deep cycle collects:

- **Security facts** — versioning, encryption, public-access, object-lock
  — via four fully independent probes (`GetBucketVersioning`/
  `GetBucketEncryption`/`GetPublicAccessBlock`+`GetBucketPolicyStatus`
  fallback/`GetObjectLockConfiguration`). Each gets its own slice of the
  cycle's timeout budget; **a single probe's failure sets only that field
  to `UNKNOWN`** and never aborts the others or the cycle. A value is set
  to `ENABLED`/`DISABLED`/`PUBLIC`/`PRIVATE` only on positive evidence from
  a successful, independent call — a failed or denied call is never
  interpreted as "probably disabled" or "probably private." Synced onto
  `object_storages` itself (`UpdateObjectStorageSecurityFacts`) so the
  dashboard/detail GET and `GET .../security` never need to join
  `object_storage_deep_metrics`.
- **Bucket object count / size / request counts** — AWS S3 tries
  CloudWatch's daily `BucketSizeBytes`/`NumberOfObjects` metrics first
  (§2's AWS-only capability; a 2-day lookback window, since those metrics
  publish with a documented ~24–48h delay — this is explicitly **not** a
  real-time number). Every provider (including AWS S3 when CloudWatch is
  denied or has no datapoints yet) falls back to a **bounded**
  `ListObjectsV2` walk, capped at 20 pages (≈20,000 keys) — never an
  unbounded scan. If the cap is hit before the bucket is fully listed, the
  result is marked `partial: true` and the count/size are a real but
  honest **undercount**, never presented as the bucket's true total.
  Request/4xx/5xx counts are CloudWatch-only and only present at all when
  the bucket owner has explicitly enabled per-bucket request metrics on
  AWS's side (most buckets never do — an empty result here is the normal
  case, not an error).
- **Growth rate** — reuses the existing pure `ComputeGrowthRate` function
  (`database_performance_math.go`, no new growth math) over
  `object_storage_metrics` rows from the last 7 days. Needs at least two
  real size samples spanning at least an hour within that window; below
  that, no rate is reported (never a fabricated `0`/day figure) — see
  §14's known-limitations note.
- **Error rate** — CloudWatch 4xx+5xx over request count when available,
  else a recent fast-cycle `HeadBucket`-failure-rate fallback.

The bucket-metrics half of each deep sample is persisted onto the *same*
`object_storage_metrics` table the fast cycle writes to (kept structurally
distinct at the Go-struct level even though the table is shared), and
merged into the fast cycle's own live cache so `GET .../growth` and the
list page's Objects/Size columns reflect it immediately rather than
waiting for the next fast tick.

## 7. Security panel & recommendations

`GET /api/object-storage/:id/security` returns the four security facts
(`versioning`/`encryption`/`object_lock`/`public_access`), each always one
of its `ENABLED`/`DISABLED`/`UNKNOWN` (or `PUBLIC`/`PRIVATE`/`UNKNOWN`)
values — `UNKNOWN` is a first-class value here, never omitted, since "we
don't know yet" is itself meaningful.

Four recommendation types are synced from that same evidence
(`ObjectStorageDeepMetricsService.syncRecommendations`, reusing the
existing `UpsertRecommendationBySource`/`ResolveRecommendationBySource`
queries — no new recommendation engine):

| Type | Fires on | Severity |
| --- | --- | --- |
| `OBJECT_STORAGE_PUBLIC_ACCESS` | `public_access == PUBLIC` | `OBJECT_STORAGE_PUBLIC_ACCESS_SEVERITY` (default `CRITICAL`; config value is normalized onto `recommendations.severity`'s real `LOW/MEDIUM/HIGH/CRITICAL` vocabulary — an unrecognized value falls back to `HIGH`, never a silently-failing insert) |
| `OBJECT_STORAGE_ENCRYPTION_DISABLED` | `encryption == DISABLED` | `HIGH` |
| `OBJECT_STORAGE_HIGH_GROWTH` | projected 7-day growth % > `OBJECT_STORAGE_GROWTH_WARNING_PERCENT` (default `20`) | `MEDIUM` |
| `OBJECT_STORAGE_HIGH_ERROR_RATE` | observed error rate % > `OBJECT_STORAGE_ERROR_RATE_WARNING_PERCENT` (default `5`) | `MEDIUM` |

Every condition upserts **only** on positive evidence and resolves only
when the opposite positive evidence is available — `UNKNOWN` touches
neither, and an unavailable growth/error-rate figure recommends nothing
(never "assume healthy," never "assume unhealthy").

`GET /api/object-storage/:id/health` layers these active recommendations
on top of the fast cycle's own `HEALTHY`/`CRITICAL`/`UNKNOWN` verdict —
severity only ever **escalates** the status (`CRITICAL` > `WARNING` >
`HEALTHY`/`UNKNOWN`), never downgrades a genuinely unreachable bucket back
down. `reasons` surfaces human-readable text ("Public access detected",
"Encryption disabled", "Storage growth increased", "High error rate
detected", "Bucket is unreachable") — always a real (possibly empty)
array, never `null`.

## 8. Growth projection

`GET /api/object-storage/:id/growth` and the detail page's embedded
`growth_projection` field report `current_bytes` (from the live cache or
latest metric row), `growth_bytes_per_day`, and
`estimated_30d_growth_bytes` (`= growth_bytes_per_day × 30`) — but
`growth_bytes_per_day`/`estimated_30d_growth_bytes` are **only ever both
present or both absent together**: no rate below the ≥2-samples/≥1-hour/
7-day-window threshold in §6 means no projection at all, never a
fabricated `0`/day. The detail page's embedded `growth_projection` field
specifically requires the *full* projection (current + rate + estimate)
before it's ever included — a partial `{current_bytes}`-only object is
deliberately withheld there to avoid a half-answer with "N/A"-style holes;
the dedicated `GET .../growth` endpoint still returns partial fields on
their own per-field contract.

## 9. Alerts

Five alert type/metric pairs (`alert_types.go`, migration `026`'s widened
`alert_rules` CHECK constraints), evaluated by the existing, fully generic
`AlertEngine`/`alertMetricLookup.Resolve` — no changes needed to either:

| Alert type | Metric | Condition | Default severity |
| --- | --- | --- | --- |
| `OBJECT_STORAGE_UNAVAILABLE` | `OBJECT_STORAGE_UNREACHABLE` | `== 1` (unreachable) | `CRITICAL` |
| `OBJECT_STORAGE_HIGH_GROWTH` | `OBJECT_STORAGE_GROWTH_PERCENT` | `> 20` | `WARNING` |
| `OBJECT_STORAGE_PUBLIC_ACCESS` | `OBJECT_STORAGE_PUBLIC_ACCESS_FLAG` | `== 1` (public) | `CRITICAL` |
| `OBJECT_STORAGE_ENCRYPTION_DISABLED` | `OBJECT_STORAGE_ENCRYPTION_DISABLED_FLAG` | `== 1` (disabled) | `WARNING` |
| `OBJECT_STORAGE_HIGH_ERROR_RATE` | `OBJECT_STORAGE_ERROR_RATE_PERCENT` | `> 5` | `WARNING` |

`alert_metric_lookup.go`'s `Resolve()` reads these directly off
`object_storages`/`object_storage_deep_metrics` via a `LEFT JOIN
object_storages` added to the shared alert-evaluation query — the same
join shape as its existing `databases` join. No second alerting system
exists for object storage; alert rules, notification policies, and
delivery all go through the one shared engine every other resource type
uses (see [alerts.md](alerts.md)).

## 10. Browser

The read-only object browser (`object_storage_browser.go`,
`ObjectStorageBrowserService`) offers prefix/pseudo-folder listing,
prefix-anchored search, object metadata, a short-lived presigned download
URL, and a byte-capped text/JSON preview — the same five concerns
`database_browser.go` covers for a database, reshaped for S3's key/prefix
model instead of tables/rows.

- **Listing** (`GET .../objects?prefix=...&continuation_token=...`) —
  one `ListObjectsV2` call with `Delimiter: "/"`, grouping everything one
  level deeper into `FOLDER` entries (S3 `CommonPrefixes`) rather than
  flattening the whole subtree. A zero-byte "folder marker" placeholder
  object (key equal to the prefix itself, as some upload tools create) is
  excluded from the `OBJECT` entries, since the same request already
  produces the equivalent `FOLDER` entry.
- **Search** (`GET .../objects/search?prefix=...&q=...`) — pure prefix
  concatenation (`prefix + q`), no wildcard/regex language; kept in the
  same `Delimiter: "/"` shape as listing rather than a second, flattened
  mode.
- **Metadata** (`GET .../objects/metadata?key=...`) — one `HeadObject`
  call: size, content type, ETag, last-modified, storage class, and the
  object's own user-defined `x-amz-meta-*` headers, exactly as the SDK
  returns them.
- **Preview** (`GET .../objects/preview?key=...`, §12).
- **Download** (`POST .../objects/download?key=...`, §11).

## 11. Downloads

`POST /api/object-storage/:id/objects/download` (not `GET`) returns a
short-lived presigned `GetObject` URL (`GeneratePresignedDownloadURL`,
`s3.PresignClient`), valid for `OBJECT_STORAGE_DOWNLOAD_URL_TTL` (default
`5m`) — **never** a permanent link. `POST`, not `GET`, is a deliberate
routing decision: minting a presigned URL is treated as creating a
stateful, sensitive, short-lived credential-bearing artifact (the URL's
query string embeds a temporary signature), the same category of action
`update-operations`/`reboot-operations`/every other "this creates
something" endpoint in this project uses `POST` for — not a plain,
side-effect-free `GET`. Presigning does not first confirm the object
exists via `HeadObject`: an extra round trip would be both needless and
racy (the object could be removed between the check and the URL actually
being used), and a presigned URL against a missing key already does the
right thing on use — it simply 404s, like any other missing-key URL.

## 12. Preview

`GET /api/object-storage/:id/objects/preview?key=...` always runs
`HeadObject` first. If the object's real size exceeds
`OBJECT_STORAGE_PREVIEW_MAX_BYTES` (default `5MiB`), it returns `413`
**without ever issuing the `GetObject` call**; if the content type isn't
text-like or JSON (`isPreviewableContentType` — any `text/*`, plus
`application/json`/`xml`/`javascript`/`x-ndjson`; an empty/unknown content
type, which many providers default new uploads to, is treated as **not**
previewable rather than guessed at), it returns `415`, also without
attempting to read the body. Only once both gates pass does it run one
`GetObject` with an explicit `Range` header capping the read at the
configured max, and even then never trusts the server to honor `Range`
exactly — a second, hard `io.LimitReader` cap is enforced on the response
body itself. The response is UTF-8 text when the (possibly truncated)
byte range is valid UTF-8, else base64 — the preview API never emits
invalid-UTF-8 raw bytes as a JSON string. Images and PDFs are **not**
served through this endpoint at all; the frontend previews those via the
same presigned download URL from §11 (`<img src=...>` / `<iframe
src=...>` using the browser's own native viewer) — no new
image/PDF-handling dependency anywhere in this feature.

## 13. Pagination

Every list/search response is cursor-based via S3's own
`ContinuationToken`/`NextContinuationToken` — **never offset-based**.
`limit` defaults to 50 and is clamped twice: once by the handler against
the config-overridable `OBJECT_STORAGE_MAX_PAGE_SIZE` (default `200`), and
again, unconditionally, by the service layer's own compile-time
`MaxObjectPageSize` (`200`) ceiling — a caller can never coax more than
that absolute maximum out of either layer regardless of what the client
requests or what the config value says. The frontend maintains its own
continuation-token *stack* for Previous/Next navigation, since S3 gives no
"page N" concept to jump to directly.

## 14. Security

- **No write/delete/upload S3 route exists anywhere.** Every route under
  `/api/object-storage` is `GET`, or a `POST`/`PATCH`/`DELETE` against
  this application's own **monitoring configuration** (`object_storages`,
  access grants, the download-URL-minting endpoint) — never against an
  object's or bucket's actual content. `internal/server/object_storage_test.go`'s
  `TestObjectStorageObjects_NoMutatingRouteExists` asserts `PUT`/`DELETE`/
  `PATCH`/`POST` against `.../objects` itself all return `405`.
- **404-not-403 IDOR discipline everywhere.** `ObjectStorageHandler.
  authorizeObjectStorage` and `ObjectStorageBrowserHandler`'s own copy of
  it (kept independent on purpose, mirroring `DatabaseBrowserHandler`) both
  resolve `:id`, confirm the storage exists and isn't soft-deleted, and
  check `CanAccessObjectStorage` for the endpoint's required permission —
  any failure at any of those three steps is an identical `404`, never
  disclosing whether a storage with that ID exists to a caller who isn't
  authorized for it. Every one of this feature's 16 `:id`-scoped endpoints
  goes through one of these two functions before touching any data.
- **`base_path` confinement + path-traversal rejection.** Every browser
  endpoint taking a `prefix`, `q`, or `key` runs it through
  `isValidObjectPath` first (rejects a leading `/` and any literal `..`
  path segment) before `joinBasePath` ever prepends the storage's
  configured `base_path` and sends the result to S3 — a caller can never
  escape the configured subtree even if the underlying credential's own
  IAM/bucket policy would technically allow broader access.
  `stripBasePath` removes that same prefix from every key/prefix before it
  is ever returned to a caller — `base_path` is a purely internal,
  per-instance configuration detail the frontend never sees.
- **Never a fabricated 500 to hide a real error's shape, but never a raw
  SDK error either.** `writeObjectStorageBrowserError`/
  `classifyObjectStorageError` translate every AWS SDK/transport failure
  into one of a small set of typed errors before it ever reaches an HTTP
  response or an audit-log entry — the underlying error's message (which
  can embed endpoint/query detail) is never surfaced directly.
- **No secret or presigned URL ever logged.** No handler or audit
  `Metadata` map anywhere includes a decrypted secret access key or a
  generated presigned URL — a presigned URL's query string is exactly as
  sensitive as a raw credential and is treated that way. `GrantAccess`/
  `RevokeAccess`/`Configure`/`Update`/`TestConnection` audit entries carry
  only IDs, the provider name, permission names, and the classified
  `connection_status`; `GetObjectMetadata`/`RequestDownload` audit entries
  carry only the object `key`.

## 15. Authorization

Four new permission constants (`identity.go`): `object_storage.view`,
`object_storage.monitor`, `object_storage.browser`,
`object_storage.download` — all four independently grantable
(`grantableObjectStoragePermissions`, `access.go`), mirroring
`grantableDatabasePermissions` exactly: an admin can hand a Member deeper
access (browser/download) per-storage without touching project/group
membership. Group membership alone grants only `view` + `monitor`
(`AuthorizationService.EffectiveObjectStorageAccess`) — never `browser`/
`download`, which must be granted directly. An Admin bypasses explicit
grants entirely, exactly like every other resource type in this project
(`CanAccessObjectStorage`/`GetUserObjectStorageAccess` both short-circuit
on `user.IsAdmin()`).

Every list-style response (`GET /api/object-storage`, `GET /api/my-access`)
carries a caller-scoped `permissions: string[]` per entry
(`permissionsForObjectStorage`) — the frontend's tab/action-hiding logic
depends on this being present and accurate, not a hardcoded or
admin-level value. `GET /api/my-access` extends the original VM-only
shape with `databases`/`object_storage` sections computed the identical
"scoped to this caller's authorized resources" way their own list
endpoints already compute (see §18's API table) — an Admin sees every
object storage and database in the system there too, matching how the
`vms` section has always behaved for an Admin caller.

## 16. Migrations

| # | File | Contents |
| - | --- | --- |
| 005 | `005_resource_details.sql` | Placeholder `object_storages` table (`provider`/`endpoint`/`region`/`bucket`/`base_path`/`access_key_id`) — pre-staged years before this feature, per §1. |
| 026 | `026_object_storage_monitoring.sql` | `standalone_object_storage_credentials`; `object_storages` gains `name`/`monitoring_enabled`/`tls_enabled`/`tls_skip_verify`/`connection_status`/`last_metrics_at`/`health_status`/`versioning_status`/`encryption_status`/`public_access`/`object_lock_status`/`deleted_at`; `object_storage_metrics`, `object_storage_deep_metrics`, `object_storage_monitoring_health`; widens `alert_rules.alert_type`/`.metric` and `recommendations.type` CHECK constraints for this feature's values (and, in passing, the missing `DATABASE_*` recommendation values `database_deep_metrics_service.go` already wrote). |
| 027 | `027_object_storage_error_rate.sql` | Adds `object_storage_deep_metrics.error_rate_percent`, so the alert engine's `OBJECT_STORAGE_ERROR_RATE_PERCENT` lookup reads an already-persisted value instead of the deep collector's in-memory computation being thrown away after only driving the recommendation sync. |

## 17. Known limitations

- **No multi-bucket-per-resource.** One `object_storages` row models
  exactly one bucket; monitoring a second bucket on the same underlying
  credential means configuring a second, independent storage resource.
- **No log integration of any kind** (no CloudTrail/S3 access-log
  ingestion) — `capabilities.logs` is `false` for every provider, and the
  Logs tab/section is fully **hidden**, never shown-with-a-message, for a
  single consistent capability-gating rule across the whole detail page.
- **Growth projection needs real history.** `GET .../growth` reports
  nothing until at least two real size samples, at least an hour apart,
  exist within the last 7 days of `object_storage_metrics` — a newly
  configured storage (or one whose deep cycle has only run once) shows no
  projection at all, by design, rather than an extrapolation from a single
  point.
- **CloudWatch bucket/request metrics need AWS-side opt-in.**
  `BucketSizeBytes`/`NumberOfObjects` are always available for AWS S3 (no
  configuration needed) but publish on a ~24–48h delay, so they never
  reflect "right now." Request/4xx/5xx counts require the bucket owner to
  have separately enabled per-bucket request metrics in the AWS console —
  most buckets never do, and an empty result there is normal, not a
  collection failure. Object count/size for DigitalOcean Spaces/MinIO/
  generic S3-compatible always comes from the bounded 20-page
  `ListObjectsV2` fallback (§6) — there is no CloudWatch-equivalent signal
  for those providers.
- **No per-admin severity-policy mechanism.** A publicly-accessible
  bucket's recommendation severity is one global config default
  (`OBJECT_STORAGE_PUBLIC_ACCESS_SEVERITY`), not a per-admin or
  per-storage policy — consistent with how every other recommendation in
  this codebase hardcodes its severity today.

## 18. API surface

| Method & path | Access |
| --- | --- |
| `GET /api/object-storage` | any role, scoped to authorized storages |
| `POST /api/object-storage` | admin only (configure) |
| `GET /api/object-storage/summary` | any role, scoped to authorized storages |
| `GET /api/object-storage/:id` | any role, `object_storage.view` |
| `PATCH /api/object-storage/:id` | admin only |
| `DELETE /api/object-storage/:id` | admin only (soft-delete, §"Removing") |
| `POST /api/object-storage/:id/test-connection` | admin only |
| `POST /api/object-storage/:id/access` | admin only |
| `DELETE /api/object-storage/:id/access/:userId` | admin only |
| `GET /api/object-storage/:id/metrics/current` \| `/history` | any role, `object_storage.monitor` |
| `GET /api/object-storage/:id/security` \| `/growth` \| `/health` | any role, `object_storage.view` |
| `GET /api/object-storage/:id/objects` \| `/objects/search` \| `/objects/metadata` \| `/objects/preview` | any role, `object_storage.browser` |
| `POST /api/object-storage/:id/objects/download` | any role, `object_storage.download` |
| `GET /api/my-access` | any role — `vms`/`databases`/`object_storage` sections, each scoped to the caller |

`GET /api/object-storage/summary` is registered ahead of the `/:id` route
in `router.go` for readability, though Go 1.22+'s `net/http.ServeMux`
resolves the two unambiguously by specificity regardless of registration
order (a literal path segment always outranks a same-position `{id}`
wildcard) — verified directly by a test that hits both paths in the same
run.

## 19. Retention & rate limits

`ObjectStorageRetentionService` runs daily, deleting
`object_storage_metrics` rows older than
`OBJECT_STORAGE_METRICS_RETENTION_DAYS` (default `30`) — nothing else.
`object_storages` configuration, `standalone_object_storage_credentials`,
`object_storage_deep_metrics`, and `audit_logs` are never touched by this
job.

`ObjectStorageConnectionLimiter` (a small `chan struct{}`-backed
semaphore, `OBJECT_STORAGE_MONITOR_MAX_CONNECTIONS`, default `5`) is
**shared by both the fast and deep schedulers** — the same instance is
wired into both via `SetConnectionLimiter` — so the two cycles' worker
pools can never together open more concurrent S3 client connections than
this one cap allows, regardless of how high either scheduler's own worker
count is configured.

## 20. Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `OBJECT_STORAGE_CONNECTION_TIMEOUT` | `10s` | Budget for one connect+probe cycle (test-connection, deep-cycle security-fact calls). |
| `OBJECT_STORAGE_METRICS_INTERVAL` | `60s` | Fast-cycle (`HeadBucket`-only) collection cadence. |
| `OBJECT_STORAGE_METRICS_WORKERS` | `3` | Fast-cycle scheduler worker pool size. |
| `OBJECT_STORAGE_METRICS_RETENTION_DAYS` | `30` | How long `object_storage_metrics` rows are kept. |
| `OBJECT_STORAGE_METRICS_STALE_AFTER` | `5m` | Age after which a cached/persisted sample is flagged stale. |
| `OBJECT_STORAGE_MONITOR_MAX_CONNECTIONS` | `5` | Shared fast+deep concurrent-connection cap. |
| `OBJECT_STORAGE_DEEP_METRICS_INTERVAL` | `5m` | Deep-cycle (security facts, growth, CloudWatch) cadence. |
| `OBJECT_STORAGE_DEEP_METRICS_WORKERS` | `2` | Deep-cycle scheduler worker pool size. |
| `OBJECT_STORAGE_GROWTH_WARNING_PERCENT` | `20` | Projected 7-day growth % above which `OBJECT_STORAGE_HIGH_GROWTH` fires. |
| `OBJECT_STORAGE_ERROR_RATE_WARNING_PERCENT` | `5` | Error rate % above which `OBJECT_STORAGE_HIGH_ERROR_RATE` fires. |
| `OBJECT_STORAGE_PUBLIC_ACCESS_SEVERITY` | `CRITICAL` | Severity of the public-access recommendation (normalized onto `LOW/MEDIUM/HIGH/CRITICAL`). |
| `OBJECT_STORAGE_MAX_PAGE_SIZE` | `200` | Server-enforced upper bound on a listing/search page size. |
| `OBJECT_STORAGE_DOWNLOAD_URL_TTL` | `5m` | How long a presigned download URL stays valid. |
| `OBJECT_STORAGE_PREVIEW_MAX_BYTES` | `5242880` (5 MiB) | Cap on how much of an object the preview endpoint will ever read into memory. |
