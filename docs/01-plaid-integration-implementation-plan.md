# Plaid Integration Implementation Plan

## Purpose

This document is the first implementation plan for Plaid in `MoneyTree`.

The repository already contains Plaid-shaped routes, UI hooks, and tests, but the current
implementation is not a real integration:

- `apps/money_tree/lib/money_tree/plaid/client.ex` is a placeholder
- `apps/money_tree/lib/money_tree_web/controllers/plaid_controller.ex` generates a local fake
  link token instead of calling Plaid
- `config/runtime.exs`, `.env.example`, and `docs/environment-variables.md` do not define any
  `PLAID_*` runtime configuration
- `apps/money_tree/lib/money_tree/plaid/synchronizer.ex` delegates to
  `MoneyTree.Teller.Synchronizer`, which is not a safe long-term design for Plaid-specific
  semantics
- current tests mostly prove local stubs and controller shapes, not a working end-to-end Plaid
  flow

The goal of this plan is to replace the scaffold with a fully functional, testable Plaid
integration that is more reliable than the current Teller path and fits the existing repo
boundaries.

## Goals

1. Add a real server-side Plaid client for link token creation, public token exchange, account
   sync, transaction sync, and webhook verification.
2. Keep all Plaid secrets and request signing on the Phoenix side.
3. Reuse existing MoneyTree persistence models where they fit, but remove hidden Teller coupling
   from Plaid execution paths.
4. Add a test suite strong enough to catch regressions before release.
5. Keep changes incremental and additive unless a breaking change is strictly required.

## Non-Goals

- redesigning institution connection storage across all providers
- replacing Teller in the same change set
- introducing AI-derived financial calculations
- building Plaid-backed import automation beyond the existing connection and sync model

## Current Surfaces To Extend

The first Plaid implementation should be anchored to these existing files and modules:

- `apps/money_tree/lib/money_tree/plaid/client.ex`
- `apps/money_tree/lib/money_tree/plaid/synchronizer.ex`
- `apps/money_tree/lib/money_tree/plaid/sync_worker.ex`
- `apps/money_tree/lib/money_tree/plaid/webhooks.ex`
- `apps/money_tree/lib/money_tree/synchronization.ex`
- `apps/money_tree/lib/money_tree_web/controllers/plaid_controller.ex`
- `apps/money_tree/lib/money_tree_web/controllers/plaid_webhook_controller.ex`
- `apps/money_tree/lib/money_tree_web/router.ex`
- `apps/money_tree/lib/money_tree_web/plugs/content_security_policy.ex`
- `apps/next/app/link-bank/page.tsx`
- `apps/next/app/link-bank/link-bank-client.tsx`
- `config/runtime.exs`
- `docs/environment-variables.md`
- `.env.example`
- `docs/vendor-integrations.md`
- `apps/money_tree/test/money_tree_web/controllers/plaid_controller_test.exs`
- `apps/money_tree/test/money_tree_web/controllers/plaid_webhook_controller_test.exs`
- `apps/money_tree/test/money_tree/plaid/sync_worker_test.exs`
- `apps/next/test/unit/link-bank.test.tsx`
- `apps/next/test/e2e/link-bank.spec.ts`

## Implementation Constraints

- Prefer additive schema changes only if the existing connection fields are insufficient.
- Do not trust the current Plaid/Teller shared sync path as a durable abstraction.
- Do not move secrets into Next.js unless Plaid explicitly requires a browser-safe public value.
- Keep the first release scoped to account linking, synchronization, and webhook-driven refresh.
- Testing is a deliverable, not cleanup work.

## Recommended Product Slice

Implement the standard Plaid Link flow for authenticated users:

1. Phoenix creates a real Plaid link token.
2. Next launches Plaid Link with that token.
3. Phoenix exchanges the returned public token for an access token and item ID.
4. MoneyTree persists the Plaid connection.
5. An initial sync imports accounts and transactions.
6. Plaid webhooks trigger incremental syncs.

This is the smallest coherent slice that proves the integration actually works in production-like
conditions.

## Phase 0: Lock The Plaid Contract

Before writing code, confirm the exact Plaid products and fields the first slice will support.

Recommended decision:

- Plaid environment: `sandbox` in local/dev, configured at runtime for other environments
- Plaid products: start with `transactions`; add `auth` only if the product really needs it
- persistence minimum:
  - encrypted access token
  - Plaid item ID
  - institution metadata returned by Link
  - sync cursors and last-sync state using existing connection fields where possible

Rules:

1. Do not keep the current fake link-token endpoint shape if Plaid’s real response requires a
   different minimum payload.
2. Do not carry over Teller-only fields such as enrollment semantics into Plaid-specific logic.
3. If a missing field forces schema work, add only the smallest reversible migration needed.

## Phase 1: Add Runtime Configuration

Add Plaid configuration in the same style as the Teller and Stripe runtime setup.

Update:

- `config/runtime.exs`
- `docs/environment-variables.md`
- `.env.example`

Expected runtime keys:

- `PLAID_CLIENT_ID`
- `PLAID_SECRET`
- `PLAID_ENV`
- `PLAID_PRODUCTS`
- `PLAID_COUNTRY_CODES`
- `PLAID_REDIRECT_URI` if the chosen Link flow needs it
- `PLAID_WEBHOOK_SECRET` if signature verification remains app-level
- `PLAID_API_HOST` only if a non-default override is genuinely needed

Implementation steps:

1. Store config under `MoneyTree.Plaid`.
2. Fail fast in production if required Plaid values are missing.
3. Parse list-like env vars such as products and country codes into deterministic runtime config.
4. Keep local defaults explicit so sandbox setup is repeatable.

## Phase 2: Build A Real Plaid Client

Replace the placeholder client in `apps/money_tree/lib/money_tree/plaid/client.ex` with a real
HTTP wrapper.

Client responsibilities:

1. `new/1` constructor that reads `MoneyTree.Plaid` config.
2. `create_link_token/1`
3. `exchange_public_token/1`
4. `get_accounts/1` or equivalent item/account fetch
5. `sync_transactions/1` using Plaid’s cursor-based transactions sync if that is the chosen API
6. error normalization into small tagged tuples suitable for controllers and workers
7. optional retry logic for transient HTTP failures

Implementation rules:

1. Follow the style of `MoneyTree.Teller.Client` where that pattern is useful.
2. Keep Req and HTTP details inside the Plaid client module.
3. Normalize Plaid response shapes before returning them to controllers or synchronizers.
4. Preserve request IDs and error codes in error tuples for supportability and test assertions.

## Phase 3: Replace The Fake Link Token Flow

Update `apps/money_tree/lib/money_tree_web/controllers/plaid_controller.ex` so it no longer
generates local random tokens.

Implementation steps:

1. Call `MoneyTree.Plaid.Client.create_link_token/1`.
2. Build request payloads from authenticated user context and request params.
3. Return a stable JSON response that contains the real Plaid `link_token` and expiration.
4. Map Plaid API failures into user-safe HTTP responses.
5. Add rate limiting similar to the Teller connect-token endpoint if Plaid token creation becomes
   a practical abuse vector.

Do not keep fake success behavior after this phase.

## Phase 4: Replace Exchange With Real Persistence

Update the exchange path in `apps/money_tree/lib/money_tree_web/controllers/plaid_controller.ex`
to persist real Plaid credentials and metadata.

Implementation steps:

1. Exchange the public token through the Plaid client.
2. Persist encrypted credentials with the Plaid access token.
3. Persist Plaid item metadata in `provider_metadata`.
4. Merge user-facing metadata carefully instead of overwriting verified fields blindly.
5. Schedule the initial sync only after persistence succeeds.
6. Return a minimal stable response for the frontend.

Check whether existing `institution_connections` fields are sufficient before adding a migration.

Likely first-pass assumption:

- no migration required if access token stays in `encrypted_credentials`, Plaid item details stay
  in `provider_metadata`, and sync state uses the existing cursor fields

If that assumption fails, add one narrow additive migration and update related changesets and tests
in the same slice.

## Phase 5: Build A Plaid-Native Synchronizer

Do not leave Plaid coupled to `MoneyTree.Teller.Synchronizer`.

Replace the implementation in `apps/money_tree/lib/money_tree/plaid/synchronizer.ex` with a
Plaid-specific synchronizer that reuses only persistence helpers that are truly provider-agnostic.

Implementation steps:

1. Read the access token and item metadata from the persisted connection.
2. Fetch accounts using Plaid account APIs or account data returned by the item flow.
3. Sync transactions using Plaid’s real transaction API and real cursor semantics.
4. Persist accounts and transactions through the existing schemas.
5. Update `last_synced_at`, sync cursors, and last-sync errors through `MoneyTree.Institutions`.
6. Preserve deterministic mapping from Plaid payloads into MoneyTree accounts and transactions.

Important design rule:

- if shared account/transaction upsert logic is useful, extract small provider-agnostic helpers
  from the Teller synchronizer rather than routing Plaid back through Teller code paths

## Phase 6: Harden Webhook Handling

The current webhook controller shape is useful, but it needs real Plaid semantics and full tests.

Update:

- `apps/money_tree/lib/money_tree_web/controllers/plaid_webhook_controller.ex`
- `apps/money_tree/lib/money_tree/plaid/webhooks.ex`

Implementation steps:

1. Verify signatures with the actual Plaid signing scheme used by the chosen webhook mode.
2. Confirm replay protection and dedupe semantics against Plaid event payloads.
3. Ignore unsupported events explicitly.
4. Schedule incremental syncs only for supported item/transaction events.
5. Record request IDs or event identifiers needed for operations and support.

If Plaid webhook verification requires signed public keys or JWK rotation rather than a shared
secret, the implementation must reflect that. Do not force Plaid into Teller-style webhook logic
if the vendor protocol differs.

## Phase 7: Finish The Next.js Link Flow

The frontend already contains a Plaid card in `apps/next/app/link-bank/link-bank-client.tsx` and
loads the Plaid script in `apps/next/app/link-bank/page.tsx`.

Implementation steps:

1. Update the Plaid vendor config to match the real backend payload shape.
2. Launch Plaid Link with the real token and callbacks.
3. Send the success payload back to `POST /api/plaid/exchange`.
4. Handle exit and error callbacks explicitly.
5. Show actionable inline errors for configuration failures, exchange failures, and webhook/sync
   follow-up failures where applicable.
6. Keep browser telemetry sanitized so public tokens and access tokens never appear in logs.

Do not push Plaid secrets or server-only config into browser env vars.

## Phase 8: Update CSP And Vendor Docs

Plaid browser surfaces are already partly represented in CSP and docs, but they should be reviewed
against the actual implementation.

Update:

- `apps/money_tree/lib/money_tree_web/plugs/content_security_policy.ex`
- `docs/vendor-integrations.md`

Implementation steps:

1. Keep only the Plaid origins actually required by the shipped flow.
2. Document what each Plaid host is used for.
3. Add any new host only when the backend or widget actually depends on it.

## Phase 9: Add A Plaid Runbook

Create a day-two operations document similar in spirit to `docs/teller_runbook.md`.

Suggested file:

- `docs/plaid_runbook.md`

Include:

1. required secrets and how to rotate them
2. local sandbox setup
3. webhook tunnel setup and replay steps
4. how to retrigger an initial or incremental sync
5. what logs, request IDs, and error codes to inspect first

## Test Strategy

Testing must be implemented alongside each phase. The Plaid work is not complete without these
layers.

### Backend Unit Tests

Add or expand tests for:

- `MoneyTree.Plaid.Client`
  - request payload construction
  - response normalization
  - transient retry handling
  - 4xx and 5xx error mapping
- `MoneyTree.Plaid.Synchronizer`
  - initial sync
  - incremental sync
  - cursor advancement
  - duplicate transaction handling
  - missing or malformed Plaid payload fields
- webhook helpers
  - signature verification
  - replay protection
  - unsupported event filtering

### Phoenix Controller Tests

Strengthen:

- `apps/money_tree/test/money_tree_web/controllers/plaid_controller_test.exs`
- `apps/money_tree/test/money_tree_web/controllers/plaid_webhook_controller_test.exs`

Add cases for:

- missing session
- missing required params
- Plaid client 4xx failure
- Plaid client 5xx failure
- successful link token creation using a real client stub contract
- successful public token exchange and connection persistence
- sync scheduling after exchange
- invalid webhook signature
- duplicate webhook nonce or event
- unsupported webhook event
- webhook-triggered incremental sync

### Persistence And Worker Tests

Expand:

- `apps/money_tree/test/money_tree/plaid/sync_worker_test.exs`

Add cases for:

- account upsert updates existing balances deterministically
- transaction upsert is idempotent
- sync error state is written when Plaid fails
- revoked connections do not keep syncing
- stale cursor recovery behavior

### Integration Tests

Add adapter-backed tests that exercise the real Plaid client module against recorded or local mock
HTTP responses.

Recommended approach:

1. use Req adapter injection or a local HTTP stub server for deterministic responses
2. assert real request paths, payloads, and headers
3. avoid hitting live Plaid in CI

### Frontend Unit And E2E Tests

Strengthen:

- `apps/next/test/unit/link-bank.test.tsx`
- `apps/next/test/e2e/link-bank.spec.ts`

Add cases for:

- successful Plaid token fetch
- successful Plaid Link launch
- exchange request after widget success
- user exit without linking
- inline error on token creation failure
- inline error on exchange failure
- telemetry sanitization for public tokens and item IDs

### Manual Verification

Before marking the integration complete, verify in a live local environment:

1. start the app through `./scripts/dev.sh`
2. confirm migrations are applied if schema changes were required
3. link a sandbox institution through the real Plaid UI
4. verify the connection row persisted correctly
5. verify accounts and transactions imported correctly
6. replay a Plaid webhook and confirm incremental sync behavior
7. verify errors are understandable when Plaid credentials are intentionally broken

## Delivery Order

Use this migration order to keep the rollout small and testable:

1. runtime config and docs
2. Plaid client unit tests
3. real Plaid client implementation
4. controller link-token and exchange updates
5. Plaid-native synchronizer
6. webhook hardening
7. frontend flow updates
8. runbook and final validation

Each phase should land with its matching tests. Do not defer the critical sync and webhook tests to
the end.

## Completion Criteria

The Plaid integration is complete only when all of the following are true:

1. Plaid runtime variables are documented and loaded through `config/runtime.exs`.
2. `POST /api/plaid/link_token` returns a real Plaid link token.
3. `POST /api/plaid/exchange` persists a usable Plaid connection and schedules sync.
4. Plaid account and transaction sync runs through Plaid-specific code, not Teller-specific code.
5. Plaid webhooks verify correctly and trigger incremental syncs idempotently.
6. frontend unit tests and e2e coverage cover the Plaid happy path and key failures.
7. backend tests cover client, controller, worker, and webhook behavior.
8. local manual verification succeeds against the migrated dev database and real Plaid sandbox
   credentials.

If any of these are missing, the integration should still be treated as incomplete.
