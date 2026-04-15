# Stripe Integration Implementation Plan

## Purpose

This document is the first implementation plan for Stripe in `MoneyTree`.

The current repository has:

- no Stripe backend modules
- no Stripe environment variables
- no Stripe webhook handlers
- no Stripe-specific CSP entries
- no Stripe references in the docs today

The goal of this plan is to add Stripe in a way that matches the existing repo style:

- Phoenix owns server-side secrets, webhooks, and persistence
- Next.js owns the user-facing button / modal / redirect flow
- runtime env vars and docs live alongside the existing Teller and Persona conventions

## Current Surfaces To Extend

These are the files and patterns this work should follow, depending on the chosen Stripe mode:

- `apps/next/app/link-bank/link-bank-client.tsx`
- `apps/next/app/link-bank/page.tsx`
- `apps/next/app/control-panel/*`
- `apps/money_tree/lib/money_tree_web/router.ex`
- `apps/money_tree/lib/money_tree_web/plugs/content_security_policy.ex`
- `apps/money_tree/lib/money_tree_web/controllers/*`
- `config/runtime.exs`
- `docs/environment-variables.md`
- `docs/vendor-integrations.md`

## Open Product Decision

Stripe has multiple product modes. Decide this before coding anything:

1. Stripe-hosted billing flow
   - Checkout
   - Billing portal
   - subscription management

2. Stripe connected-account flow
   - account onboarding
   - account linking
   - capability/status sync

3. Stripe data-sync flow
   - ingest charges, payouts, balance transactions, or disputes into `MoneyTree`

If the product decision is not finalized, stop after Phase 0 and do not add code yet.

Current implementation choice:

- mode: Stripe connected-account flow
- first slice: authenticated Phoenix endpoint that creates a Stripe Connect OAuth session URL
- UI surface: `link-bank` (as a connector-style launch point)

## UI Ownership Rule

Do not assume Stripe belongs in `link-bank`.

Use this mapping:

- `link-bank` only if Stripe is being treated like another external financial account connector
- `control-panel` or `settings` if Stripe is a billing, checkout, or portal flow
- a dedicated new page only if the Stripe flow is large enough that it does not fit an existing product surface

For a first implementation, reuse an existing product surface whenever possible.

## Recommended First Slice

Start with one narrow Stripe flow, not every Stripe product.

Recommended approach:

- implement one Stripe-hosted session endpoint
- add one frontend button/card for that session in the correct product surface
- add one webhook handler only if the chosen Stripe flow needs it

Do not try to support Checkout, Billing Portal, Connect, and data sync in the same first pass.

## Phase 0: Confirm The Flow

1. Write down the exact user action.
   - Example: “user clicks Stripe in the vendor list and opens a Stripe-hosted page”
   - Example: “user links their Stripe account so MoneyTree can sync Stripe activity”

2. Decide the minimum state we need to persist.
   - Example: Stripe customer ID
   - Example: Stripe connected account ID
   - Example: Stripe session ID
   - Example: Stripe webhook event ID

3. Decide whether the flow is read-only or stateful.
   - Read-only flows need fewer tables and fewer webhooks.
   - Stateful flows usually need persistence and webhook reconciliation.

4. Decide the public Stripe URLs needed for the browser.
   - Hosted checkout or portal
   - Embedded widget
   - Redirect-based onboarding

5. Decide the UI surface before writing any frontend code.
   - `link-bank` only for account-connector behavior
   - `control-panel` or `settings` for billing or portal behavior
   - new route only if existing surfaces are clearly wrong

## Phase 1: Add Runtime Configuration

Add Stripe env vars in the same style as Teller and Persona.

Update:

- `config/runtime.exs`
- `docs/environment-variables.md`
- `.env.example`

Suggested env vars:

- `STRIPE_SECRET_KEY`
- `STRIPE_API_VERSION`

Mode-specific vars:

- Hosted checkout or billing portal:
  - `STRIPE_PRICE_ID`
  - `STRIPE_SUCCESS_URL`
  - `STRIPE_CANCEL_URL`
- `STRIPE_CONNECT_CLIENT_ID`
- `STRIPE_CONNECT_REDIRECT_URI`
- Browser-initiated Stripe.js flows only:
  - `STRIPE_PUBLISHABLE_KEY`
- Webhook-enabled flows only:
  - `STRIPE_WEBHOOK_SECRET`

Do not add all Stripe env vars by default. Only add the variables required by the chosen first slice.

Implementation steps:

1. Add the env vars to `docs/environment-variables.md`.
2. Add the same keys to `.env.example`.
3. Read them in `config/runtime.exs`.
4. Store them in a dedicated config namespace, for example `MoneyTree.Stripe`.
5. Fail fast in production if the required vars for the chosen flow are missing.

## Phase 2: Add A Stripe Client Module

Create a backend wrapper instead of calling Stripe directly from controllers.

Suggested file:

- `apps/money_tree/lib/money_tree/stripe/client.ex`

Responsibilities:

1. Hold a small `new/1` constructor that reads config.
2. Create the specific Stripe request for the chosen flow.
3. Convert Stripe errors into small tagged tuples.
4. Keep HTTP details out of controllers.

Implementation rules:

- keep request creation in one module
- keep secrets on the server only
- do not put Stripe keys in Next.js environment unless the browser truly needs the publishable key

If the repo already has a good client pattern, follow `MoneyTree.Teller.Client`.

## Phase 3: Add Phoenix Session Endpoint

Add one authenticated controller for the browser-initiated Stripe flow.

Suggested file:

- `apps/money_tree/lib/money_tree_web/controllers/stripe_controller.ex`

Suggested routes:

- `POST /api/stripe/session`

Implementation steps:

1. Add the route to `apps/money_tree/lib/money_tree_web/router.ex`.
2. Keep the session endpoint behind `:api_auth`.
3. Return JSON with a small stable shape.
4. Translate Stripe errors into user-safe messages.

Do not add webhook handling to this controller.

## Phase 4: Handle Webhooks

Most Stripe flows need webhook reconciliation.

Suggested file:

- `apps/money_tree/lib/money_tree_web/controllers/stripe_webhook_controller.ex`

Suggested route:

- `POST /api/stripe/webhook`

Implementation steps:

1. Verify webhook signatures with `STRIPE_WEBHOOK_SECRET`.
2. Ignore events we do not yet care about.
3. Persist the event ID or dedupe key before doing side effects.
4. Make webhook handling idempotent.
5. Store only the minimum Stripe IDs needed for future lookup.

If the chosen flow does not need webhooks yet, keep this phase out of the first release.

## Phase 5: Wire The Next.js UI

Wire Stripe into the correct existing product surface instead of defaulting to `link-bank`.

Likely touchpoints:

- `apps/next/app/link-bank/link-bank-client.tsx` for account-connector behavior only
- `apps/next/app/link-bank/page.tsx` for account-connector behavior only
- `apps/next/app/control-panel/*` for billing or portal behavior
- existing Phoenix settings routes if the first slice belongs under settings

Implementation steps:

1. Add one Stripe action in the chosen surface.
2. If the chosen surface is `link-bank`, add a `Stripe` vendor entry matching the existing vendor pattern.
3. Call the new Phoenix endpoint from the client.
4. Launch the Stripe-hosted flow or redirect as required.
5. Show a clean inline error if Stripe returns a failure.
6. Log support identifiers if the UI already has an event log for that surface.

Keep the frontend simple:

- one action
- one loading state
- one error state
- one success state

## Phase 6: Update CSP And Vendor Docs

Stripe adds browser and iframe origins that must be allowed explicitly.

Update:

- `apps/money_tree/lib/money_tree_web/plugs/content_security_policy.ex`
- `docs/vendor-integrations.md`

Likely origins, depending on flow:

- Hosted checkout:
  - `https://checkout.stripe.com`
- Billing portal:
  - `https://billing.stripe.com`
- Embedded Stripe.js:
  - `https://js.stripe.com`
  - `https://m.stripe.network`

Only add the origins that the chosen flow actually needs.

## Phase 7: Decide Where Stripe State Lives

Choose the smallest persistence model that supports the flow.

Options:

1. Reuse an existing metadata field if Stripe only needs a small amount of state.
2. Add a dedicated Stripe table if the flow needs durable syncing.
3. Add a new `provider`-style record if Stripe behaves like another external connector.

Recommended first-slice rule:

- if the flow only needs a transient hosted session, do not add persistence yet
- if the flow needs webhook reconciliation, add a dedicated webhook-event table for idempotency instead of hiding event IDs in unrelated metadata
- if the flow behaves like an external account connector, model it alongside provider/connection state rather than under billing metadata

Implementation rule:

- do not create a new table until the exact stored identifiers are known
- do not over-model Stripe upfront

If webhook persistence is needed, add these surfaces explicitly:

- migration under `apps/money_tree/priv/repo/migrations/*`
- schema module such as `apps/money_tree/lib/money_tree/stripe/webhook_event.ex`
- context helper in `apps/money_tree/lib/money_tree/stripe.ex` or similar

The minimum webhook event record should hold:

- Stripe event ID
- event type
- processed-at timestamp
- status
- minimal metadata needed for debugging

## Phase 8: Tests

Add tests as you go, not at the end.

Phoenix tests:

- controller success path
- controller error path
- webhook signature failure
- webhook idempotency
- route test

Next tests:

- button renders
- click triggers fetch
- loading state appears
- error state surfaces cleanly
- non-JSON failure handling stays intact

If the flow opens a hosted Stripe page, add a test that confirms the frontend only sends the minimum fields required.

## Phase 9: Validation Order

Run the narrowest checks first:

1. Phoenix controller test
2. webhook test if webhooks are part of the first slice
3. targeted Next unit test
4. targeted route test
5. full `pnpm --dir apps/next test`
6. relevant `mix test` slice

## Definition Of Done

Stripe is ready for a first release when:

- the intended Stripe flow is decided
- runtime env vars are documented
- the Phoenix client and controller exist
- the Next button or card works
- webhook handling is idempotent if needed
- CSP allows only the required Stripe origins
- targeted tests pass

## Suggested Next Work Order

1. Decide the Stripe mode.
2. Decide the UI surface for that mode.
3. Add env vars and runtime config for that mode only.
4. Add the backend Stripe client.
5. Add the Phoenix session endpoint.
6. Add webhook handling if the chosen flow needs it.
7. Add persistence only if the flow actually needs it.
8. Wire the Next UI button or card in the chosen surface.
9. Update CSP and docs.
10. Add tests and run the narrow validation slice.

## File-By-File Order

Use this sequence if you want the smallest safe implementation path.

1. `docs/environment-variables.md`
   - Add only the Stripe env vars required by the selected flow so the runtime shape is explicit before code is written.
2. `.env.example`
   - Mirror the same Stripe keys for local setup.
3. `config/runtime.exs`
   - Read Stripe env vars into `MoneyTree.Stripe` and fail fast in production when required values are missing.
4. `docs/vendor-integrations.md`
   - Reserve the Stripe origins the chosen flow needs, and only those origins.
5. `apps/money_tree/lib/money_tree/stripe/client.ex`
   - Create the server-side Stripe wrapper and keep API calls out of controllers.
6. `apps/money_tree/lib/money_tree_web/controllers/stripe_controller.ex`
   - Add the authenticated Stripe session endpoint and normalize errors.
7. `apps/money_tree/lib/money_tree_web/controllers/stripe_webhook_controller.ex`
   - Add only if the chosen Stripe flow needs webhook reconciliation.
8. `apps/money_tree/lib/money_tree_web/router.ex`
   - Wire the new controller routes into the Phoenix API.
9. `apps/money_tree/priv/repo/migrations/*`
   - Add this only if the chosen flow needs persistence or webhook idempotency.
10. `apps/money_tree/lib/money_tree/stripe/webhook_event.ex`
   - Add this only if the chosen flow needs dedicated webhook-event persistence.
11. `apps/money_tree/lib/money_tree_web/plugs/content_security_policy.ex`
   - Add the minimum Stripe CSP origins after the browser flow is known.
12. One UI surface, not all of them:
   - `apps/next/app/link-bank/link-bank-client.tsx` for connector behavior
   - `apps/next/app/link-bank/page.tsx` for connector behavior
   - `apps/next/app/control-panel/*` for billing or portal behavior
13. `apps/money_tree/test/money_tree_web/controllers/stripe_controller_test.exs`
   - Cover controller success and error behavior.
14. `apps/money_tree/test/money_tree_web/controllers/stripe_webhook_controller_test.exs`
   - Cover webhook signature and idempotency behavior if webhooks are used.
15. One UI test surface, not all of them:
   - `apps/next/test/unit/link-bank.test.tsx` for connector behavior
   - or the relevant control-panel/unit test file for billing or portal behavior

Do not put Stripe into `link-bank` unless the product decision explicitly says Stripe is acting as an external account connector.

## Minimal Driver For A Basic Coder

If you want the simplest execution path, give the coder these rules:

1. Do one file family at a time.
2. Choose the product surface before editing any frontend code.
3. Do not add Stripe UI before the backend endpoint exists.
4. Do not add webhook code unless the chosen Stripe flow needs it.
5. Do not add extra env vars beyond the selected flow.
6. Do not invent persistence. If webhook idempotency is required, add a dedicated persistence surface for it.
7. Add tests in the same pass as the feature, not later.
8. Keep the first implementation narrow enough to ship behind a single button or card.
