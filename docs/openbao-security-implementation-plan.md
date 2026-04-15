# OpenBao security implementation plan for MoneyTree

## Purpose

Strengthen MoneyTree's secrets management and operational security for a finance-focused application while
preserving a self-hosted deployment model.

This plan proposes a high-security, self-hosted secret delivery model centered on OpenBao, with the
following goals:

- remove production dependence on long-lived plaintext environment secrets where practical
- keep all raw secret access server-side only
- avoid turning the app or its admin panel into a second secret-management UI
- support secret rotation and least-privilege access
- keep local development simple while making production stricter
- fit MoneyTree's current Phoenix + Next.js + runtime-config architecture

This document is intentionally implementation-oriented and repo-specific.

---

## Current security baseline in the repo

MoneyTree already has several strong foundations:

- Phoenix runtime configuration is centralized in `config/runtime.exs`
- the app fails fast in production for several missing critical settings
- WebAuthn/passkey support already exists in the auth/control-panel surface
- owner-aware UI already exists in the Next control panel
- authenticated API routing already distinguishes normal and owner access

At the same time, `config/runtime.exs` currently loads many sensitive values directly from environment
variables in production, including:

- Teller webhook secret
- Teller client certificate / private key material
- Plaid secret and webhook secret
- SMTP credentials
- `CLOAK_VAULT_KEY`
- database credentials / URL
- `SECRET_KEY_BASE`

This is workable, but not ideal for a finance-oriented product.

---

## Security objectives

### Primary objectives

1. move sensitive production secrets to a self-hosted secret backend
2. give the MoneyTree app only read access to the exact secrets it needs
3. avoid broad or static vault tokens when possible
4. make secret usage observable without exposing values
5. preserve deterministic startup and failure behavior
6. keep browser/admin access away from raw secret payloads

### Secondary objectives

1. make secret rotation easier
2. support future integrations safely, including mortgage document extraction providers and rate providers
3. reduce secret sprawl across `.env`, deployment files, and host configuration
4. prepare the app for more formal production hardening later

---

## Recommended target architecture

## High-level design

Use OpenBao as the source of truth for production secrets.

MoneyTree should access OpenBao through a narrow backend integration layer, with strict separation between:

- configuration metadata
- secret references
- actual secret values

### Core rule

The browser must never receive raw secret values.

The Next control panel or any owner/admin page may show integration health and secret reference status, but
must not become a general-purpose vault browser or secret editor.

### Recommended architecture components

- `MoneyTree.Secrets`
- `MoneyTree.Secrets.OpenBao`
- `MoneyTree.Secrets.Provider` behavior
- `MoneyTree.Secrets.Cache` optional lightweight in-memory cache
- `MoneyTree.Secrets.Health` status checks for UI and observability

### Recommended backend responsibility split

- `config/runtime.exs` remains the final assembly point for runtime config
- `MoneyTree.Secrets.*` resolves values from OpenBao or allowed fallbacks
- business logic and controllers never fetch secrets ad hoc
- the admin/control-panel surface uses health/status APIs only

---

## Recommended auth model for OpenBao

## Preferred approach

Use a dedicated MoneyTree machine identity with least-privilege access.

### Strong recommendation

Use one of these in order of preference:

1. AppRole or similarly constrained machine auth with short-lived or renewable tokens
2. platform identity auth if the final production environment supports it cleanly
3. a wrapped bootstrap token only as a temporary stepping stone during rollout

### Do not do this in production

- do not use a root token
- do not use a broad admin token
- do not share one generic token across unrelated apps
- do not put a powerful long-lived token into the Next frontend or browser-visible config

## Policy model

Create a dedicated policy for MoneyTree production, for example:

- `moneytree-prod-read`

This policy should allow read-only access to exact paths such as:

- `kv/data/moneytree/prod/database`
- `kv/data/moneytree/prod/cloak`
- `kv/data/moneytree/prod/phoenix`
- `kv/data/moneytree/prod/plaid`
- `kv/data/moneytree/prod/teller`
- `kv/data/moneytree/prod/smtp`
- `kv/data/moneytree/prod/stripe`
- `kv/data/moneytree/prod/providers/*` later if needed

Keep the policy read-only.

Do not give MoneyTree rights to:

- list unrelated secret trees
- write secrets
- modify auth backends
- issue high-privilege tokens
- manage PKI or transit globally

---

## What should move to OpenBao first

## Phase 1 secret groups

These are the best first candidates because they are already in runtime config and clearly sensitive.

### Group A — finance integration secrets

- `PLAID_CLIENT_ID` optional to move now
- `PLAID_SECRET`
- `PLAID_WEBHOOK_SECRET`
- `TELLER_CONNECT_APPLICATION_ID` optional to move now
- `TELLER_WEBHOOK_SECRET`
- `TELLER_CERT_PEM` or file-backed equivalent
- `TELLER_KEY_PEM` or file-backed equivalent
- Stripe Connect client credentials if used in production

### Group B — app crypto and auth

- `CLOAK_VAULT_KEY`
- `SECRET_KEY_BASE`

### Group C — infrastructure/application credentials

- `DATABASE_URL` or database password components
- SMTP username/password

### Group D — later additions

- mortgage rate provider API keys
- OCR / extraction provider credentials
- future mail or notification provider credentials
- future document storage credentials if needed

## What can stay as regular env for now

These are typically configuration, not secrets:

- `PHX_HOST`
- `PORT`
- `PHX_SERVER`
- `NEXT_PROXY_URL`
- `NEXT_PROXY_*`
- `OTEL_EXPORTER_OTLP_ENDPOINT` depending on environment
- queue concurrency settings

---

## Runtime integration strategy

## Guiding principle

Do not scatter OpenBao calls throughout the codebase.

The app should resolve secrets in one place and then configure the application from those resolved values.

## Recommended runtime model

Add a provider abstraction like:

- `MoneyTree.Secrets.Provider`
- `MoneyTree.Secrets.OpenBao`
- `MoneyTree.Secrets.Env`

### Example responsibilities

`MoneyTree.Secrets.Provider`
- defines a consistent interface for reading named secret groups

`MoneyTree.Secrets.OpenBao`
- authenticates to OpenBao
- reads configured paths
- normalizes payloads into repo-friendly maps
- returns structured errors for missing/unreadable paths

`MoneyTree.Secrets.Env`
- resolves from environment variables
- used for local development and controlled fallback modes

`MoneyTree.Secrets`
- app-facing facade used by `runtime.exs`
- resolves groups like `:database`, `:cloak`, `:plaid`, `:teller`, `:smtp`
- chooses provider based on deployment mode

## Deployment mode concept

Introduce an explicit secret backend mode, for example:

- `env`
- `openbao`
- `hybrid`

### Intended use

- local dev: `env`
- staging: `hybrid` allowed temporarily
- production: `openbao` strongly preferred

### Behavior rules

#### `env`
- use environment variables only
- intended for local development and emergency scenarios

#### `openbao`
- required secret groups must be resolved from OpenBao
- production should fail fast if required groups are unreadable or missing

#### `hybrid`
- prefer OpenBao
- allow controlled env fallback during migration only
- expose warning/telemetry when env fallback was used

---

## Critical startup behavior

MoneyTree is a finance-oriented app, so startup behavior must be strict and predictable.

## Required production rule

In production, if a critical secret group cannot be resolved, the app should fail to boot rather than run in
an ambiguous or degraded state.

### Critical groups

- `:database`
- `:cloak`
- `:phoenix`

### Strongly recommended critical groups

- `:plaid` if Plaid is enabled in production
- `:teller` if Teller is enabled in production
- `:smtp` if production mail delivery is required

## Why this matters

Fail-fast is safer than:

- silently booting with missing crypto material
- partially broken webhook validation
- inconsistent encrypted data handling
- accidental drift into stale environment fallback

---

## Special handling for `CLOAK_VAULT_KEY`

This deserves special attention.

`CLOAK_VAULT_KEY` is used to configure encrypted fields and is foundational to sensitive data access. That
makes it more sensitive than an ordinary API key.

## Recommendation

Move `CLOAK_VAULT_KEY` to OpenBao in production, but do it carefully.

### Requirements

- the key must be available before app runtime config completes
- startup must fail hard if the key is missing or unreadable in production
- local dev should still allow `.env` or a dev-safe fallback
- rotation must be treated as a planned key-management event, not casual drift

## Rotation note

Do not implement automatic Cloak key rotation in the first slice.

Instead:
- first move the authoritative key source to OpenBao
- then document a later multi-key rotation plan if needed

---

## Special handling for `SECRET_KEY_BASE`

This also belongs in the high-sensitivity tier.

## Recommendation

Resolve `SECRET_KEY_BASE` from OpenBao in production using the same strict rules as `CLOAK_VAULT_KEY`.

### Reasoning

- it protects cookies/session signing
- it is part of the app's trust boundary
- it should not drift across environments accidentally

---

## Recommended OpenBao path structure

Use a predictable path layout.

### Example

- `kv/data/moneytree/dev/database`
- `kv/data/moneytree/dev/cloak`
- `kv/data/moneytree/dev/phoenix`
- `kv/data/moneytree/dev/plaid`
- `kv/data/moneytree/dev/teller`
- `kv/data/moneytree/dev/smtp`

- `kv/data/moneytree/staging/database`
- `kv/data/moneytree/staging/cloak`
- `kv/data/moneytree/staging/phoenix`
- `kv/data/moneytree/staging/plaid`
- `kv/data/moneytree/staging/teller`
- `kv/data/moneytree/staging/smtp`

- `kv/data/moneytree/prod/database`
- `kv/data/moneytree/prod/cloak`
- `kv/data/moneytree/prod/phoenix`
- `kv/data/moneytree/prod/plaid`
- `kv/data/moneytree/prod/teller`
- `kv/data/moneytree/prod/smtp`

## Suggested data layout by secret group

### `database`
- `url`
- or `username`, `password`, `hostname`, `database`, `port`, `ssl`

### `cloak`
- `vault_key`

### `phoenix`
- `secret_key_base`

### `plaid`
- `client_id`
- `secret`
- `webhook_secret`
- `environment`
- `redirect_uri` if treated as sensitive enough for your process

### `teller`
- `connect_application_id`
- `webhook_secret`
- `client_cert_pem`
- `client_key_pem`
- host overrides if desired

### `smtp`
- `host`
- `port`
- `username`
- `password`
- `verify_mode`

---

## What the admin/control panel should and should not do

MoneyTree already has an authenticated control panel and owner-aware UI. Keep it useful, but sharply limited.

## Safe scope for the control panel

Add a **Secret backend status** card or owner-only page that shows:

- current secret backend mode (`env`, `openbao`, `hybrid`)
- OpenBao reachable: yes/no
- last successful secret resolution time
- token/lease renewable: yes/no if available
- required secret groups status:
  - configured
  - missing
  - unreadable
  - fallback used
- last validation error message sanitized for display

## Safe actions

Allow at most:

- revalidate secret backend connectivity
- test read access to required paths without returning values
- refresh cached health status

## Forbidden actions for the control panel

Do not allow the app UI to:

- show raw secret values
- browse arbitrary OpenBao paths
- edit or write secret payloads
- create policies or auth backends
- mint powerful tokens
- manage unrelated secrets

## Why

The admin panel is still part of the application trust surface. If it becomes a vault console, any app-layer
compromise becomes a secrets compromise.

---

## Observability and auditing

## Add structured telemetry for secret operations

Track at least:

- startup secret resolution success/failure
- health-check success/failure
- provider mode in use
- fallback usage in hybrid mode
- time spent resolving secret groups
- cache hits/misses if caching is added

Do not log:

- raw secret values
- PEM material
- full tokens
- decrypted payloads

### Safe log examples

- `secret_group=plaid provider=openbao status=ok`
- `secret_group=cloak provider=openbao status=missing`
- `secret_group=teller provider=env status=fallback_used`

---

## Hardening recommendations beyond OpenBao

OpenBao improves secret handling, but it is not the whole security story.

## Additional hardening steps recommended for MoneyTree

### 1. tighten owner/admin surface

- keep owner-only pages strictly role-guarded
- consider requiring fresh auth or a step-up check for sensitive owner actions later
- log owner-panel access events

### 2. harden session policy

- shorten owner session lifetime relative to standard sessions if feasible later
- surface session revocation clearly in UI
- consider more aggressive session controls for owner access over time

### 3. protect deployment boundary

- keep OpenBao reachable only from trusted network paths
- do not expose OpenBao broadly to the public internet if avoidable
- use TLS and verify peer certificates

### 4. secrets on disk

- avoid writing resolved secrets to temporary files unless absolutely necessary
- prefer in-memory use for PEM values where feasible

### 5. limit secret blast radius

- separate environments strictly
- separate app roles from operator/admin roles
- never reuse prod credentials in lower environments

---

## Proposed repo changes

## New backend modules

Recommended additions under `apps/money_tree/lib/money_tree`:

- `money_tree/secrets.ex`
- `money_tree/secrets/provider.ex`
- `money_tree/secrets/env.ex`
- `money_tree/secrets/open_bao.ex`
- `money_tree/secrets/health.ex`

## Recommended supporting config additions

Add environment variables or config references such as:

- `SECRET_BACKEND_MODE`
- `OPENBAO_ADDR`
- `OPENBAO_NAMESPACE` optional
- `OPENBAO_AUTH_METHOD`
- `OPENBAO_ROLE_ID`
- `OPENBAO_SECRET_ID` or wrapped bootstrap method depending on rollout
- `OPENBAO_KV_PREFIX`
- `OPENBAO_SSL_VERIFY`
- `OPENBAO_TIMEOUT_MS`

These should be metadata and connection hints, not the actual business secrets themselves.

## Runtime config changes

Update `config/runtime.exs` so that:

- secret group resolution happens through `MoneyTree.Secrets`
- provider mode is explicit
- production fail-fast rules remain or become stricter
- local development stays simple

## Next app changes

Add an owner-only status surface in the control panel area, but keep it status-only.

Possible route:

- `/app/react/control-panel/security`

or add a card to the existing control panel page.

## API changes

Add minimal owner-only endpoints if needed for status checks, for example:

- `GET /api/owner/security/secret-backend`
- `POST /api/owner/security/secret-backend/revalidate`

These endpoints must return status metadata only.

---

## Rollout phases

## Phase 1 — planning and scaffolding

Goal: introduce a secrets abstraction without changing production behavior yet.

Tasks:

1. add `MoneyTree.Secrets` modules and provider abstraction
2. implement `Env` provider first
3. add secret backend mode selection with `env` default
4. refactor `runtime.exs` to use the abstraction while preserving current behavior
5. add tests for secret group resolution and fail-fast behavior

Exit criteria:

- the app still behaves the same in dev/prod using env-backed secrets
- secrets now flow through one abstraction layer

## Phase 2 — OpenBao read integration

Goal: add production-capable OpenBao secret resolution.

Tasks:

1. implement `MoneyTree.Secrets.OpenBao`
2. add OpenBao auth flow using constrained machine identity
3. add read-only group resolution for:
   - database
   - cloak
   - phoenix
   - plaid
   - teller
   - smtp
4. add structured error handling and telemetry
5. add integration tests around configuration resolution where feasible

Exit criteria:

- staging or test environment can boot using OpenBao-backed secrets
- missing critical groups fail safely and clearly

## Phase 3 — status and observability

Goal: make the integration operationally visible without exposing values.

Tasks:

1. add `MoneyTree.Secrets.Health`
2. add owner-only API endpoint(s) for status
3. add a status-only control-panel card/page
4. emit telemetry around health and fallback usage
5. sanitize all returned/logged error messages

Exit criteria:

- owners can see integration health
- no secret payloads are visible in the app

## Phase 4 — production migration

Goal: move production off direct secret env usage for the high-priority groups.

Tasks:

1. create production OpenBao paths and policies
2. load production secret groups into OpenBao
3. switch production to `openbao` mode
4. verify startup, integrations, and mail/webhook flows
5. remove or reduce redundant production env secrets where practical

Exit criteria:

- production runs with OpenBao as authoritative secret source
- fallback is either disabled or tightly controlled

## Phase 5 — follow-up hardening

Goal: reduce residual risk and improve operational maturity.

Tasks:

1. add lease renewal/expiry handling if applicable
2. reduce lifetime of bootstrap credentials
3. document rotation playbooks
4. document disaster recovery / OpenBao outage behavior
5. consider future step-up auth for sensitive owner operations

Exit criteria:

- the secret backend integration is stable, observable, and documented

---

## Small execution slices for AI coding agents

These are intentionally narrow and should be separate tasks/PRs.

1. add `MoneyTree.Secrets.Provider` and `MoneyTree.Secrets.Env`
2. refactor `runtime.exs` to read through the new abstraction without behavior changes
3. add tests for env-backed resolution of current secret groups
4. add `MoneyTree.Secrets.OpenBao` client scaffold
5. add OpenBao config metadata parsing and validation
6. implement read resolution for one pilot group such as `:smtp`
7. extend OpenBao resolution to `:plaid` and `:teller`
8. extend OpenBao resolution to `:database`, `:cloak`, and `:phoenix`
9. add fail-fast production tests for missing critical groups
10. add telemetry around secret provider usage
11. add `MoneyTree.Secrets.Health`
12. add owner-only secret backend status endpoint
13. add a status-only control-panel card/page
14. add sanitized revalidation action
15. write deployment docs for OpenBao path/policy setup
16. write operations docs for rotation and outage handling

---

## Testing plan

## Backend tests

Add tests for:

- provider selection by mode
- env-backed secret resolution
- OpenBao response normalization
- missing secret group handling
- invalid OpenBao config handling
- production fail-fast for critical groups
- sanitized error handling
- no accidental secret-value logging

## API tests

Add owner-only endpoint tests for:

- secret backend status retrieval
- unauthorized access rejection
- status revalidation
- sanitized error payloads

## Frontend tests

Add tests for:

- control-panel security status rendering
- missing/healthy/fallback states
- no raw secret values rendered

## Deployment validation

Validate manually in staging:

- app boots with OpenBao-backed secrets
- Plaid/Teller integrations still initialize correctly
- SMTP still sends mail
- encrypted data access still works through Cloak
- health page reports expected status

---

## Non-goals

This implementation plan does not include:

- building a general-purpose vault UI into MoneyTree
- storing user financial data in OpenBao instead of PostgreSQL
- replacing all configuration with secret backend data
- immediate automatic rotation of all cryptographic material
- broad operator workflows for OpenBao administration from inside the app

---

## Final recommendation

For MoneyTree, the best self-hosted security upgrade is not merely “use OpenBao.”

It is:

- use OpenBao as the production source of truth for critical secrets
- authenticate the app with a tightly scoped machine identity
- keep all secret access server-side
- keep the admin surface status-only
- preserve strict startup behavior for critical crypto and database secrets
- migrate in phases so production does not get brittle during rollout

That is the best fit for a self-hosted finance-oriented app with MoneyTree's current architecture.
