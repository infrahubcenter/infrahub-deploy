# Authentication & Authorization Architecture

Step 3 adds identity ("who are you") and VM-scoped access control ("what
can you see") on top of the Step 2 schema; Step 4 adds the project/group/VM
management endpoints and UI that create the projects, groups, and VMs this
model actually governs, plus deactivation semantics (§6) and cross-project
validation (§7). This document covers all of it, plus the design decisions
behind it. It does not cover SSH/console *execution* -- only the
authorization primitive a future console endpoint will call.

## 1. Authentication

- **Password storage**: Argon2id (`internal/services/password.go`), OWASP
  interactive baseline (19 MiB memory, t=1). Never plaintext, never
  reversible.
- **Access token**: short-lived JWT (HS256, default 15 min), claims limited
  to `sub` (user ID), `role`, `jti`, `iat`, `exp`. No credentials, no PII
  beyond the user ID, ever.
- **Refresh token**: opaque random value (32 bytes). Only its SHA-256 hash
  is stored (`refresh_tokens.token_hash`); presenting a token rotates it
  (old row revoked, new row created) and reusing an already-revoked token
  revokes *every* refresh token for that user, on the assumption reuse
  means theft.
- **Cookies**: both tokens are set as `HttpOnly` cookies (never
  `localStorage`). Access token cookie is scoped `Path=/`; refresh token
  cookie is scoped `Path=/api/auth` so it's only ever sent to
  refresh/logout. `Secure` defaults to `false` only when `APP_ENV=development`
  (see `COOKIE_SECURE` in `.env.example`); everywhere else it defaults to
  `true`. `SameSite=Lax` is sufficient here because the frontend and
  backend are same-site (both "localhost", differing only by port).
- **`RequireAuthentication`** (`internal/middleware/auth.go`) re-loads the
  user's live row (`AuthService.Me`) on every request rather than trusting
  the JWT's role claim -- a disabled account or role change takes effect on
  the very next request, not whenever the token happens to expire.
- **Admin bootstrap** (`cmd/bootstrap-admin`): reads
  `BOOTSTRAP_ADMIN_EMAIL`/`_NAME`/`_PASSWORD` from the environment (never a
  CLI flag, so the password never lands in shell history), and refuses to
  run if any ADMIN account already exists.

## 2. Authorization model

Every user has exactly one role, `ADMIN` or `MEMBER` (Step 2's
`user_roles` supports many-to-many, but this application always assigns
exactly one at creation time).

**Deny by default**, always, for everything VM-scoped. There is no
implicit access from project membership -- see the Step 3 spec's explicit
worked example: a member assigned to the `Production` group of project
`Backend` can see `production-backend-01/02`, but not
`development-backend-01`, even though all three belong to the same
project.

`AuthorizationService.CanAccessVM(user, vmResourceID, permission)`
(`internal/services/authorization.go`) is the single source of truth,
checked in this order:

1. **ADMIN role** → always allowed.
2. **Direct grant** (`resource_permissions`) → allowed if a row exists for
   `(vm, user, permission)`.
3. **Group membership** (`group_members` + the VM's `resources.group_id`)
   → allowed for `vm.view` *and* `vm.connect` if the user belongs to the
   VM's group. Group access is intentionally coarse ("you're on this
   team") where direct access is intentionally fine-grained (an admin can
   grant `vm.view` alone).
4. Otherwise → **deny**.

Direct and group access are independent and both persist: removing one
never affects the other (Step 3 spec §17). When a user has both for the
same VM, `GetUserVMAccess` reports the merged, deduplicated permission set
(§19) with `access_source: "DIRECT"` (the more specific, intentionally-set
grant).

`GetUserVMAccess(user)` computes the full accessible-VM list for a user in
one pass -- an ADMIN gets every VM (`access_source: "ADMIN"`); a MEMBER
gets the union of direct grants and group-derived access. This backs
`GET /api/vms` (filtered per caller) and `GET /api/my-access` (identical
computation, member-facing shape).

### Why VM-only

Only `vm.view` / `vm.connect` are enforced in this step. `resources` also
covers `DATABASE` and `OBJECT_STORAGE`, and `CanAccessVM` deliberately
checks `resource_type = 'VM'` (`GetVMResourceByID`) rather than any
resource -- extending the same three-tier model (admin / direct / group)
to other resource types is a later step's work, not a redesign.

## 3. 404-not-403: the disclosure policy

For every VM-scoped endpoint (`GET /api/vms/:id`, and the future console
endpoint), an authorization failure and "this VM doesn't exist" are
**indistinguishable**: both return `404 Not Found` with no VM data in the
body. A `403` would itself leak that the ID is real -- confirming its
existence to a member probing IDs they don't have access to. This is
verified directly: `TestVMAccess_MemberDeniedUnauthorizedVM_NoLeak` in
`internal/server/router_test.go` asserts the 404 body contains none of
`address`, `hostname`, `name`, `project`.

`403 Forbidden` is reserved for pure role gates where no resource
existence question applies: an endpoint like `POST /api/users` either
requires the ADMIN role or it doesn't -- there's nothing to enumerate by
probing it.

## 4. Console authorization (future SSH, not built yet)

No SSH/console endpoint exists in this step. What exists is the
authorization primitive it must call before ever touching a connection:

```
Browser → WebSocket → Go backend
                          │
                          ├─ RequireAuthentication (who are you)
                          ├─ CanAccessVM(user, vmID, "vm.connect") (deny by default)
                          └─ only then: SSH → VM
```

`vm.view` and `vm.connect` are independent permissions -- a user with
`vm.view` but not `vm.connect` can see a VM's details but the console
control must be disabled (frontend) and any future console endpoint must
independently deny (backend). This is exercised directly by
`TestCanAccessVM_ViewGrantDoesNotImplyConnect` and
`TestCanAccessVM_ConsoleDeniedByDefault` in
`internal/services/authorization_test.go`.

## 5. API surface

| Method & path | Auth | Notes |
| --- | --- | --- |
| `POST /api/auth/login` | public | generic "Invalid email or password." for wrong password, unknown email, *and* disabled account |
| `POST /api/auth/refresh` | refresh cookie | rotates the token |
| `POST /api/auth/logout` | refresh cookie | idempotent |
| `GET /api/auth/me` | any role | |
| `GET /api/my-access`, `GET /api/my-access/vms` | any role | `{"vms":[...]}` / bare array |
| `GET /api/vms`, `GET /api/vms/:id` | any role | filtered per caller; 404 on denial |
| `POST /api/users`, `GET /api/users`, `GET /api/users/:id`, `PATCH /api/users/:id` | ADMIN | |
| `POST /api/users/:id/vm-access`, `DELETE /api/users/:id/vm-access/:vmId` | ADMIN | permissions limited to `vm.view`/`vm.connect` |
| `POST /api/groups/:groupId/members`, `DELETE /api/groups/:groupId/members/:userId` | ADMIN | |
| `POST /api/projects`, `GET /api/projects`, `GET /api/projects/:id`, `PATCH /api/projects/:id` | ADMIN | Step 4 |
| `POST /api/projects/:projectId/groups`, `GET /api/projects/:projectId/groups`, `GET /api/groups/:id`, `PATCH /api/groups/:id` | ADMIN | Step 4 |
| `GET /api/groups/:groupId/members` | ADMIN | Step 4 |
| `GET /api/resources`, `GET /api/resources/:id`, `POST /api/resources`, `PATCH /api/resources/:id` | ADMIN | Step 4; DATABASE/OBJECT_STORAGE placeholders only -- VM creation always goes through `/api/vms` |
| `POST /api/vms`, `PATCH /api/vms/:id`, `GET /api/vms/:id/access` | ADMIN | Step 4 |

## 6. Deactivation and effective access (Step 4)

Deactivating a group or a VM must stop granting *new* access without
deleting anything (§33/§34 of the Step 4 spec). Both are enforced inside
`AuthorizationService`, not as a separate check layered on top, so there is
exactly one place that decides "can this user reach this VM right now":

- **`groups.is_active = false`**: `IsUserGroupMember` and
  `ListVMResourceIDsForUserGroups` (`sql/queries/groups.sql`) both join
  `groups` and require `is_active = true`. Existing `group_members` rows
  are untouched -- membership is preserved, just inert. Reactivating the
  group makes it effective again immediately, with no data to restore.
- **`resources.status = 'DISABLED'`**: `AuthorizationService.EffectiveVMAccess`
  returns "no access" outright once it loads a DISABLED resource, before
  even checking direct/group grants -- so an existing direct grant does
  not survive deactivation the way it survives a *group* removal. This is
  deliberate: DISABLED means "this VM is not currently a valid target for
  anyone but an admin," not "everyone except one specific grant."
- **ADMIN bypasses both.** An admin can still see and reactivate a
  deactivated group or VM; the checks above only gate MEMBER access.

Both are covered by dedicated tests:
`TestVM_DeactivatedGroup_GrantsNoAccess` and
`TestVM_Deactivated_CannotBeNewlyAccessed` in
`internal/server/router_test.go`.

## 7. Cross-project validation (Step 4)

A resource's `group_id`, when set, must belong to the same `project_id` as
the resource -- e.g. a VM being created/moved under project *Backend*
cannot be pointed at a group that belongs to project *Frontend* (Step 4
spec §31/§32). This is checked twice, deliberately:

1. **Application layer**: `validateGroupInProject`
   (`internal/services/group.go`), called from `VMService.Create`/`Update`
   and `ResourceService.CreatePlaceholder`/`Update` *before* any write,
   returns a clean `ErrCrossProjectGroup` → `400 Bad Request` with an
   understandable message.
2. **Database layer**: the `check_resource_group_project` trigger from
   Step 2 (`004_resources.sql`) rejects the same case at the constraint
   level regardless of which code path reaches it. `isRaisedException`
   (`internal/services/errors.go`) recognizes this trigger's exception
   (SQLSTATE `P0001`) and maps it to the same `ErrCrossProjectGroup`, so
   even a bug that skipped step 1 still surfaces as a clean 400, not a raw
   500. Application validation is required either way (Step 4 §32) -- the
   trigger is the backstop, not the primary defense, since a raw
   trigger-raised message is not something to hand back to an API caller.

Verified in `TestGroups_DuplicateRejected_CrossProjectVMRejected`
(`internal/server/router_test.go`).

## 8. Service architecture (Step 4)

Handlers never talk to the database or `AuthorizationService` directly;
they parse the request, call one service method, and shape the response.
Each management concern is its own service in `internal/services/`:

```
Handler → Service → AuthorizationService → repository.Store → PostgreSQL
```

| Service | Owns |
| --- | --- |
| `ProjectService` | project CRUD, name uniqueness |
| `GroupService` | group CRUD, group membership, `validateGroupInProject` |
| `ResourceService` | generic resource CRUD (DATABASE/OBJECT_STORAGE placeholders) |
| `VMService` | VM create/update (resource+vms in one transaction), `List`/`Get` (via `AuthorizationService`), `ListAccess` |
| `AccessService` | direct VM permission grant/revoke (`resource_permissions`) |

Sentinel errors (`ErrNotFound`, `ErrDuplicateName`, `ErrValidation`,
`ErrCrossProjectGroup` in `internal/services/errors.go`) cross the
service→handler boundary; `internal/handlers/errors.go`'s
`writeServiceError` is the one place that maps them to HTTP status codes,
so every management handler responds consistently.

## 9. Audit events

`internal/services/audit.go` defines the event names -- authentication
(`USER_LOGIN_SUCCESS`, `USER_LOGIN_FAILED`, `USER_LOGOUT`,
`USER_DISABLED`), VM access (`VM_ACCESS_GRANTED`/`REVOKED`), group
membership (`GROUP_MEMBER_ADDED`/`REMOVED`), and, from Step 4, management
events for projects/groups/VMs (`PROJECT_CREATED`/`UPDATED`/`DEACTIVATED`,
`GROUP_CREATED`/`UPDATED`/`DEACTIVATED`,
`VM_CREATED`/`UPDATED`/`DEACTIVATED`) -- and writes to the append-only
`audit_logs` table from Step 2 (see `013_fix_audit_log_append_only.sql`
in `docs/database-architecture.md` for a correction made in Step 3).
Audit writes are best-effort: a failure to write an audit row never blocks
or fails the underlying request. No audit metadata ever includes a
password, token, or credential value. Verified in
`TestAudit_ManagementEventsRecorded`.

## 10. Frontend route protection is UX only

`frontend/src/proxy.ts` (Next.js 16's renamed `middleware.ts`) only checks
*cookie presence* to decide whether to redirect to `/login` -- it cannot
verify the JWT (the signing secret is backend-only) and makes no
authorization decision. Per-page role gating
(`components/auth/route-guard.tsx`) redirects a MEMBER away from
`/admin/*` to `/forbidden`, again as UX. The backend enforces everything
independently on every request; a member editing the DOM or calling the
API directly gets exactly the same 403/404 the UI would have prevented.

## 11. Step 18: Central User Management, Roles, Permissions & Resource Access Control

Step 18 makes `/admin/users` fully functional (search/filter/pagination,
role-change, per-type access views) and ships the previously-nonexistent
`/permissions` page, without changing the authorization model itself. A
full codebase survey preceded the work and closed off several tempting-
but-unnecessary additions:

- **Roles remain exactly `ADMIN`/`MEMBER`.** No dynamic roles, no
  `role_permissions` table -- `user_roles` still supports many-to-many at
  the schema level, but this application still assigns exactly one role
  at creation time, unchanged since Step 2.
- **No explicit-DENY list, no project-level grant tier, no Docker
  permission tier.** The existing deny-by-default model (Admin bypass →
  Direct ∪ Group → deny, §2 above) is preserved exactly. Project
  membership still grants nothing -- `project_members` remains dead code;
  "My Access" surfaces Projects/Groups by *deriving* which ones contain a
  resource the user can actually reach, never by resurrecting
  `project_members` as a grant mechanism. Docker still has no permission
  tier of its own: `DockerHandler.authorizeVMView`/`authorizeContainer`
  fully inherit from the parent VM's `vm.view`, unchanged since Step 8.
- **404-vs-403 split is unchanged (§3 above), confirmed under an explicit
  regression test.** Resource-scoped endpoints (`GET /api/databases/:id`
  and the VM/ObjectStorage equivalents) still 404 on any authorization
  failure. Pure role-gated category endpoints (`POST /api/users`,
  `GET /api/permissions`, `GET /api/users/:id`) still 403 via
  `RequireRole`, with no existence question to hide. One layering detail
  is easy to get backwards: the three "Authorized Members" list endpoints
  (`GET /api/{vms,databases,object-storage}/:id/access`) are
  administrative actions, not resource-view endpoints -- they sit behind
  `requireAdmin` *at the router level*, so a Member is rejected with 403
  by `RequireRole` before the handler ever runs, even if that Member holds
  a direct view grant on the exact resource named in the URL. The
  handler's own `authorizeDatabase`/`authorizeObjectStorage`-style 404
  logic is simply never reached for a non-admin caller on these three
  routes. `TestIDORPolicy_ResourceScopedIs404_CategoryEndpointIs403` and
  `TestIDORPolicy_VMListAccess_MemberForbiddenEvenWithOwnGrant`
  (`internal/server/idor_policy_test.go`) exercise both halves of this
  split, plus the ListAccess layering nuance, directly.
- **Role-change API**: `PATCH /api/users/:id` (`role`, `confirmation`)
  delegates to `AuthService.UpdateUserAccount`, which takes a Postgres
  advisory transaction lock (`pg_advisory_xact_lock`) before evaluating
  the last-active-admin invariant -- closing a race where two concurrent
  requests could each demote one of the last two admins and leave zero.
  A change that would leave zero active admins is rejected with `409`
  (`ErrLastActiveAdmin`) regardless of confirmation; an admin's own
  self-demotion additionally requires `confirmation: true` or is rejected
  with `400`. Both are real, backend-enforced invariants, not a
  frontend-only confirm dialog -- see `TestLastAdmin_CannotDisable`,
  `TestLastAdmin_CannotDemote`, `TestSelfDemotion_RequiresConfirmation`,
  and `TestSelfDemotion_LastAdminRejectedEvenWithConfirmation`
  (`internal/server/users_role_test.go`).
- **`GET /api/permissions` is direct-grants-only, by design.** It lists
  every `resource_permissions` row across VM/Database/ObjectStorage in one
  place, but deliberately excludes group-derived access: a `Source: GROUP`
  row isn't individually revocable the way this page's revoke action
  implies (revoking means removing group membership, a different action
  entirely). Group-derived access remains visible where it always has
  been -- each resource type's own `ListAccess` endpoint, which merges
  direct and group-derived rows with an explicit `access_source`.
- **No new generic grant/revoke mutation endpoint.** The Permissions
  page's grant/revoke actions dispatch client-side to the three existing
  per-type endpoints (VM/Database/ObjectStorage grant and revoke) rather
  than introducing a generic endpoint that would either indirect to the
  same three service methods or duplicate their logic a third time.
- **Status (`ACTIVE`/`INVITED`/`DISABLED`) is derived, not a stored
  enum.** `DISABLED` if `!is_active`; `INVITED` if `is_active` and
  `last_login_at IS NULL`; `ACTIVE` otherwise. `last_login_at` is set only
  from `AuthService.Login` (never `Refresh`), so "Last Login" reflects an
  actual login rather than silent token renewal. See
  `TestUserStatus_DerivedCorrectly`.

WebSocket authorization was re-verified, not changed: both `DockerHandler`'s
container-stats stream (`internal/handlers/docker_stream.go`) and
`AlertsHandler.Stream` (`internal/handlers/alerts.go`) resolve their
resource/scope authorization check *before* calling `Upgrader.Upgrade`, and
both restrict `CheckOrigin` to the configured frontend origin (or no
`Origin` header at all, for same-origin/non-browser tools) -- identical in
shape to every REST endpoint's authorization, and identical to the
Step 8/17-era implementation. Prior to this step neither stream had any
dedicated test; `internal/server/websocket_auth_test.go` closes that gap,
driving real handshake attempts through `gorilla/websocket`'s `Dialer` and
asserting the pre-upgrade rejection status (404 for an unauthorized
Docker-stream caller, 401 for an unauthenticated alerts-stream caller, 403
for a foreign `Origin` on either) alongside a same-origin authorized
success case for both.

## 12. Step 19: Central Infrastructure Monitoring & Observability Dashboard

Step 19 adds `MonitoringDashboardHandler` (`internal/handlers/monitoring_dashboard.go`)
and three routes -- no new authorization primitive, no new grant mechanism.
All three reuse the exact merge `MyAccessHandler`/`AlertsHandler` already
use, so an unauthorized resource can never appear in any of them for the
same reason it can never appear in `GET /api/my-access` or `GET /api/alerts`.

- **`GET /api/monitoring/overview?project_id=&group_id=`** -- per-type
  health/availability tallies (VM/Database/Object Storage/Docker) plus
  Alerts/Recommendations summaries.
- **`GET /api/monitoring/resources?resource_type=&project_id=&group_id=&health=&alert_severity=&search=`**
  -- the unified, unpaginated VM/Database/Object Storage table.
- **`GET /api/monitoring/timeline?project_id=&group_id=&limit=`** -- a
  "recent events" feed composed from Alerts' and Recommendations' own
  lifecycle timestamps (`first_seen_at`/`acknowledged_at`/`resolved_at`,
  `detected_at`/`resolved_at`), exploded into synthetic
  `ALERT_TRIGGERED`/`ALERT_ACKNOWLEDGED`/`ALERT_RESOLVED`/
  `RECOMMENDATION_DETECTED`/`RECOMMENDATION_RESOLVED` events, sorted
  newest-first and truncated to `limit`. Deliberately *not* a new
  `GET /api/audit-logs` endpoint: `audit_logs` mixes security events with
  operational ones and has no category column, so a correctly-scoped audit
  endpoint is a standalone feature in its own right, not something to bolt
  onto one dashboard panel. A null `acknowledged_at`/`resolved_at` means
  "that event never happened" -- it is never fabricated at a placeholder
  time; a never-acknowledged, never-resolved alert contributes exactly one
  event.

**Scoping model**: all three routes are `authenticated` (any role), not
`requireAdmin` -- exactly like `/api/alerts` and `/api/my-access` today,
the response scoping itself is the security boundary, not a per-route role
gate. This is deliberate: these are aggregate/list endpoints with no single
resource ID in the URL to 404 on, so the §3 404-vs-403 disclosure policy
doesn't apply here the way it does to `GET /api/vms/:id` -- the equivalent
protection is that `loadAuthorizedResources` (the one shared merge+filter
function all three routes call) excludes every unauthorized VM/Database/
Object Storage row *before* any of Overview's tallies, Resources' Go-side
filters (`resource_type`/`project_id`/`group_id`/`health`/`alert_severity`/
`search`), or Timeline's alert/recommendation fetch ever run, so a filter
can only ever narrow that already-authorized set, never widen it back out.
Alerts/Recommendations scoping (Overview's and Timeline's own
`resourceIDs`) reuses `services.GetUserAlertAccessResourceIDs` directly,
the same function `GET /api/alerts` and `GET /api/recommendations` use.

**Object Storage alerts/recommendations fix (Phase 0)**: before this step,
`GetUserAlertAccessResourceIDs` (`internal/services/alert_service.go`) only
ever merged VM and Database access, never Object Storage, despite Object
Storage alert types and recommendations being generated since Step 17. A
Member granted only Object Storage access saw zero alerts/recommendations
for it on `GET /api/alerts`, `GET /api/alerts/summary`,
`GET /api/alerts/stream`, and `GET /api/recommendations` alike (all four
call this one function) -- an under-report, never a leak, but one the new
dashboard would otherwise have silently inherited and amplified. The fix
adds a `GetUserObjectStorageAccess` merge alongside the existing VM/Database
one; `RecommendationHandler.List` was also switched from its own separate
VM+DB-only merge to this now-fixed shared function, removing a second,
independently-drifting implementation of the same scoping rule.

**Docker is not a `resource_type`** in `GET /api/monitoring/resources` or
anywhere else in this codebase's authorization model -- Docker containers
are nested under a VM and inherit `vm.view` entirely (§11 above), and
container-scoped alerts already report their parent VM's `resource_type`.
The Overview `docker` bucket is summary-only (host/container/image counts
across the caller's authorized VMs), not a filterable resource row.
