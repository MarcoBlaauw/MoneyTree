# Financial Evaluation Implementation Plan

## Status

Active as of 2026-05-22.

This plan has been reset to fit the current MoneyTree codebase. Earlier versions assumed that
mortgages, loan documents, lender quotes, and refinance workflows still needed new evaluation-owned
schemas. That is no longer true. Loan Center now owns those records.

## Does This Plan Still Add Value?

Yes, with a narrower purpose.

It should not create a parallel financial profile system. It should add value by turning existing
MoneyTree data into explainable status, review prompts, and evaluation workflows across domains.

Keep this plan if the goal is:

- a dedicated `/evaluations` surface that summarizes what needs attention
- deterministic stale-data, missing-data, expiring, and opportunity checks
- insurance, rent, and vehicle evaluation records that are not already modeled elsewhere
- contract-backed APIs that Next can consume without ad hoc response shapes
- dashboard and notification integration for important evaluation state changes

Do not use this plan for:

- duplicating `MoneyTree.Mortgages`
- duplicating `MoneyTree.Loans`
- replacing Loan Center refinance scenarios, lender quotes, rate observations, document extraction, fee review, or alert rules
- letting AI calculate financial recommendations
- building a generic document import framework before the existing Loan Center document review flow is exhausted

## End Goal

MoneyTree should provide an explainable financial evaluation layer over reviewed facts.

The finished state is:

- Existing Loan Center facts feed mortgage and loan evaluation status.
- New evaluation-specific schemas exist only where no current domain owns the data, such as insurance policies, rent profiles, and vehicle-specific policy or lease facts.
- Deterministic Elixir code computes status, warnings, missing fields, stale fields, and opportunity flags.
- AI may extract or explain, but never calculates authoritative amounts, eligibility, or recommendations.
- The same backend evaluation status feeds Next pages, Phoenix LiveViews, contracts, notifications, and dashboard cards.
- Users can act on evaluation results through review, update, and alert flows.

## Current Codebase Baseline

Use these existing domains as the source of truth:

- `MoneyTree.Mortgages`
  - persisted mortgage records and escrow profiles
  - fields include balance, rate, payment, home value, status, source, and `last_reviewed_at`
- `MoneyTree.Loans`
  - generic loans
  - refinance scenarios
  - refinance analysis results
  - lender quotes
  - lender quote fee review
  - loan documents and document extraction candidates
  - rate sources and rate observations
  - alert rules
- `MoneyTree.Obligations`
  - recurring payment obligations, including subscription/recurring-payment metadata
- `MoneyTree.Recurring`
  - deterministic recurring transaction detection
- `MoneyTree.Notifications`
  - durable notification events and delivery attempts
- `MoneyTree.Assets`
  - tangible property and vehicle anchors
- `apps/contracts`
  - OpenAPI source and generated REST types
- `apps/next/app`
  - server-rendered pages, `fetchWithSession()`, and route-specific `app/lib/*` normalizers

Already implemented for this plan:

- `MoneyTree.Evaluations.status_summary/2`
- authenticated `GET /api/evaluations/status-summary`
- OpenAPI contract and generated REST type updates
- deterministic initial summary over active mortgages, generic loans, pending loan document extractions, and lender quote expirations
- Next `/evaluations` index page backed by the status summary API
- status summary expansion for failed/stuck loan documents, lender quote fee review lines, and open recurring anomalies
- Phoenix dashboard evaluation status entry point linked to `/app/react/evaluations`
- durable financial evaluation notification events synced through `MoneyTree.Notifications.pending/2`

## Architecture Rules

### Context Ownership

Use existing contexts first.

- Loan and mortgage facts stay in `MoneyTree.Loans` and `MoneyTree.Mortgages`.
- Recurring bill semantics stay in `MoneyTree.Obligations`.
- Tangible asset anchors stay in `MoneyTree.Assets`.
- Durable surfacing and delivery stay in `MoneyTree.Notifications`.
- Cross-domain status aggregation and evaluation result shaping lives in `MoneyTree.Evaluations`.

Create new schemas only when the data has no current owner.

Likely new evaluation-owned records:

- insurance policies
- rent profiles
- benchmark snapshots not already covered by Loan Center rate observations
- persisted cross-domain evaluation result snapshots, if transient summaries become insufficient

Likely not needed in this plan:

- mortgage profiles
- generic loan profiles
- mortgage document/import tables
- lender quote tables
- refinance scenario tables

### Financial Logic

All calculations must be deterministic.

AI is allowed for:

- document extraction drafts
- classification
- summarizing deterministic results
- plain-language explanation

AI is not allowed for:

- calculating budget, refinance, payoff, premium, or payment amounts
- deciding eligibility
- setting thresholds
- persisting extracted facts without user confirmation

### Contract Discipline

Every Phoenix JSON endpoint consumed by Next must be added to `apps/contracts/specs/openapi.yaml`.

After editing the contract:

```sh
pnpm --dir apps/contracts run generate:openapi
pnpm --dir apps/contracts run verify:openapi
```

Do not edit generated contract files by hand.

### Migration Discipline

Any schema-affecting task must apply migrations to the active development database before completion.

Use the repository development flow when the app must run locally:

```sh
./scripts/dev.sh
```

For narrower backend work, `mix ecto.migrate` from the umbrella is acceptable when no server startup is needed.

## Evaluation Status Model

Use this status vocabulary consistently:

- `healthy`
- `incomplete`
- `needs_review`
- `stale`
- `expiring`
- `opportunity`

The status summary API currently counts:

- `incomplete`
- `needs_review`
- `stale`
- `expiring`
- `opportunity`

Keep `healthy` mostly as a UI/detail status. The summary count can omit healthy items unless a page needs total coverage.

Each status item should include:

- stable id
- domain
- resource id
- status
- severity
- title
- summary
- deterministic reasons
- source, usually `deterministic`
- target path

## Current Implementation Slice

Implemented files:

- `apps/money_tree/lib/money_tree/evaluations.ex`
- `apps/money_tree/lib/money_tree_web/controllers/evaluation_controller.ex`
- `apps/money_tree/lib/money_tree_web/router.ex`
- `apps/contracts/specs/openapi.yaml`
- `apps/contracts/src/generated/rest.ts`
- `apps/money_tree/test/money_tree/evaluations_test.exs`
- `apps/money_tree/test/money_tree_web/controllers/evaluation_controller_test.exs`

Current deterministic checks:

- active mortgage missing home value estimate -> `incomplete`
- active mortgage or generic loan with no `last_reviewed_at` -> `needs_review`
- active mortgage or generic loan with review older than default stale window -> `stale`
- pending loan document extraction -> `needs_review`
- active lender quote expiring inside the default window or already expired -> `expiring`

## Implementation Roadmap

### Task 1: Next Evaluations Index

Status:

- Completed on 2026-05-22.

Goal:

- Make `/evaluations` show the current status summary using the implemented API.

Files likely affected:

- `apps/next/app/evaluations/page.tsx`
- `apps/next/app/evaluations/render-evaluations-page.tsx`
- `apps/next/app/lib/evaluations.ts`
- `apps/next/test/unit/*`

Implementation:

- fetch `GET /api/evaluations/status-summary` with `fetchWithSession()`
- type response using generated REST types where practical
- show count tiles for incomplete, needs review, stale, expiring, and opportunity
- show the highest-severity current items with links to `target_path`
- handle unauthenticated or failed fetch as an empty signed-out state

Validation:

- `pnpm --dir apps/next test`
- `pnpm --dir apps/contracts run verify:openapi`

Implemented files:

- `apps/next/app/evaluations/page.tsx`
- `apps/next/app/evaluations/render-evaluations-page.tsx`
- `apps/next/app/lib/evaluations.ts`
- `apps/next/test/unit/evaluations-page.test.tsx`

### Task 2: Status Summary Expansion

Status:

- Completed on 2026-05-22 for the first existing-data expansion.

Goal:

- Make `MoneyTree.Evaluations.status_summary/2` cover more existing Loan Center and obligation signals before adding new schemas.

Files likely affected:

- `apps/money_tree/lib/money_tree/evaluations.ex`
- `apps/money_tree/test/money_tree/evaluations_test.exs`

Candidate checks:

- failed loan documents -> `needs_review`
- queued/extracting loan documents older than the default stuck-processing window -> `needs_review`
- active lender quote fee lines marked `requires_review` -> `needs_review`
- open recurring-series anomalies -> `needs_review`

Still reasonable future checks:

- loan alert rules with unresolved triggered states, if represented in current data
- lender quotes missing required fee review detail when that can be queried without running a heavy fee analysis per quote
- obligations with subscription/recurring metadata and stale review dates if review timestamps are added to obligations

Validation:

- targeted context tests
- keep user scoping explicit

### Task 3: Dashboard And LiveView Entry Points

Status:

- Completed on 2026-05-22 for the first dashboard entry point.

Goal:

- Surface compact evaluation status in the existing app without turning dashboard pages into full management workflows.

Files likely affected:

- dashboard LiveView files
- `apps/money_tree/lib/money_tree_web/live/loans_live/index.ex`
- maybe `apps/money_tree/lib/money_tree_web/live/obligations_live/index.ex`

Implementation:

- add compact count cards or badges
- deep-link to `/app/react/evaluations` or existing Loan Center targets
- do not duplicate evaluation calculations in LiveView

Implemented:

- Dashboard KPI count for evaluation items
- Dashboard right-rail evaluation status panel
- Top current evaluation items rendered from `MoneyTree.Evaluations.status_summary/2`
- Link to the Next evaluations index

Validation:

- targeted LiveView tests

### Task 4: Notification Integration

Status:

- Completed on 2026-05-22 for current evaluation summary items.

Goal:

- Emit durable notification events only for important evaluation state changes.

Files likely affected:

- `apps/money_tree/lib/money_tree/notifications.ex`
- `apps/money_tree/lib/money_tree/notifications/event.ex`
- `apps/money_tree/lib/money_tree/evaluations.ex`
- migration only if event validation/schema requires it

Implementation:

- define event kinds for stale data, expiring quotes, pending review, and future insurance/rent renewal alerts
- add dedupe rules so daily checks do not spam events
- keep notification generation separate from summary calculation

Implemented:

- `financial_evaluation` notification event kind
- evaluation statuses accepted by durable notification events
- `MoneyTree.Notifications.sync_evaluation_events/2`
- dedupe key per user/evaluation item/status
- `MoneyTree.Notifications.pending/2` syncs current evaluation events before loading dashboard events

Validation:

- notification tests
- evaluation-triggered event tests
- apply migration if schema changes are added

### Task 5: Insurance Policy Domain

Goal:

- Add the first new evaluation-owned domain that is not already covered by Loan Center.

Files likely affected:

- migration under `apps/money_tree/priv/repo/migrations`
- `apps/money_tree/lib/money_tree/evaluations/insurance_policy.ex`
- `apps/money_tree/lib/money_tree/evaluations.ex`
- controller and route if API-backed
- contract updates if consumed by Next

Minimal schema:

- user id
- optional asset id
- optional obligation id
- policy type
- carrier name
- policy number last4
- coverage start/end
- renewal date
- premium amount and period
- deductible amount
- selected coverage fields as needed
- source
- verification state
- `last_reviewed_at`

Deterministic checks:

- renewal approaching -> `expiring`
- missing renewal date or premium -> `incomplete`
- never reviewed -> `needs_review`
- old review -> `stale`

Validation:

- migration applied to dev database
- schema/context tests
- controller tests if API is added
- contract verify if API is added

### Task 6: Rent Profile Domain

Goal:

- Support renters without forcing mortgage ownership.

Files likely affected:

- migration
- `apps/money_tree/lib/money_tree/evaluations/rent_profile.ex`
- `apps/money_tree/lib/money_tree/evaluations.ex`

Minimal schema:

- user id
- optional obligation id
- monthly rent
- lease start/end
- renewal notice days
- landlord or property label
- source
- verification state
- `last_reviewed_at`

Deterministic checks:

- lease end approaching -> `expiring`
- missing lease end or rent amount -> `incomplete`
- never reviewed -> `needs_review`
- old review -> `stale`

Validation:

- migration applied to dev database
- schema/context tests

### Task 7: Vehicle Evaluation Refinement

Goal:

- Reuse generic loans and assets first. Add new schema only for vehicle-specific facts that generic loans cannot store.

Files likely affected:

- `MoneyTree.Loans`
- `MoneyTree.Assets`
- `MoneyTree.Evaluations`
- optional new schema if needed

Prefer existing data for:

- auto loan balance
- auto loan rate
- remaining term
- monthly payment
- collateral description

Add only if needed:

- odometer
- annual mileage limit
- residual value
- lease maturity date
- excess mileage fee

Validation:

- targeted context tests
- migration applied if a schema is added

### Task 8: Persisted Evaluation Results

Goal:

- Persist evaluation outputs only when transient summaries are not enough for history, alert dedupe, or audit.

Files likely affected:

- migration
- `apps/money_tree/lib/money_tree/evaluations/result.ex`
- `apps/money_tree/lib/money_tree/evaluations.ex`

Suggested fields:

- user id
- subject type
- subject id
- evaluation type
- status
- severity
- summary
- missing fields
- stale fields
- computed facts
- recommendations
- computed at
- expires at

Rules:

- persisted results must be deterministic snapshots
- do not store LLM-only recommendation outputs as authoritative results

Validation:

- migration applied to dev database
- context tests

### Task 9: Benchmark Integration

Goal:

- Use existing Loan Center rate observations where possible before creating new benchmark snapshot tables.

Files to inspect first:

- `MoneyTree.Loans.RateObservation`
- `MoneyTree.Loans.RateSource`
- `MoneyTree.Loans.RateProviders.*`

Implementation options:

- extend existing Loan Center rate observation selection helpers
- add evaluation-facing query helpers over existing rate observations
- create a generic benchmark snapshot table only if non-loan benchmarks require it

Validation:

- deterministic freshness-selection tests

### Task 10: Document Extraction Expansion

Goal:

- Avoid a generic import framework until there is a second real document workflow.

Current baseline:

- Loan Center already has loan document metadata, extraction candidates, review, confirm, apply, quote creation, and scenario creation flows.

Next steps:

- improve the existing loan document flow if mortgage/quote extraction is the only need
- create a new import abstraction only when insurance, rent, or vehicle documents require shared behavior

Validation:

- keep review-first behavior
- no extracted data becomes canonical without explicit user confirmation

## Recommended Execution Order

1. Next evaluations index
2. Status summary expansion over existing data
3. Dashboard and LiveView entry points
4. Notification integration
5. Insurance policy domain
6. Rent profile domain
7. Vehicle evaluation refinement
8. Persisted evaluation results
9. Benchmark integration
10. Document extraction expansion

This order keeps the early work useful and low-risk because it starts with existing records and only
adds schemas once there is no existing owner for the data.

## Validation Checklist

For backend-only evaluation changes:

```sh
mix test apps/money_tree/test/money_tree/evaluations_test.exs
```

For controller/API changes:

```sh
mix test apps/money_tree/test/money_tree_web/controllers/evaluation_controller_test.exs
pnpm --dir apps/contracts run verify:openapi
```

For Next evaluation pages:

```sh
pnpm --dir apps/next test
pnpm --dir apps/next lint
```

For schema changes:

```sh
mix ecto.migrate
```

Then run the narrow context/controller tests that cover the migrated schema.

## Open Questions

- Should `/evaluations` live as a Next page only, or should Phoenix `/app/dashboard` link to it with a compact status card?
- Should healthy evaluation coverage be counted explicitly, or should the index focus only on actionable statuses?
- Should insurance policies be managed under `/evaluations/insurance`, `/app/obligations`, or both?
- Should vehicle lease facts extend `MoneyTree.Loans.Loan`, `MoneyTree.Assets.Asset`, or a small evaluation-owned vehicle fact table?
