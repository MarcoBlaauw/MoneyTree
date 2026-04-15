# Mortgage Center implementation plan

## Purpose and scope

Add a mortgage-focused workspace to MoneyTree that lets a user:

- store one or more mortgages
- view mortgage details and escrow together
- analyze deterministic refinance scenarios later
- connect mortgage records to existing obligations and notification systems later
- import mortgage documents later through a review-first workflow

This plan is execution-oriented and repo-anchored. It keeps the existing architectural direction from
`docs/mortgage-refinance-implementation-plan.md` while applying the Mortgage Center framing and Phase 1
scope refinements from `docs/mortgage-center-addendum.md`.

## Product framing

### Initial product shell

Start with a **Mortgage Center**.

Mortgage Center is the initial home-finance shell for:

- mortgage tracking
- escrow visibility
- refinance analysis
- statements and imports
- alerts and rate watch

### Future relationship to Home Owner Center

Do not build a broad Home Owner Center now.

If MoneyTree later expands into non-mortgage homeowner workflows such as insurance, property taxes,
HOA, maintenance, or home documents, Mortgage Center can become a subsection of a future Home Owner
Center. That future possibility should shape naming and IA, but it should not broaden current scope.

## Repo fit

Use the existing MoneyTree boundaries already established in the repo:

- Phoenix backend contexts in `apps/money_tree/lib/money_tree`
- Phoenix JSON controllers and router in `apps/money_tree/lib/money_tree_web`
- additive Ecto migrations in `apps/money_tree/priv/repo/migrations`
- Next.js app UI in `apps/next/app`
- API contracts in `apps/contracts`
- notification events and delivery via existing notifications modules
- obligation linkage through the existing obligations domain
- background jobs through Oban

Keep financial calculations deterministic and implemented in Elixir code. Keep document imports
review-first, confirmation-based, and separate from canonical persistence.

## Current repo surfaces to extend

- `apps/money_tree/lib/money_tree`
- `apps/money_tree/lib/money_tree_web/controllers`
- `apps/money_tree/lib/money_tree_web/router.ex`
- `apps/money_tree/priv/repo/migrations`
- `apps/next/app`
- `apps/contracts`
- existing obligations and notifications modules
- existing Oban configuration and worker patterns

## Naming and IA

Use **Mortgage Center** consistently in docs, contracts, backend naming, and frontend page labels.

Recommended IA now:

- Mortgage Center
- Overview
- Current mortgage
- Escrow
- Refinance analysis
- Statements & imports
- Alerts
- Rate watch

Keep the route family under `/app/react/mortgages` for now, but treat those routes as Mortgage Center
surfaces in product language.

## Route structure

### Next.js routes

- `/app/react/mortgages` -> Mortgage Center overview
- `/app/react/mortgages/[mortgageId]` -> Mortgage Center detail
- `/app/react/mortgages/[mortgageId]/refinance` -> Mortgage Center refinance workspace
- `/app/react/mortgages/[mortgageId]/imports` -> Mortgage Center statements/imports workspace
- `/app/react/mortgages/[mortgageId]/alerts` -> Mortgage Center alerts workspace

### Phoenix API routes

Add authenticated JSON APIs under the existing `/api` pattern in [router.ex](/home/webmeester/MoneyTree/apps/money_tree/lib/money_tree_web/router.ex).

Recommended endpoint family:

- `GET /api/mortgages`
- `POST /api/mortgages`
- `GET /api/mortgages/:id`
- `PUT /api/mortgages/:id`
- `DELETE /api/mortgages/:id`
- `GET /api/mortgages/:id/refinance_scenarios`
- `POST /api/mortgages/:id/refinance_scenarios`
- `GET /api/refinance_scenarios/:id`
- `PUT /api/refinance_scenarios/:id`
- `DELETE /api/refinance_scenarios/:id`
- `POST /api/mortgages/:id/analyze`
- `GET /api/mortgages/:id/rate_snapshots`
- `POST /api/mortgage_rates/import`
- `GET /api/mortgages/:id/alerts`
- `POST /api/mortgages/:id/alerts`
- `PUT /api/mortgage_alerts/:id`
- `DELETE /api/mortgage_alerts/:id`
- `GET /api/mortgages/:id/import_reviews`
- `POST /api/mortgages/:id/import_reviews`
- `POST /api/mortgage_import_reviews/:id/confirm`
- `POST /api/mortgage_import_reviews/:id/reject`

Phase 1 only needs the mortgage CRUD subset.

## Backend module plan

Create a new context family under `MoneyTree.Mortgages`.

Recommended modules:

- `MoneyTree.Mortgages`
- `MoneyTree.Mortgages.Mortgage`
- `MoneyTree.Mortgages.EscrowProfile`
- `MoneyTree.Mortgages.RefinanceScenario`
- `MoneyTree.Mortgages.RefinanceFee`
- `MoneyTree.Mortgages.RateSnapshot`
- `MoneyTree.Mortgages.RateProvider`
- `MoneyTree.Mortgages.Analysis`
- `MoneyTree.Mortgages.AnalysisEngine`
- `MoneyTree.Mortgages.ImportJob`
- `MoneyTree.Mortgages.ImportReview`
- `MoneyTree.Mortgages.AlertRule`

Recommended web layer additions:

- `MoneyTreeWeb.MortgageController`
- `MoneyTreeWeb.RefinanceScenarioController`
- `MoneyTreeWeb.MortgageAnalysisController`
- `MoneyTreeWeb.MortgageAlertController`
- `MoneyTreeWeb.MortgageImportReviewController`
- `MoneyTreeWeb.MortgageRateController`

Keep pure calculation logic in service modules, not controllers and not frontend code.

## Schema plan

All schema changes should be additive. Reuse existing obligations and notifications systems rather
than creating parallel systems.

### Core Phase 1 tables

#### `mortgages`

Primary user mortgage record.

Suggested fields:

- `user_id`
- `nickname`
- `property_name`
- `street_line_1`
- `street_line_2`
- `city`
- `state_region`
- `postal_code`
- `country_code`
- `occupancy_type`
- `loan_type`
- `servicer_name`
- `lender_name`
- `original_loan_amount`
- `current_balance`
- `original_interest_rate`
- `current_interest_rate`
- `original_term_months`
- `remaining_term_months`
- `monthly_principal_interest`
- `monthly_payment_total`
- `home_value_estimate`
- `pmi_mip_monthly`
- `hoa_monthly`
- `flood_insurance_monthly`
- `has_escrow`
- `escrow_included_in_payment`
- `linked_obligation_id`
- `status`
- `source`
- `last_reviewed_at`
- timestamps

#### `mortgage_escrow_profiles`

Separate escrow assumptions and tracked escrow amounts from the base mortgage record.

Suggested fields:

- `mortgage_id`
- `property_tax_monthly`
- `homeowners_insurance_monthly`
- `flood_insurance_monthly`
- `other_escrow_monthly`
- `escrow_cushion_months`
- `expected_old_escrow_refund`
- `annual_tax_growth_rate`
- `annual_insurance_growth_rate`
- `source`
- `confidence_score`
- timestamps

### Later tables

#### `refinance_scenarios`

- `mortgage_id`
- `name`
- `loan_type`
- `rate_source_type`
- `rate_snapshot_id`
- `interest_rate`
- `term_months`
- `points`
- `cash_out_amount`
- `financed_fees`
- `roll_closing_costs_into_loan`
- `estimated_appraised_value`
- `estimated_ltv`
- `estimated_pmi_mip_monthly`
- `expected_property_tax_monthly`
- `expected_homeowners_insurance_monthly`
- `expected_flood_insurance_monthly`
- `expected_hoa_monthly`
- `preserve_current_payoff_timeline`
- `closing_date_assumption`
- `expected_years_in_home`
- `status`
- timestamps

#### `refinance_fees`

- `refinance_scenario_id`
- `category`
- `code`
- `name`
- `amount`
- `kind`
- `financed`
- `sort_order`
- `required`
- `notes`
- timestamps

#### `mortgage_rate_snapshots`

- `provider_key`
- `product_type`
- `loan_type`
- `term_months`
- `occupancy_type`
- `rate`
- `apr`
- `points`
- `assumptions`
- `source_url`
- `published_at`
- `imported_at`
- `raw_payload`
- timestamps

#### `mortgage_import_reviews`

- `user_id`
- `mortgage_id`
- `source_type`
- `source_filename`
- `storage_key`
- `extraction_method`
- `status`
- `parsed_payload`
- `confidence_score`
- `review_notes`
- `confirmed_at`
- timestamps

#### `mortgage_alert_rules`

- `mortgage_id`
- `user_id`
- `kind`
- `active`
- `threshold_config`
- `delivery_preferences`
- `last_evaluated_at`
- `last_triggered_at`
- timestamps

### Notification expansion later

Extend `notification_events.kind` only after the base mortgage domain is in place. Candidate kinds:

- `mortgage_payment_due`
- `mortgage_rate_watch`
- `mortgage_break_even`
- `mortgage_review`

## API and contract plan

Define request and response contracts in `apps/contracts` before wiring generated consumers.

Contract guidance:

- keep structured numeric fields as the source of truth
- keep explanation payloads separate from raw calculations
- avoid presentation-only strings as contract primitives

Recommended analysis response shape later:

- `mortgage_summary`
- `current_loan_baseline`
- `scenario_summaries`
- `payment_ranges`
- `closing_cost_breakdown`
- `escrow_breakdown`
- `break_even_metrics`
- `warnings`
- `assumptions`
- `rate_source`
- `generated_at`

Phase 1 contracts should stay narrow:

- mortgage list item
- mortgage detail
- escrow profile payload
- create mortgage request
- update mortgage request

## Frontend page plan

Use Next.js for Mortgage Center.

### Phase 1 pages

#### `/app/react/mortgages`

Mortgage Center overview page:

- list saved mortgages
- show high-level mortgage summary cards
- show escrow summary in overview rows or cards
- CTA to add a mortgage manually
- leave visible room for refinance, imports, and alerts later

#### `/app/react/mortgages/[mortgageId]`

Mortgage Center detail page:

- mortgage summary
- escrow summary
- edit affordance
- placeholder navigation or section entry points for refinance, imports, and alerts

### Later pages

#### `/app/react/mortgages/[mortgageId]/refinance`

- current mortgage baseline
- scenario comparison
- fee breakdown
- break-even outputs
- warnings and deterministic explanations

#### `/app/react/mortgages/[mortgageId]/imports`

- uploaded document list
- processing status
- parsed values
- confirmation and diff flow

#### `/app/react/mortgages/[mortgageId]/alerts`

- payment reminder settings
- rate watch thresholds
- annual review reminders
- notification preference linkage

## Alert and integration plan

Do not build a second alerting subsystem.

Use existing systems:

- `MoneyTree.Obligations.Obligation`
- `MoneyTree.Notifications.Event`
- Oban workers for scheduled evaluation and delivery

Recommended integration approach:

- a mortgage can optionally create or sync a linked obligation for the recurring mortgage payment
- refinance watch and review reminders should create notification events directly
- obligation linkage should be opt-in or review-first, not forced in Phase 1

Suggested mortgage-to-obligation mapping later:

- `creditor_payee` <- servicer or lender name
- `minimum_due_amount` <- total monthly payment or P&I depending on escrow inclusion
- `alert_preferences` <- merged from mortgage settings
- `linked_funding_account_id` <- selected account from mortgage settings

## Import pipeline plan

Imports are explicitly later-phase work. Keep them review-first.

Workflow:

1. upload document or screenshot
2. store file metadata
3. enqueue extraction via Oban
4. classify document type
5. extract candidate mortgage fields
6. compute field-level confidence
7. show review UI
8. require explicit user confirmation
9. preserve provenance and review history

First extracted fields later:

- servicer name
- masked loan number
- property address
- current principal balance
- interest rate
- monthly principal and interest
- escrow amount
- total payment due
- due date
- property tax amount if visible
- homeowners insurance amount if visible
- PMI/MIP if visible

Recommended layering:

- keep generic file handling outside core mortgage calculation logic
- let a future document layer handle upload/storage concerns
- keep `MoneyTree.Mortgages.ImportJob` responsible only for mortgage-specific mapping into review data

## Deterministic calculation plan

Build refinance calculations in pure Elixir under `MoneyTree.Mortgages.AnalysisEngine`.

Responsibilities later:

- amortization
- monthly payment calculations
- financed-fee handling
- escrow-inclusive payment comparisons
- optimistic/typical/conservative ranges
- break-even calculations
- time-horizon comparison
- warnings for term reset and unfavorable scenarios
- structured explanation payloads

No AI-generated financial calculations.

## Phased rollout

### Phase 1 - Mortgage Center shell

Goal: create the Mortgage Center shell, mortgage CRUD, escrow storage, Mortgage Center overview page,
and mortgage detail page.

Scope:

1. add `mortgages` and `mortgage_escrow_profiles` tables
2. add backend schemas and context functions
3. add contracts for mortgage CRUD
4. add authenticated Phoenix CRUD endpoints
5. add Next Mortgage Center overview page
6. add Next mortgage detail page
7. support manual entry and editing only

Exit criteria:

- user can create, edit, and view a mortgage
- escrow values are stored separately but displayed together
- user lands in a Mortgage Center overview
- the shell clearly leaves room for refinance, imports, and alerts

### Phase 2 - Deterministic refinance analysis

Goal: honest refinance comparison built on the saved mortgage baseline.

Scope:

1. add `refinance_scenarios` and `refinance_fees`
2. implement `AnalysisEngine`
3. implement keep-current baseline calculations
4. implement refinance scenario calculations
5. implement payment ranges, break-even, and warnings
6. add analysis endpoint and contracts
7. add Mortgage Center refinance page

Exit criteria:

- user can compare at least one scenario against the saved mortgage
- payment, cost, and break-even outputs are visible
- escrow is included in comparison outputs

### Phase 3 - Obligation and alert linkage

Goal: connect Mortgage Center to existing obligations and notifications.

Scope:

1. add `mortgage_alert_rules`
2. add mortgage-linked obligation sync service
3. expand notification event kinds as needed
4. add alert evaluation service and scheduled job
5. add Mortgage Center alerts page

Exit criteria:

- user can opt into payment reminders and mortgage watch alerts
- events flow through existing notification delivery paths

### Phase 4 - Rate snapshotting

Goal: import refinance rates with attribution and timestamps.

Scope:

1. add `mortgage_rate_snapshots`
2. define `RateProvider` behavior and one adapter
3. add import trigger endpoint and dev/admin path
4. add snapshot-backed scenario defaults
5. surface source and timestamp in UI

Exit criteria:

- scenario builder can use imported snapshots
- UI shows source and import time clearly

### Phase 5 - Import review workflow

Goal: allow mortgage detail imports from statements and screenshots with review before persistence.

Scope:

1. add `mortgage_import_reviews`
2. add upload endpoint and metadata flow
3. add Oban extraction scaffold
4. add import review API and UI
5. map confirmed fields into mortgage and escrow records
6. trigger re-analysis suggestion after confirmed changes

Exit criteria:

- user can upload a file, review parsed values, and confirm changes manually

### Phase 6 - Product integration polish

Goal: connect Mortgage Center outcomes back into the broader app.

Scope:

1. add dashboard summary cards
2. add annual review reminders
3. add re-run analysis automation when material values change
4. add export only if later approved
5. add more rate providers only if useful

Exit criteria:

- Mortgage Center feels integrated into MoneyTree instead of isolated

## Small execution slices for Codex

These slices are deliberately small and independently executable.

### Phase 1 slices

1. add `mortgages` migration
2. add `mortgage_escrow_profiles` migration
3. add `Mortgage` and `EscrowProfile` schemas
4. add `MoneyTree.Mortgages` CRUD context functions
5. add backend tests for mortgage CRUD
6. add contract definitions for mortgage list/detail/create/update
7. add `MortgageController` CRUD endpoints
8. add controller tests
9. add `/api/mortgages` routes
10. add Next Mortgage Center overview page
11. add Next mortgage detail page
12. add focused frontend tests for overview/detail rendering
13. apply migrations to the dev database

### Later slices

1. add refinance scenario schema and migration
2. add refinance fee schema and migration
3. implement amortization and payment math with tests
4. implement refinance comparison service with tests
5. expose analysis endpoint and contracts
6. build refinance page
7. add mortgage alert rule schema and migration
8. extend notification event kinds
9. implement obligation sync service
10. build alerts page
11. add rate snapshot schema and provider behavior
12. build rate snapshot display
13. add import review schema and upload metadata flow
14. build import review confirmation flow

## Testing plan

### Backend tests

Add focused tests for:

- mortgage changesets and CRUD context functions
- escrow storage and retrieval
- deterministic amortization and refinance math later
- obligation linkage later
- alert rule evaluation later

### Controller/API tests

- authenticated mortgage CRUD
- analysis response shape later
- alert CRUD later
- import review confirm/reject later

### Frontend tests

- Mortgage Center overview rendering
- mortgage detail rendering
- refinance comparison interactions later
- import review flow later

### Migration discipline

Every schema-affecting slice must:

1. add the migration
2. apply it to the active dev database
3. verify affected flows against the migrated schema

## Guardrails and non-goals

### Guardrails

- keep Mortgage Center as the initial shell
- do not broaden this into a full Home Owner Center yet
- keep calculations deterministic and explainable
- keep imports review-first and confirmation-based
- keep escrow visible in major summaries
- keep rate provider assumptions out of core analysis math
- reuse obligations, notifications, contracts, Phoenix contexts, Next, and Oban

### Non-goals for now

- lender marketplace flows
- automatic lender application submission
- auto-persisting OCR or AI guesses as truth
- tax advice or deduction optimization
- broad homeowner management beyond mortgage workflows
- a standalone refinance widget detached from Mortgage Center

## Final implementation stance

Treat mortgage tracking as a first-class MoneyTree domain, and treat refinance analysis as a tool
built on top of that domain.

That keeps the first implementation slice small and coherent:

- Mortgage Center shell
- mortgage CRUD
- escrow storage
- overview page
- detail page

Everything else layers on after that without changing the core shape.
