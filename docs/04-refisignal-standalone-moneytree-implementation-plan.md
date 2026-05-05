# RefiSignal standalone + MoneyTree implementation plan

## Purpose

Build **RefiSignal** as a refinance decision tool that can run inside MoneyTree now, while keeping the domain and UI boundaries clean enough to run as a standalone satellite app later.

The product goal is not just to calculate a new mortgage payment. RefiSignal should:

- read current mortgage documents through a review-first document import flow
- extract useful mortgage data points with a local Ollama-backed LLM pipeline
- pull mortgage-rate benchmark data from external sources
- accept manual or API-fed lender quotes
- compare refinance options with deterministic math
- surface detailed fee, escrow, interest, break-even, and cash-to-close analysis
- create alerts when rates or lender quotes make a refinance worth reviewing
- reuse MoneyTree's existing UI, auth, contracts, background jobs, mailer, and notifications where possible

## Current repo comparison

### Existing MoneyTree foundation

MoneyTree already has most of the infrastructure RefiSignal should use:

- Phoenix backend app under `apps/money_tree`
- Next.js frontend under `apps/next`
- shared Tailwind/UI package under `apps/ui`
- API contract workspace under `apps/contracts`
- PostgreSQL and Ecto migrations
- Oban background processing
- Swoosh mail delivery
- authenticated API routing
- existing notification and obligation concepts
- existing mortgage CRUD API and Mortgage Center planning
- existing app shell navigation in `MoneyTreeWeb.Layouts`

This means RefiSignal should not be implemented as a separate stack or separate product shell first. It should start as a MoneyTree feature area with standalone-ready boundaries.

### Existing mortgage work to reuse

The repo already includes a Mortgage Center implementation plan in `docs/03-mortgage-center-implementation-plan.md`. That plan correctly frames mortgage tracking, escrow visibility, refinance analysis, imports, alerts, and rate watch as related workflows.

The codebase also already has:

- `MoneyTree.Mortgages`
- `MoneyTree.Mortgages.Mortgage`
- `MoneyTree.Mortgages.EscrowProfile`
- `MoneyTreeWeb.MortgageController`
- `/api/mortgages` routes
- `/api/mortgages/:id` routes
- OpenAPI contract definitions for mortgage CRUD

RefiSignal should therefore extend the current mortgage domain instead of replacing it.

### Gaps RefiSignal needs to fill

The current repo appears to have the mortgage baseline layer but not the refinance decision layer yet.

Primary missing pieces:

- refinance scenario schemas and APIs
- deterministic refinance analysis engine
- fee templates and scenario-specific fee items
- rate source/provider abstraction
- rate observation import jobs
- lender quote management
- document upload and extraction review workflow
- Ollama extraction worker interface
- alert rules tied to scenario results
- RefiSignal UI screens and menu entry
- standalone app packaging strategy

## Product positioning

Use this terminology:

- **Mortgage Center**: the broader home-loan area inside MoneyTree.
- **RefiSignal**: the refinance analysis and alerting tool within Mortgage Center.

Recommended UI labels:

- Main MoneyTree menu item: `RefiSignal`
- Page title: `RefiSignal`
- Subtitle: `Mortgage refinance analysis and rate-watch alerts`

This keeps the feature focused. Mortgage Center can still exist as the umbrella concept, but users should see a direct, obvious refinance entry point.

## Integration model

### Inside MoneyTree

RefiSignal should be available at:

- Phoenix canonical route: `/app/refisignal`
- Optional mortgage-specific route: `/app/refisignal/:mortgage_id`
- Next.js route, if implemented in Next first: `/app/react/refisignal`
- Mortgage-specific Next route: `/app/react/refisignal/[mortgageId]`

Add `RefiSignal` to the MoneyTree app menu in `MoneyTreeWeb.Layouts.app_nav_items/0`.

Recommended placement:

```elixir
%{label: "RefiSignal", path: ~p"/app/refisignal", page_title: "RefiSignal"}
```

Suggested order:

1. Dashboard
2. Accounts
3. Transactions
4. Budgets
5. Obligations
6. Assets
7. RefiSignal
8. Transfers
9. Settings

Reasoning: RefiSignal belongs near Assets and Obligations because it is a home/loan planning surface, not a transaction ledger.

### Standalone mode later

Keep the RefiSignal domain portable by avoiding hard dependencies on MoneyTree UI routes and session assumptions in the core calculation and extraction code.

Standalone target shape:

```text
RefiSignal standalone
├── web shell / landing page
├── RefiSignal UI package or route group
├── same API contract subset
├── same calculation engine
├── same document extraction worker contract
├── same notification channel interface
└── isolated deployment config
```

MoneyTree-integrated shape:

```text
MoneyTree
├── Dashboard
├── Accounts
├── Transactions
├── Budgets
├── Obligations
├── Assets
├── RefiSignal
│   ├── mortgage picker
│   ├── current mortgage baseline
│   ├── scenarios
│   ├── lender quotes
│   ├── document imports
│   ├── rate watch
│   └── alerts
├── Transfers
└── Settings
```

## Architecture principles

### 1. Deterministic math, explainable AI

The LLM may extract, classify, summarize, and explain.

The LLM must not be the source of truth for math.

Implement refinance calculations in deterministic Elixir modules with tests for:

- monthly payment
- amortization schedule
- total interest
- remaining balance after month N
- closing cost break-even
- financed vs cash-paid fees
- points and lender credits
- escrow/prepaid treatment
- APR estimate, if included
- scenario comparison over fixed horizons

### 2. Review-first document ingestion

Uploaded mortgage papers should never silently overwrite canonical mortgage records.

Flow:

1. User uploads document.
2. File is stored with metadata.
3. Oban job extracts text/OCR output.
4. Ollama worker extracts structured candidate fields.
5. Candidate fields are stored in an import review record.
6. User reviews field-level values, confidence, and source snippets.
7. User confirms selected updates.
8. Only confirmed fields update the mortgage baseline or scenario assumptions.

### 3. Portable domain boundaries

Keep these layers separate:

- persistence schemas
- context functions
- calculation engine
- rate provider adapters
- document extraction adapters
- notification/alert evaluation
- UI rendering

This makes it easier to split RefiSignal into a standalone app later.

### 4. Reuse MoneyTree systems first

Do not create parallel systems when MoneyTree already has one.

Reuse:

- auth/session handling
- PostgreSQL/Ecto
- OpenAPI contracts
- Oban workers
- Swoosh mailer
- notification events
- existing mortgage records
- existing obligation linkage
- app shell navigation
- shared Tailwind/UI styling

## Backend implementation plan

### Context modules

Extend `MoneyTree.Mortgages` or add focused submodules under `MoneyTree.Mortgages`.

Recommended modules:

```text
apps/money_tree/lib/money_tree/mortgages/
  refinance_scenario.ex
  refinance_fee.ex
  refinance_result.ex
  rate_source.ex
  rate_observation.ex
  lender_quote.ex
  document.ex
  document_extraction.ex
  alert_rule.ex
  analysis_engine.ex
  amortization.ex
  fee_templates.ex
  rate_providers/
    fred.ex
    freddie_mac.ex
    manual.ex
    lender_quote.ex
  workers/
    rate_import_worker.ex
    document_extraction_worker.ex
    alert_evaluation_worker.ex
```

Recommended context API additions in `MoneyTree.Mortgages`:

```elixir
list_refinance_scenarios(user, mortgage_id)
fetch_refinance_scenario(user, scenario_id)
create_refinance_scenario(user, mortgage_id, attrs)
update_refinance_scenario(user, scenario_id, attrs)
delete_refinance_scenario(user, scenario_id)
analyze_refinance_scenario(user, scenario_id)
analyze_refinance_options(user, mortgage_id, attrs)

list_rate_sources(user)
create_rate_source(user, attrs)
import_rate_observations(source_id)
list_rate_observations(filters)

list_lender_quotes(user, mortgage_id)
create_lender_quote(user, mortgage_id, attrs)
update_lender_quote(user, quote_id, attrs)
archive_lender_quote(user, quote_id)

create_document_upload(user, mortgage_id, attrs)
create_document_extraction_review(user, document_id, attrs)
confirm_document_extraction(user, review_id, selected_fields)
reject_document_extraction(user, review_id)

list_refisignal_alert_rules(user, mortgage_id)
create_refisignal_alert_rule(user, mortgage_id, attrs)
update_refisignal_alert_rule(user, alert_rule_id, attrs)
delete_refisignal_alert_rule(user, alert_rule_id)
evaluate_refisignal_alerts()
```

## Database plan

Use additive migrations. Existing `mortgages` and `mortgage_escrow_profiles` remain the baseline.

### `refinance_scenarios`

Stores user-created scenario assumptions.

Suggested fields:

- `id`
- `user_id`
- `mortgage_id`
- `name`
- `loan_type`
- `product_type`
- `term_months`
- `interest_rate`
- `apr`
- `points`
- `lender_credit_amount`
- `cash_out_amount`
- `cash_in_amount`
- `roll_closing_costs_into_loan`
- `financed_fees_amount`
- `cash_to_close_override`
- `estimated_appraised_value`
- `estimated_ltv`
- `estimated_pmi_mip_monthly`
- `expected_property_tax_monthly`
- `expected_homeowners_insurance_monthly`
- `expected_flood_insurance_monthly`
- `expected_hoa_monthly`
- `closing_date_assumption`
- `expected_years_in_home`
- `rate_source_type`
- `rate_observation_id`
- `lender_quote_id`
- `status`
- timestamps

Indexes:

- `user_id`
- `mortgage_id`
- `status`
- `rate_observation_id`
- `lender_quote_id`

### `refinance_fees`

Stores line-item fee assumptions per scenario.

Suggested fields:

- `id`
- `refinance_scenario_id`
- `category`
- `code`
- `name`
- `amount`
- `kind`
- `financed`
- `paid_at_closing`
- `is_true_cost`
- `is_prepaid_or_escrow`
- `required`
- `sort_order`
- `notes`
- timestamps

Fee categories:

- lender
- points
- title
- recording
- appraisal
- credit_report
- prepaid_interest
- escrow_deposit
- insurance
- taxes
- payoff_adjustment
- other

Important distinction:

- True refinance costs affect break-even.
- Prepaids and escrow deposits affect cash to close but should not be treated the same as lender/title costs.

### `refinance_results`

Stores generated analysis snapshots so alerts and past comparisons are reproducible.

Suggested fields:

- `id`
- `user_id`
- `mortgage_id`
- `refinance_scenario_id`
- `current_monthly_pi`
- `current_monthly_total`
- `new_monthly_pi`
- `new_monthly_total`
- `monthly_savings_pi`
- `monthly_savings_total`
- `new_loan_amount`
- `cash_to_close`
- `true_closing_costs`
- `prepaids_and_escrow`
- `break_even_months`
- `interest_saved_life_of_loan`
- `interest_saved_5_year`
- `interest_saved_7_year`
- `interest_saved_10_year`
- `remaining_balance_delta_5_year`
- `remaining_balance_delta_7_year`
- `remaining_balance_delta_10_year`
- `warnings`
- `assumptions`
- `computed_at`
- timestamps

Store `warnings` and `assumptions` as JSONB.

### `mortgage_rate_sources`

Represents external or manual rate providers.

Suggested fields:

- `id`
- `provider_key`
- `name`
- `source_type`
- `base_url`
- `enabled`
- `requires_api_key`
- `config`
- `last_success_at`
- `last_error_at`
- `last_error_message`
- timestamps

Initial source types:

- `fred`
- `freddie_mac`
- `manual`
- `lender_api`
- `aggregator_api`

### `mortgage_rate_observations`

Stores imported market-rate observations.

Suggested fields:

- `id`
- `rate_source_id`
- `provider_key`
- `series_key`
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
- `observed_at`
- `imported_at`
- `raw_payload`
- timestamps

Indexes:

- `(provider_key, series_key, published_at)` unique where applicable
- `product_type`
- `term_months`
- `published_at`

### `lender_quotes`

Stores specific user-entered or API-provided offers.

Suggested fields:

- `id`
- `user_id`
- `mortgage_id`
- `lender_name`
- `quote_source`
- `quote_reference`
- `loan_type`
- `product_type`
- `term_months`
- `interest_rate`
- `apr`
- `points`
- `lender_credit_amount`
- `estimated_closing_costs`
- `estimated_cash_to_close`
- `estimated_monthly_pi`
- `estimated_monthly_total`
- `lock_available`
- `lock_expires_at`
- `quote_expires_at`
- `raw_payload`
- `status`
- timestamps

Status values:

- active
- expired
- archived
- selected

### `mortgage_documents`

Stores uploaded mortgage-related documents.

Suggested fields:

- `id`
- `user_id`
- `mortgage_id`
- `document_type`
- `original_filename`
- `content_type`
- `byte_size`
- `storage_key`
- `checksum_sha256`
- `status`
- `uploaded_at`
- timestamps

Document types:

- mortgage_statement
- closing_disclosure
- loan_estimate
- escrow_statement
- payoff_quote
- lender_quote
- property_tax_bill
- homeowners_insurance
- other

### `mortgage_document_extractions`

Stores extraction attempts and review payloads.

Suggested fields:

- `id`
- `user_id`
- `mortgage_id`
- `mortgage_document_id`
- `extraction_method`
- `model_name`
- `status`
- `ocr_text_storage_key`
- `raw_text_excerpt`
- `extracted_payload`
- `field_confidence`
- `source_citations`
- `reviewed_at`
- `confirmed_at`
- `rejected_at`
- timestamps

### `refisignal_alert_rules`

Stores refinance-specific alert rules.

Suggested fields:

- `id`
- `user_id`
- `mortgage_id`
- `name`
- `kind`
- `active`
- `threshold_config`
- `delivery_preferences`
- `last_evaluated_at`
- `last_triggered_at`
- timestamps

Kinds:

- rate_below_threshold
- monthly_savings_above_threshold
- break_even_below_months
- interest_saved_above_threshold
- fifteen_year_within_payment_delta
- lender_quote_expiring
- document_review_needed

## API plan

Add routes under the existing authenticated `/api` scope.

### Refinance scenarios

- `GET /api/mortgages/:mortgage_id/refinance_scenarios`
- `POST /api/mortgages/:mortgage_id/refinance_scenarios`
- `GET /api/refinance_scenarios/:id`
- `PUT /api/refinance_scenarios/:id`
- `DELETE /api/refinance_scenarios/:id`
- `POST /api/refinance_scenarios/:id/analyze`
- `POST /api/mortgages/:mortgage_id/refisignal/analyze`

### Fees

- `GET /api/refinance_scenarios/:scenario_id/fees`
- `POST /api/refinance_scenarios/:scenario_id/fees`
- `PUT /api/refinance_fees/:id`
- `DELETE /api/refinance_fees/:id`
- `POST /api/refinance_scenarios/:scenario_id/fees/apply_template`

### Rate sources and observations

- `GET /api/mortgage_rate_sources`
- `POST /api/mortgage_rate_sources`
- `PUT /api/mortgage_rate_sources/:id`
- `POST /api/mortgage_rate_sources/:id/import`
- `GET /api/mortgage_rate_observations`

### Lender quotes

- `GET /api/mortgages/:mortgage_id/lender_quotes`
- `POST /api/mortgages/:mortgage_id/lender_quotes`
- `GET /api/lender_quotes/:id`
- `PUT /api/lender_quotes/:id`
- `DELETE /api/lender_quotes/:id`
- `POST /api/lender_quotes/:id/convert_to_scenario`

### Documents and extraction

- `GET /api/mortgages/:mortgage_id/documents`
- `POST /api/mortgages/:mortgage_id/documents`
- `GET /api/mortgage_documents/:id`
- `DELETE /api/mortgage_documents/:id`
- `POST /api/mortgage_documents/:id/extract`
- `GET /api/mortgage_document_extractions/:id`
- `POST /api/mortgage_document_extractions/:id/confirm`
- `POST /api/mortgage_document_extractions/:id/reject`

### Alerts

- `GET /api/mortgages/:mortgage_id/refisignal_alert_rules`
- `POST /api/mortgages/:mortgage_id/refisignal_alert_rules`
- `PUT /api/refisignal_alert_rules/:id`
- `DELETE /api/refisignal_alert_rules/:id`
- `POST /api/refisignal_alert_rules/evaluate`

## Contract plan

Update `apps/contracts/specs/openapi.yaml` before generating/using frontend clients.

Add schemas for:

- `RefinanceScenario`
- `CreateRefinanceScenarioRequest`
- `UpdateRefinanceScenarioRequest`
- `RefinanceFee`
- `CreateRefinanceFeeRequest`
- `RefinanceAnalysisResult`
- `MortgageRateSource`
- `MortgageRateObservation`
- `LenderQuote`
- `MortgageDocument`
- `MortgageDocumentExtraction`
- `RefiSignalAlertRule`

Important contract rules:

- Use string-encoded decimal values consistently with existing mortgage contracts.
- Keep calculation inputs and calculation outputs separate.
- Keep `warnings`, `assumptions`, `source_citations`, and raw provider payloads as structured objects, not human-only strings.
- Do not expose full loan numbers or sensitive document identifiers in API responses.

## Calculation engine plan

Create deterministic calculation modules.

Recommended modules:

```text
MoneyTree.Mortgages.Amortization
MoneyTree.Mortgages.RefinanceMath
MoneyTree.Mortgages.RefinanceAnalysis
MoneyTree.Mortgages.RefinanceWarnings
MoneyTree.Mortgages.FeeClassifier
```

### Required calculations

- monthly principal and interest payment
- amortization schedule
- remaining balance after N months
- total interest from now to payoff
- current-loan baseline schedule
- new-loan scenario schedule
- true closing costs
- prepaids and escrow deposits
- cash to close
- financed closing-cost impact
- points cost
- lender credit offset
- break-even months
- total interest saved over 5, 7, 10 years
- remaining-balance delta over 5, 7, 10 years
- lifetime interest delta
- payment delta
- optional APR estimate

### Required warnings

Generate deterministic warnings for cases such as:

- lower payment but higher lifetime interest
- break-even exceeds expected years in home
- closing costs are mostly financed
- monthly payment savings are driven by term reset
- PMI/MIP appears or increases
- escrow/prepaid amounts dominate cash to close but are not true costs
- current mortgage data is stale or low-confidence
- lender quote is expired or near expiration
- rate source is benchmark-only, not a guaranteed offer

## Rate-source strategy

### Phase 1 sources

Implement manual and benchmark sources first.

Recommended initial sources:

- manual rate entry
- FRED/Freddie Mac weekly average rates
- optional CSV import for rate observations

Reasoning: lender-specific quote APIs are likely to require approval, partner access, cost, or compliance review. RefiSignal should not depend on those in the MVP.

### Phase 2 sources

Add provider adapters once the core engine works.

Potential adapter categories:

- public benchmark API
- lender quote API
- aggregator API
- manually maintained lender quote
- uploaded Loan Estimate / quote document

Provider adapters should normalize to `mortgage_rate_observations` or `lender_quotes` and preserve the raw payload for auditability.

## Ollama extraction plan

### Worker boundary

Keep extraction behind a worker contract so the web app does not directly depend on Ollama availability.

Recommended flow:

```text
Upload -> mortgage_documents -> Oban DocumentExtractionWorker -> OCR/text extraction -> Ollama structured extraction -> mortgage_document_extractions -> user review -> confirmed update
```

### Prompt contract

Use strict JSON extraction prompts. The output should contain:

- document type
- extracted fields
- normalized values
- confidence per field
- source snippet per field
- page number or location when available
- warnings about missing/ambiguous data

Example field shape:

```json
{
  "current_interest_rate": {
    "value": "7.125",
    "unit": "percent",
    "confidence": 0.96,
    "source": "Page 2: Interest Rate 7.125%",
    "needs_review": false
  }
}
```

### Extraction targets

Initial fields:

- servicer name
- lender name
- current balance
- current interest rate
- monthly principal and interest
- monthly escrow
- total monthly payment
- PMI/MIP
- property tax escrow
- homeowners insurance escrow
- loan type
- loan term
- original loan amount
- origination date
- maturity date
- escrow shortage/surplus
- prepayment penalty language

Do not persist full loan numbers unless there is a specific encrypted field and a strong reason to store them.

## Frontend plan

### Add MoneyTree menu link

Update `MoneyTreeWeb.Layouts.app_nav_items/0`:

```elixir
%{label: "RefiSignal", path: ~p"/app/refisignal", page_title: "RefiSignal"}
```

Add a route in `router.ex`:

```elixir
live "/app/refisignal", RefiSignalLive.Index
live "/app/refisignal/:mortgage_id", RefiSignalLive.Show
```

If the first UI implementation stays in Next.js, route the canonical Phoenix destination to the proxied Next route consistently with the existing bridge approach.

### Recommended UI sections

Main RefiSignal page:

- mortgage selector
- current mortgage baseline card
- market rate watch card
- best current scenario card
- alert status card
- lender quote list
- document review queue
- recent analysis history

Mortgage-specific RefiSignal page:

- baseline summary
- scenario comparison table
- scenario detail drawer/page
- fee breakdown
- cash-to-close breakdown
- escrow/prepaid explanation
- interest-over-time comparison
- warnings and assumptions
- lender quote conversion
- alert rule editor

### Scenario comparison columns

- scenario name
- term
- rate
- APR
- points
- new payment
- monthly savings
- cash to close
- true cost
- break-even
- 5-year net
- 7-year net
- 10-year net
- lifetime interest delta
- warnings

### Standalone-ready UI strategy

Build the RefiSignal UI as a route group and reusable components instead of scattering logic through the MoneyTree dashboard.

Recommended Next layout:

```text
apps/next/app/refisignal/
  page.tsx
  [mortgageId]/page.tsx
  components/
    MortgageBaselineCard.tsx
    ScenarioComparisonTable.tsx
    FeeBreakdownCard.tsx
    CashToCloseCard.tsx
    RateWatchCard.tsx
    AlertRulesPanel.tsx
    DocumentReviewQueue.tsx
    LenderQuotesPanel.tsx
```

If implemented in Phoenix LiveView first, mirror the same component boundaries under:

```text
apps/money_tree/lib/money_tree_web/live/refi_signal_live/
  index.ex
  show.ex
  components.ex
```

## Notification and alert plan

Do not build a separate alerting subsystem.

Use Oban workers for evaluation and existing mail/notification infrastructure for delivery.

### Alert evaluation worker

`MoneyTree.Mortgages.Workers.AlertEvaluationWorker` should:

1. load active `refisignal_alert_rules`
2. refresh or use latest rate observations
3. run scenario analysis for the mortgage
4. compare results to thresholds
5. create notification events
6. send email or other enabled delivery channel
7. update `last_evaluated_at` and `last_triggered_at`

### Delivery channels

Phase 1:

- in-app notification event
- email via Swoosh

Phase 2:

- webhook
- ntfy
- Pushover
- Home Assistant webhook
- SMS only if explicitly added later

### Useful alert examples

- 30-year fixed benchmark falls below `6.25%`
- estimated break-even falls below `36 months`
- estimated monthly savings exceeds `$250`
- 15-year refinance payment is within `$300` of current payment
- lender quote expires within `7 days`
- uploaded document extraction needs review

## Security and privacy plan

Mortgage documents are sensitive financial records. Treat them like bank data.

Requirements:

- authenticate every API
- scope every query by `user_id`
- use encrypted or access-controlled file storage
- store document metadata separately from file bytes
- checksum uploads
- redact sensitive fields in logs
- do not log OCR text or LLM prompts by default
- never send documents to remote LLMs by default
- make Ollama/local extraction the default path
- store raw provider payloads only when they are not secret-bearing, or encrypt them if needed
- avoid storing full loan numbers unless explicitly required

## Implementation phases

### Phase 0: repo alignment and naming

Goal: make RefiSignal visible in the product without adding heavy behavior yet.

Tasks:

- add `RefiSignal` to `MoneyTreeWeb.Layouts.app_nav_items/0`
- add canonical `/app/refisignal` route
- create placeholder RefiSignal page using existing MoneyTree styling
- link to existing mortgage records from the placeholder page
- add route tests for the new destination

Acceptance criteria:

- authenticated user sees `RefiSignal` in the MoneyTree menu
- `/app/refisignal` loads without using demo language
- page has a clear empty state when no mortgage exists
- page links user to create or manage a mortgage

### Phase 1: deterministic refinance math

Goal: create the calculation foundation before document import or external APIs.

Tasks:

- implement amortization module
- implement refinance math module
- add unit tests for payment, interest, balance, and break-even calculations
- add fee classifier for true cost vs prepaid/escrow items
- add analysis result shape
- create seed/demo data for a realistic mortgage scenario

Acceptance criteria:

- calculations are covered by tests
- lower-payment-but-higher-interest scenario generates a warning
- financed-fee scenario shows different cash-to-close and lifetime interest results
- escrow/prepaids are separated from true closing costs

### Phase 2: scenario persistence and APIs

Goal: allow users to save and analyze refinance scenarios.

Tasks:

- add `refinance_scenarios` migration/schema
- add `refinance_fees` migration/schema
- add `refinance_results` migration/schema
- add context functions
- add controllers/routes
- update OpenAPI contracts
- generate/verify contract clients
- add controller tests

Acceptance criteria:

- user can create a scenario for their own mortgage
- user cannot access another user's scenario
- scenario analysis returns deterministic results
- result snapshot can be saved for alerting/history

### Phase 3: RefiSignal UI

Goal: make scenario analysis usable.

Tasks:

- build RefiSignal index page
- build mortgage-specific RefiSignal page
- add mortgage selector
- add scenario form
- add fee editor
- add scenario comparison table
- add detailed result view
- add warnings and assumptions panel

Acceptance criteria:

- user can create, edit, and analyze a scenario from the UI
- user can compare at least two scenarios
- UI distinguishes true closing costs from prepaids/escrow
- UI explains break-even and time-horizon comparisons clearly

### Phase 4: rate watch

Goal: import benchmark rates and use them in scenario generation.

Tasks:

- add `mortgage_rate_sources` migration/schema
- add `mortgage_rate_observations` migration/schema
- implement manual source
- implement first benchmark provider adapter
- add Oban import worker
- add rate observation list endpoint
- add UI card showing latest benchmark rate
- add ability to create a scenario from an observed benchmark rate

Acceptance criteria:

- rate observations can be imported repeatedly without duplicates
- UI shows source, product, rate, date, and assumptions
- scenario can be seeded from a rate observation
- stale provider data is visibly marked

### Phase 5: lender quotes

Goal: track specific offers separately from benchmark rates.

Tasks:

- add `lender_quotes` migration/schema
- add CRUD API
- add UI for manual quote entry
- add quote-to-scenario conversion
- add quote expiration tracking
- preserve raw payload field for future API integrations

Acceptance criteria:

- manual lender quote can be entered and compared
- expired quotes are visually marked
- quote can generate a scenario with fee assumptions

### Phase 6: alerts

Goal: notify the user when a refinance may be worth reviewing.

Tasks:

- add `refisignal_alert_rules` migration/schema
- add alert rule CRUD API
- add alert evaluation worker
- integrate with existing notification events
- send email for triggered alerts
- add UI alert editor

Acceptance criteria:

- user can create threshold-based alert rules
- worker evaluates rules against latest results
- user receives an email or in-app notification when a rule triggers
- duplicate noisy alerts are suppressed with cooldown logic

### Phase 7: document upload and extraction review

Goal: extract mortgage data from uploaded documents without trusting the LLM blindly.

Tasks:

- add `mortgage_documents` migration/schema
- add `mortgage_document_extractions` migration/schema
- add authenticated upload endpoint
- add file storage adapter
- add OCR/text extraction worker
- add Ollama extraction adapter
- add strict JSON prompt templates
- add review UI
- add confirm/reject endpoints
- update mortgage baseline only after confirmation

Acceptance criteria:

- user can upload a mortgage statement or closing disclosure
- extraction job produces candidate fields with confidence and snippets
- user can approve selected fields
- rejected extraction does not change mortgage data
- OCR/LLM text is not logged in normal logs

### Phase 8: standalone packaging

Goal: allow RefiSignal to run outside MoneyTree without rewriting the domain.

Tasks:

- identify shared RefiSignal UI route/components
- document required environment variables
- create standalone deployment notes
- isolate feature flags and config
- support standalone auth strategy or single-user mode
- support standalone database schema using the same migrations or a subset

Acceptance criteria:

- RefiSignal can be built as part of MoneyTree
- documented path exists to expose it as its own app
- domain modules do not assume a MoneyTree dashboard
- UI components avoid hard-coded MoneyTree-only links except in the integrated shell

## Testing plan

### Backend tests

Add tests for:

- amortization math
- refinance math
- fee classification
- scenario CRUD authorization
- scenario analysis
- rate import idempotency
- lender quote expiration
- alert evaluation and cooldown
- document extraction confirmation/rejection

### Frontend tests

Add tests for:

- menu contains RefiSignal
- RefiSignal empty state
- mortgage selector
- scenario form validation
- scenario comparison table
- fee breakdown display
- warnings display
- alert rule editor

### E2E tests

Add one happy-path Playwright test:

1. log in
2. open RefiSignal from menu
3. create/select mortgage
4. create refinance scenario
5. add fee items
6. run analysis
7. verify break-even and warning output appears

## Environment variables

Add only when needed.

Potential future variables:

```text
REFISIGNAL_ENABLED=true
REFISIGNAL_STANDALONE_MODE=false
REFISIGNAL_RATE_IMPORT_SCHEDULE="0 9 * * 1"
REFISIGNAL_ALERT_EVALUATION_SCHEDULE="0 10 * * *"
OLLAMA_BASE_URL=http://127.0.0.1:11434
OLLAMA_MORTGAGE_EXTRACTION_MODEL=qwen2.5:latest
MORTGAGE_DOCUMENT_STORAGE_PATH=/var/lib/moneytree/mortgage-documents
```

If OpenBao is used for secrets, document which provider API keys belong there instead of `.env`.

## Developer notes for Codex/agents

When implementing this plan:

1. Prefer small vertical slices.
2. Update contracts before frontend consumers.
3. Add migrations and run them locally.
4. Keep deterministic math isolated and heavily tested.
5. Do not let LLM extraction write directly to canonical mortgage records.
6. Do not create a second notification system.
7. Do not create a second mortgage baseline table.
8. Keep RefiSignal UI components portable enough for standalone mode.
9. Add menu and route tests when adding the navigation entry.
10. Run the existing checks described in `README.md` after each meaningful slice.

## Recommended first Codex task

Implement Phase 0 only:

- add `RefiSignal` to the app navigation
- add `/app/refisignal` route
- create a simple authenticated placeholder page
- show saved mortgages from the existing mortgage API/context if easy; otherwise show a static placeholder and link to mortgage management
- add route/navigation tests
- do not add refinance math yet

This gives the feature a visible product location without mixing UI work and financial math in the same first patch.
