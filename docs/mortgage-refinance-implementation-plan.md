# Mortgage + Refinance implementation plan

## Purpose

Add a mortgage-focused evaluation feature set to MoneyTree without turning the app into a lender funnel.
The feature must help a user model an existing mortgage, compare realistic refinance scenarios, import
mortgage details from documents later, and create durable reminders/alerts tied to the user's mortgage
obligations and refinance watch rules.

This plan is intentionally anchored to the current MoneyTree repo structure and should be executed in
small, AI-friendly steps.

---

## Current repo constraints and fit

MoneyTree already has the right foundations for this feature:

- Phoenix is the primary backend and API layer.
- Next.js is already mounted behind Phoenix for richer app experiences.
- The app already has an obligations concept that stores recurring payment obligations.
- The app already has durable notification events and delivery attempts.
- The repo already expects background work to happen through Oban.
- The repo already has a contracts workspace for API definitions.
- The repo already has explicit guardrails for review-first document imports and deterministic financial logic.

### Existing code surfaces this feature should plug into

- `apps/money_tree/lib/money_tree` → new mortgage/refinance domain logic
- `apps/money_tree/lib/money_tree_web` → API controllers for mortgages, refinance scenarios, rate snapshots, imports, and alerts
- `apps/money_tree/priv/repo/migrations` → additive schema changes
- `apps/next/app` → refinance calculator UI and mortgage management pages
- `apps/contracts` → request/response contracts for the new endpoints
- `docs` → user-facing and developer-facing implementation notes

### Existing repo signals that shape this plan

The current router already exposes authenticated JSON APIs and app surfaces for obligations, settings,
accounts, and categorization. It also forwards richer React/Next UX behind `/app/react/*`, while LiveView
still powers other in-app pages. That makes the refinance workspace a strong candidate for a Next-driven UI
with Phoenix JSON endpoints behind it.

The existing obligation model already stores recurring payment metadata, funding-account linkage, and alert
preferences. Notification events already exist and are durable. That means mortgage payments should integrate
with those systems instead of inventing a completely separate reminder engine.

---

## Product boundaries

### In scope

1. Store one or more user mortgage profiles.
2. Model the current mortgage precisely enough to compare it against refinance scenarios.
3. Calculate refinance scenarios honestly, including fees, escrow, term reset, and range-based payments.
4. Import market refinance rates through a backend service with source attribution and timestamps.
5. Connect mortgage records to the existing obligation and notification systems.
6. Add future-ready document import scaffolding for PDFs and screenshots.
7. Allow alerts for payment due dates, rate watch thresholds, review reminders, and break-even milestones.
8. Keep the system explainable and rule-based.

### Out of scope for the first execution slice

1. Lender marketplace integrations.
2. Automatic application submission to lenders.
3. Fully automated OCR-based persistence without user review.
4. Tax advice or tax-deduction optimization.
5. Real estate AVM integrations unless later approved.
6. Cash-out suitability scoring beyond deterministic warnings.

---

## Recommended architecture

### UX placement

Use Next.js for the mortgage and refinance workspace.

Recommended route family:

- `/app/react/mortgages`
- `/app/react/mortgages/[mortgageId]`
- `/app/react/mortgages/[mortgageId]/refinance`
- `/app/react/mortgages/[mortgageId]/imports`
- `/app/react/mortgages/[mortgageId]/alerts`

Reasoning:

- The refinance workflow is form-heavy and comparison-heavy.
- It will benefit from richer charts, scenario tabs, and progressive disclosure.
- It is a better fit for the existing Phoenix-proxied Next surface than for a new LiveView-heavy implementation.

### Backend placement

Create a new Phoenix context family under `MoneyTree.Mortgages`.

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

Keep calculation logic in pure Elixir service modules, not in controllers and not in the frontend.

### Alert integration

Do not build a second alerting subsystem.

Integrate with:

- `MoneyTree.Obligations.Obligation`
- `MoneyTree.Notifications.Event`

Recommended approach:

- every active mortgage can optionally create or synchronize a linked obligation for the monthly mortgage payment
- refinance watch rules and analysis reminder rules can create notification events directly without pretending they are payment obligations
- extend notification event kinds in a later migration to include mortgage-related event kinds

### Background jobs

Use Oban for:

- rate ingestion and normalization
- document extraction orchestration
- re-analysis when imported rates change materially
- scheduled alert generation
- optional mortgage-obligation synchronization

---

## Data model plan

All schema changes should be additive and reversible where possible.

### 1. `mortgages`

Represents the user's current mortgage or a mortgage they want to track.

Suggested fields:

- `id`
- `user_id`
- `nickname`
- `property_name`
- `street_line_1` nullable
- `street_line_2` nullable
- `city` nullable
- `state_region` nullable
- `postal_code` nullable
- `country_code` default `US`
- `occupancy_type` (`primary_residence`, `second_home`, `investment_property`)
- `loan_type` (`conventional`, `fha`, `va`, `usda`, `jumbo`, `other`)
- `servicer_name`
- `lender_name`
- `original_loan_amount`
- `current_balance`
- `original_interest_rate`
- `current_interest_rate`
- `original_term_months`
- `remaining_term_months`
- `monthly_principal_interest`
- `monthly_payment_total` nullable
- `home_value_estimate`
- `pmi_mip_monthly` nullable
- `hoa_monthly` nullable
- `flood_insurance_monthly` nullable
- `has_escrow` boolean
- `escrow_included_in_payment` boolean
- `linked_obligation_id` nullable
- `status` (`active`, `paid_off`, `sold`, `archived`)
- `source` (`manual`, `imported_document`, `connected_account`, `mixed`)
- `last_reviewed_at` nullable
- `inserted_at`, `updated_at`

### 2. `mortgage_escrow_profiles`

Stores monthly and closing-time escrow assumptions separately from the mortgage record.

Suggested fields:

- `id`
- `mortgage_id`
- `property_tax_monthly`
- `homeowners_insurance_monthly`
- `flood_insurance_monthly` nullable
- `other_escrow_monthly` nullable
- `escrow_cushion_months` nullable
- `expected_old_escrow_refund` nullable
- `annual_tax_growth_rate` nullable
- `annual_insurance_growth_rate` nullable
- `source`
- `confidence_score` nullable
- timestamps

### 3. `refinance_scenarios`

One mortgage can have many refinance scenarios.

Suggested fields:

- `id`
- `mortgage_id`
- `name`
- `loan_type`
- `rate_source_type` (`manual`, `snapshot`, `blended`)
- `rate_snapshot_id` nullable
- `interest_rate`
- `term_months`
- `points`
- `cash_out_amount`
- `financed_fees` boolean
- `roll_closing_costs_into_loan` boolean
- `estimated_appraised_value` nullable
- `estimated_ltv` nullable
- `estimated_pmi_mip_monthly` nullable
- `expected_property_tax_monthly` nullable
- `expected_homeowners_insurance_monthly` nullable
- `expected_flood_insurance_monthly` nullable
- `expected_hoa_monthly` nullable
- `preserve_current_payoff_timeline` boolean
- `closing_date_assumption` nullable
- `expected_years_in_home` nullable
- `status` (`draft`, `active`, `archived`)
- timestamps

### 4. `refinance_fees`

Stores line-item fees rather than a single opaque total.

Suggested fields:

- `id`
- `refinance_scenario_id`
- `category`
- `code`
- `name`
- `amount`
- `kind` (`closing_cost`, `prepaid`, `escrow_funding`, `credit`, `adjustment`)
- `financed` boolean
- `sort_order`
- `required` boolean
- `notes` nullable
- timestamps

### 5. `mortgage_rate_snapshots`

Stores imported rate data with attribution.

Suggested fields:

- `id`
- `provider_key`
- `product_type`
- `loan_type`
- `term_months`
- `occupancy_type` nullable
- `rate`
- `apr` nullable
- `points` nullable
- `assumptions` map
- `source_url`
- `published_at` nullable
- `imported_at`
- `raw_payload` map
- timestamps

### 6. `mortgage_import_reviews`

Future-ready import staging table for PDFs/screenshots/manual validation.

Suggested fields:

- `id`
- `user_id`
- `mortgage_id` nullable
- `source_type` (`pdf`, `image`, `screenshot`, `manual_upload`)
- `source_filename` nullable
- `storage_key` nullable
- `extraction_method` (`ocr`, `llm_structured`, `hybrid`, `manual`)
- `status` (`uploaded`, `processing`, `review_required`, `confirmed`, `rejected`, `failed`)
- `parsed_payload` map
- `confidence_score` nullable
- `review_notes` nullable
- `confirmed_at` nullable
- timestamps

### 7. `mortgage_alert_rules`

Deterministic alert definitions.

Suggested fields:

- `id`
- `mortgage_id`
- `user_id`
- `kind` (`payment_due`, `rate_watch`, `break_even_reminder`, `document_review`, `annual_review`)
- `active` boolean
- `threshold_config` map
- `delivery_preferences` map
- `last_evaluated_at` nullable
- `last_triggered_at` nullable
- timestamps

### 8. notification event expansion

Extend `notification_events.kind` beyond `payment_obligation` in a later migration so mortgage workflows
can create first-class notification events, such as:

- `mortgage_payment_due`
- `mortgage_rate_watch`
- `mortgage_break_even`
- `mortgage_review`

This should happen after the base mortgage domain is in place.

---

## Core domain logic plan

### A. deterministic refinance engine

Build a pure Elixir calculation engine under `MoneyTree.Mortgages.AnalysisEngine`.

Responsibilities:

- amortization calculations
- payment calculations
- financed-fee handling
- escrow-inclusive monthly payment calculations
- payment range generation
- break-even calculations
- time-horizon comparisons
- warning generation
- explanation payload generation for the frontend

This engine must not rely on AI.

### B. scenario comparison service

Build a higher-level service under `MoneyTree.Mortgages.Analysis` that:

- loads the mortgage + escrow profile + scenario + fees
- computes baseline keep-current-loan economics
- computes one or more refinance comparisons
- produces structured view models for the API

### C. mortgage-obligation synchronization

Build a narrow service that can create or update a linked `Obligation` record for the active mortgage.

Suggested mapping:

- `creditor_payee` ← servicer or lender name
- `minimum_due_amount` ← current monthly payment total or monthly P&I if escrow is not included
- `alert_preferences` ← merged from mortgage alert preferences
- `linked_funding_account_id` ← selected funding account from the mortgage settings UI

Do not force this linkage in v1. Make it opt-in or review-first.

### D. rate import service

Create `MoneyTree.Mortgages.RateProvider` behavior and at least one provider adapter.

Responsibilities:

- fetch external rate data
- normalize into internal shape
- save rate snapshots with attribution
- expose timestamp and assumptions to the frontend
- support manual provider substitution later

Important guardrail:

Do not present provider-advertised values as guaranteed borrower rates. The analysis layer must still
construct optimistic / typical / conservative ranges.

---

## API plan

Add authenticated Phoenix JSON endpoints and define their contracts under `apps/contracts`.

### Recommended endpoint family

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

### Contract guidance

Each contract should keep calculations and explanations separate.

Suggested response shape for analysis:

- `mortgage_summary`
- `current_loan_baseline`
- `scenario_summaries[]`
- `payment_ranges`
- `closing_cost_breakdown`
- `escrow_breakdown`
- `break_even_metrics`
- `warnings[]`
- `assumptions`
- `rate_source`
- `generated_at`

Do not send presentation-only strings as the source of truth. Keep numbers structured.

---

## Frontend plan

### Next.js route structure

Add a mortgage workspace under `apps/next/app`.

Recommended pages:

- mortgage list page
- mortgage detail page
- refinance analysis page
- import review page
- alert rules page

### Primary UX recommendations

1. Use a comparison-first layout rather than a lender funnel.
2. Show current mortgage vs refinance scenario cards side by side.
3. Default to honest metrics, not teaser savings.
4. Use accordions or drawers for fee breakdowns.
5. Show separate views for:
   - payment summary
   - cost breakdown
   - break-even views
   - amortization
   - alerts
   - import review
6. Keep escrow visible in all major summaries.

### Proposed page breakdown

#### `/app/react/mortgages`

- list saved mortgages
- highlight next payment due if linked to obligations
- show any active refinance watch alerts
- CTA to add a mortgage manually
- CTA to import a mortgage statement later

#### `/app/react/mortgages/[mortgageId]`

- mortgage summary card
- escrow summary card
- linked obligation status
- active alerts summary
- latest rate snapshot summary
- actions: edit, analyze refinance, manage alerts, review imports

#### `/app/react/mortgages/[mortgageId]/refinance`

Main analysis workspace:

- left column: current mortgage baseline
- top controls: add scenario, duplicate scenario, compare term options
- scenario cards for 30y/20y/15y/custom
- monthly payment ranges section
- full cost breakdown section
- break-even section with multiple definitions
- warnings and honesty checks
- charts for balance and cumulative cost

#### `/app/react/mortgages/[mortgageId]/imports`

- uploaded document list
- processing status
- parsed fields with confidence flags
- user confirmation form
- diff view between imported values and stored mortgage values

#### `/app/react/mortgages/[mortgageId]/alerts`

- payment reminder settings
- rate watch threshold configuration
- annual mortgage review reminder
- break-even follow-up reminder rules
- linkage to existing notification preferences

---

## Import pipeline plan for PDFs and screenshots

This should be phased in after the manual calculator works.

### import workflow

1. upload document or screenshot
2. store file metadata
3. run extraction job
4. classify the document type
5. extract candidate mortgage fields
6. compute per-field confidence and overall confidence
7. present a review screen
8. require user confirmation before updating canonical mortgage data
9. preserve import provenance and reviewed history

### extracted fields to target first

- servicer name
- loan number masked
- property address
- current principal balance
- interest rate
- monthly principal and interest
- escrow amount
- total payment due
- due date
- property tax amount if visible
- homeowners insurance amount if visible
- PMI/MIP amount if visible

### technical notes

- follow the AGENTS review-first import guidance exactly
- keep extraction logic separate from persistence logic
- do not overwrite confirmed mortgage fields silently
- store raw parsed payload for re-review
- use Oban for asynchronous extraction
- make the extraction provider swappable later

### screenshot/PDF staging recommendation

Do not build OCR deep into the mortgage domain itself.

Recommended layering:

- `MoneyTree.Documents` or a similarly narrow import support layer later
- `MoneyTree.Mortgages.ImportJob` orchestrates mortgage-specific mapping into the review model

That keeps mortgage logic deterministic while allowing more document types later.

---

## Automatic linking between current mortgage and refinance calculator

The refinance calculator should not be a disconnected widget.

### target behavior

When a user has a saved mortgage:

- the refinance page uses that mortgage as the baseline automatically
- refinance scenarios inherit relevant mortgage defaults
- the calculator preloads escrow assumptions from the mortgage escrow profile
- the calculator can recommend preserving the current payoff timeline as one scenario option
- alerts can be created from analysis results

### examples of automatic linkages

1. `current_balance` from the mortgage becomes the default refinance principal baseline
2. `remaining_term_months` becomes the basis for the keep-current comparison
3. escrow profile becomes the basis for full-payment comparisons
4. if the mortgage has a linked obligation, payment reminders can reuse that schedule
5. if the user imports a new statement, the mortgage can be marked as needing re-analysis
6. if imported or refreshed rates cross the user's configured threshold, generate a rate watch notification event

### analysis-to-alert linkage examples

Allow the user to create alerts such as:

- tell me when a 15-year refinance payment falls within my configured budget
- tell me when my estimated break-even drops below 24 months
- remind me to review this refinance analysis in 90 days
- alert me if my current mortgage payment looks out of sync with the latest imported statement

---

## Rollout order

The order below is designed for small, AI-friendly implementation slices.

### Phase 1 — manual mortgage foundation

Goal: store mortgages and show them in the app.

Tasks:

1. add `mortgages` and `mortgage_escrow_profiles` tables
2. add backend schemas and context functions
3. add contracts for CRUD endpoints
4. add Phoenix controller endpoints
5. add Next mortgage list/detail pages
6. allow manual entry and editing only

Exit criteria:

- user can create, edit, and view a mortgage
- escrow values are stored separately but displayed together

### Phase 2 — deterministic refinance calculator

Goal: honest refinance comparison from manual inputs.

Tasks:

1. add `refinance_scenarios` and `refinance_fees`
2. build `AnalysisEngine`
3. implement current-loan baseline calculations
4. implement refinance scenario calculations
5. implement optimistic/typical/conservative payment ranges
6. add warnings and break-even outputs
7. add Next refinance comparison page

Exit criteria:

- user can compare at least one scenario against the current mortgage
- payment, cost, and break-even views are visible
- escrow is included properly

### Phase 3 — obligation and alert linkage

Goal: connect mortgages to existing reminders and notifications.

Tasks:

1. add `mortgage_alert_rules`
2. add mortgage-linked obligation synchronization service
3. expand notification event kinds for mortgage workflows
4. add rule evaluation service and scheduled job
5. add alerts UI in Next

Exit criteria:

- user can opt into payment reminders and refinance watch alerts
- notification events appear through the existing delivery path

### Phase 4 — rate import and snapshotting

Goal: import refinance rates with attribution and timestamps.

Tasks:

1. add `mortgage_rate_snapshots`
2. define provider behavior and one provider adapter
3. add manual import trigger endpoint and admin/dev seed path
4. add snapshot-driven scenario defaults
5. add rate-source UI and timestamp display

Exit criteria:

- scenario builder can use imported rate snapshots
- UI shows source and import time clearly

### Phase 5 — import review workflow

Goal: allow mortgage detail imports from statements/screenshots with user confirmation.

Tasks:

1. add `mortgage_import_reviews`
2. add upload endpoint + storage metadata flow
3. add Oban extraction job scaffold
4. add import review API + UI
5. map confirmed fields into mortgage + escrow models
6. trigger re-analysis suggestion after confirmed changes

Exit criteria:

- a user can upload a file, review parsed values, and confirm changes manually

### Phase 6 — polish and automation

Goal: connect analysis outcomes back into the product experience.

Tasks:

1. add dashboard summary cards for mortgages and refinance watch status
2. add annual review reminders
3. add “re-run analysis” automation when material values change
4. add CSV/PDF export for analysis output later if desired
5. add more provider adapters only if useful

Exit criteria:

- mortgage tracking feels integrated into MoneyTree, not isolated

---

## Small execution tasks for AI coding agents

These tasks are intentionally narrow and should be treated as separate prompts or PRs.

1. create base mortgage schemas and migrations
2. add mortgage CRUD context functions and tests
3. expose mortgage CRUD endpoints and contracts
4. build the Next mortgage list page
5. build the Next mortgage detail page
6. add refinance scenario schemas and migrations
7. implement core amortization and payment functions with tests
8. implement refinance analysis service with tests
9. expose analysis endpoint and contracts
10. build the refinance comparison page
11. add refinance fee line-item editing UI
12. add mortgage alert rule schemas and migrations
13. extend notification event kinds for mortgage alerts
14. implement mortgage-linked obligation synchronization
15. build mortgage alert rules UI
16. add rate snapshot schema and provider behavior
17. implement first rate provider adapter
18. build rate snapshot display UI
19. add mortgage import review schema and migration
20. add file-upload metadata flow for mortgage imports
21. add import review confirmation UI
22. trigger re-analysis reminders when confirmed fields change

---

## Testing plan

### backend tests

Add deterministic tests for:

- amortization schedule generation
- monthly payment calculation
- financed-fee scenarios
- escrow-inclusive payment totals
- payment range generation
- break-even calculations
- scenario comparison outputs
- warning generation for term reset and unfavorable scenarios
- mortgage-obligation synchronization
- alert rule evaluation

### controller/API tests

- authenticated CRUD for mortgages and scenarios
- analysis response shape
- rate snapshot retrieval
- alert rule CRUD
- import review confirm/reject flow

### frontend tests

- mortgage list and detail rendering
- refinance page scenario editing
- fee breakdown interaction
- warning visibility
- rate source/timestamp rendering
- import review confirmation flow

### migration discipline

Every schema-affecting task must apply migrations to the active dev database, per repo rules.
Do not consider schema work complete until migrations have been applied successfully.

---

## Risk notes and guardrails

1. Do not let the UI reduce everything to “lower monthly payment”.
2. Do not hide reset-term costs.
3. Do not mix imported guesses with confirmed mortgage truth without review state.
4. Do not push OCR or AI extraction directly into canonical fields.
5. Do not hardwire rate-provider assumptions into the core analysis engine.
6. Do not build a parallel reminder system when obligations + notifications already exist.
7. Do not store fees as a single opaque number.
8. Do not make escrow optional in the comparison summaries just because some lender tools do that.

---

## Recommended first implementation prompt for Codex

Create a small, repo-anchored implementation for Phase 1 of `docs/mortgage-refinance-implementation-plan.md`.

Requirements:

- inspect existing MoneyTree patterns before coding
- add additive Ecto migrations for `mortgages` and `mortgage_escrow_profiles`
- create schemas, changesets, and context functions under `apps/money_tree/lib/money_tree/mortgages`
- add authenticated Phoenix JSON CRUD endpoints under the existing `/api` pattern
- add matching contracts in `apps/contracts`
- build a minimal Next page under `apps/next/app` to list and create mortgages
- keep the work narrow; do not implement refinance math yet
- add focused tests for backend changes
- run the required migrations against the dev database
- validate the new flow using the repo’s existing development startup expectations

---

## Recommended second implementation prompt for Codex

Implement Phase 2 of `docs/mortgage-refinance-implementation-plan.md` in small, repo-consistent steps.

Requirements:

- inspect the new mortgage domain code first
- add additive migrations for `refinance_scenarios` and `refinance_fees`
- implement deterministic refinance calculation services in Elixir
- include escrow, fee line items, break-even calculations, and warning generation
- expose an authenticated analysis endpoint
- add matching contracts in `apps/contracts`
- build a minimal but honest Next comparison UI
- do not add rate imports yet
- do not add PDF/image import yet
- add tests for core financial math and warnings
- apply migrations to the dev database before considering the task complete

---

## Final recommendation

Treat mortgage tracking as a first-class MoneyTree domain, and treat the refinance calculator as an analysis tool built on top of that domain.

That keeps the system honest and gives you the future hooks you want:

- mortgage statement imports
- automatic baseline loading for refinance analysis
- obligation/payment reminders
- refinance watch alerts
- re-analysis when facts change

This is a better long-term fit than building a standalone refinance widget first and trying to glue it back into the product later.
