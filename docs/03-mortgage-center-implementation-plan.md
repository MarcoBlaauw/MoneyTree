# Loan Center implementation plan

## Purpose and scope

Replace the earlier Mortgage Center-only direction with a broader **Loan Center** that defaults to mortgage loans first.

Loan Center should let a user manage loan records, import loan documents, compare refinance scenarios, and make better debt decisions using deterministic calculations, user-confirmed inputs, and optional AI-assisted extraction.

The first implementation should focus on mortgage refinance analysis because MoneyTree already has mortgage baseline records, escrow profile support, mortgage CRUD routes, and prior Mortgage Center planning. The architecture should still leave room for other loan types later, including auto loans, personal loans, student loans, HELOCs, and credit card balance-transfer style comparisons.

## Product goals

Loan Center should answer the questions users actually use when deciding whether to refinance:

1. **What will the new monthly payment likely be?**
2. **How long until the refinance breaks even?**
3. **What is the full-term finance cost for each scenario?**

Those three outputs must be first-class in the UI and API. Other details matter, but these are the core decision metrics.

Loan Center should also show:

- low / expected / high refinance cost ranges
- low / expected / high new monthly payment ranges
- full-term total payment and interest cost
- finance cost comparison against the current loan
- cash-to-close estimate
- true refinance cost versus escrow/prepaid timing costs
- lender fee and third-party fee breakdown
- escrow and prepaid assumptions
- PMI/MIP impact for mortgages
- break-even point by month and date
- 5-year, 7-year, 10-year, and full-term comparisons
- warnings when a lower payment is mostly caused by resetting the term
- alerts when rate or quote changes make a refinance worth reviewing

## Current repo fit

MoneyTree already has a good foundation for the first Loan Center slice:

- Phoenix backend contexts in `apps/money_tree/lib/money_tree`
- Phoenix JSON controllers and router in `apps/money_tree/lib/money_tree_web`
- additive Ecto migrations in `apps/money_tree/priv/repo/migrations`
- Next.js app UI in `apps/next/app`
- shared Tailwind/UI package in `apps/ui`
- API contracts in `apps/contracts`
- Oban background jobs
- Swoosh mail delivery
- notification/event infrastructure
- existing obligations domain
- existing mortgage context and mortgage CRUD API

Existing mortgage modules and APIs should be reused rather than replaced:

- `MoneyTree.Mortgages`
- `MoneyTree.Mortgages.Mortgage`
- `MoneyTree.Mortgages.EscrowProfile`
- `MoneyTreeWeb.MortgageController`
- `/api/mortgages`
- `/api/mortgages/:id`

## Naming and information architecture

### Product area

Use **Loan Center** as the top-level product area.

Initial user-facing navigation label:

- `Loan Center`

Initial default loan type:

- `Mortgage`

Recommended app navigation placement:

```text
Dashboard
Accounts
Transactions
Budgets
Obligations
Assets
Loan Center
Transfers
Settings
```

### Initial Loan Center sections

For the mortgage-first implementation:

```text
Loan Center
├── Overview
├── Current loans
├── Mortgage details
├── Documents
├── Refinance analysis
├── Rate watch
├── Lender quotes
├── Alerts
└── Analysis history
```

The UI may still use mortgage-specific labels inside mortgage screens, but the outer shell should be Loan Center so the future expansion path is obvious.

## Route structure

### Canonical Phoenix routes

Add canonical authenticated routes under `/app`:

- `/app/loans` -> Loan Center overview
- `/app/loans/:loan_id` -> loan detail
- `/app/loans/:loan_id/refinance` -> refinance analysis workspace
- `/app/loans/:loan_id/documents` -> document import/review workspace
- `/app/loans/:loan_id/quotes` -> lender quote workspace
- `/app/loans/:loan_id/alerts` -> loan/refinance alerts

### Mortgage compatibility routes

Existing mortgage routes and APIs should continue to work. If the UI already has mortgage routes, add redirects or compatibility links rather than breaking them.

Possible compatibility routes:

- `/app/mortgages` -> redirects to `/app/loans?type=mortgage`
- `/app/mortgages/:id` -> redirects to `/app/loans/:loan_id` if/when mortgage-to-loan mapping exists

### API route strategy

Use generic `/api/loans` routes for new Loan Center features where practical, but keep existing `/api/mortgages` routes for the current mortgage baseline.

Near-term API families:

- `/api/mortgages` for existing mortgage CRUD
- `/api/loans` for generic loan records once introduced
- `/api/loans/:loan_id/refinance_scenarios`
- `/api/refinance_scenarios/:id`
- `/api/refinance_scenarios/:id/analyze`
- `/api/loans/:loan_id/documents`
- `/api/loan_documents/:id/extract`
- `/api/loan_document_extractions/:id/confirm`
- `/api/loans/:loan_id/lender_quotes`
- `/api/loans/:loan_id/alert_rules`

For the first slice, mortgage records can act as the only loan source while the generic loan abstraction is introduced gradually.

## Core architecture principle

Keep these concerns separate:

- canonical loan/mortgage data
- imported document data
- extracted candidate data
- confirmed user data
- refinance assumptions
- fee assumptions
- analysis results
- alerts

Do not allow an uploaded document or LLM extraction to silently overwrite canonical loan records.

## Data input strategy

Loan Center must support data input that is separate from data already available in MoneyTree.

Input sources:

1. Existing MoneyTree data
   - mortgage records
   - obligations
   - connected accounts later
   - payment history later
2. Manual input
   - current loan details
   - lender quotes
   - fee estimates
   - refinance assumptions
3. Document upload
   - current mortgage papers
   - statements
   - closing disclosures
   - loan estimates
   - escrow statements
   - payoff quotes
   - screenshots or scanned PDFs
4. External rate sources
   - public benchmarks
   - API-driven rate sources if available
   - manual rate imports
5. Financial institution / lender quote sources later
   - lender APIs
   - aggregator APIs
   - uploaded quote documents

Every imported source should be traceable. The user should be able to see whether a value came from MoneyTree data, manual input, an uploaded document, an external benchmark, or a lender quote.

## Deterministic math, AI-assisted extraction

Ollama may be used for:

- classifying uploaded loan documents
- extracting candidate fields
- summarizing document findings
- explaining analysis results in plain language
- highlighting missing or suspicious assumptions

Ollama must not be used as the source of truth for financial calculations.

All payment, break-even, cost-range, and full-term cost calculations must be deterministic and covered by tests.

## Domain model direction

### Phase 1: Use existing mortgage records

The current `mortgages` table and `mortgage_escrow_profiles` table are enough to start mortgage refinance analysis.

Do not block the refinance feature on a broad loan migration.

### Phase 2: Introduce generic loan abstraction

Add a generic loan layer once the mortgage-first refinance flow is working.

Recommended future tables:

#### `loans`

Generic loan baseline.

Suggested fields:

- `id`
- `user_id`
- `loan_type`
- `nickname`
- `lender_name`
- `servicer_name`
- `account_reference_masked`
- `current_balance`
- `current_interest_rate`
- `rate_type`
- `original_loan_amount`
- `original_term_months`
- `remaining_term_months`
- `monthly_payment`
- `minimum_payment`
- `payment_frequency`
- `secured`
- `collateral_type`
- `status`
- `source`
- `last_reviewed_at`
- timestamps

Initial loan types:

- mortgage
- auto
- personal
- student
- heloc
- credit_card_balance_transfer
- other

#### `mortgage_loan_details`

Mortgage-specific extension when `loan_type = mortgage`.

Suggested fields:

- `loan_id`
- `mortgage_id` if mapping from existing mortgage record is used
- `property_name`
- `street_line_1`
- `street_line_2`
- `city`
- `state_region`
- `postal_code`
- `country_code`
- `occupancy_type`
- `home_value_estimate`
- `has_escrow`
- `escrow_included_in_payment`
- `pmi_mip_monthly`
- `hoa_monthly`
- `flood_insurance_monthly`
- timestamps

This avoids stuffing every future loan type into mortgage-only columns.

## Refinance scenario schema

Use generic refinance scenario records with mortgage-specific detail available where needed.

### `refinance_scenarios`

Suggested fields:

- `id`
- `user_id`
- `loan_id`
- `mortgage_id` nullable transitional field while mortgage records are the first supported loan source
- `name`
- `scenario_type`
- `target_loan_type`
- `product_type`
- `loan_type_detail`
- `new_term_months`
- `new_interest_rate`
- `new_apr`
- `new_principal_amount`
- `cash_out_amount`
- `cash_in_amount`
- `roll_costs_into_loan`
- `points`
- `lender_credit_amount`
- `expected_years_before_sale_or_refi`
- `closing_date_assumption`
- `rate_source_type`
- `rate_observation_id`
- `lender_quote_id`
- `status`
- timestamps

### `refinance_fee_items`

Line-item fees and cash-flow timing items.

Suggested fields:

- `id`
- `refinance_scenario_id`
- `category`
- `code`
- `name`
- `low_amount`
- `expected_amount`
- `high_amount`
- `fixed_amount`
- `percentage_of_loan_amount`
- `kind`
- `paid_at_closing`
- `financed`
- `is_true_cost`
- `is_prepaid_or_escrow`
- `required`
- `sort_order`
- `notes`
- timestamps

Each fee item should support ranges. If only one value is known, store it as expected amount and allow low/high to match expected.

Fee categories:

- origination
- points
- underwriting
- processing
- application
- appraisal
- credit_report
- flood_certification
- title_search
- title_insurance
- settlement_or_closing
- recording
- attorney_or_notary
- prepaid_interest
- escrow_deposit
- homeowners_insurance
- property_tax_escrow
- payoff_interest_adjustment
- release_fee
- prepayment_penalty
- lender_credit
- other

## Refinance analysis result schema

### `refinance_analysis_results`

Store analysis snapshots so alerts and historical comparisons are reproducible.

Suggested fields:

- `id`
- `user_id`
- `loan_id`
- `mortgage_id`
- `refinance_scenario_id`
- `analysis_version`
- `current_monthly_payment`
- `new_monthly_payment_low`
- `new_monthly_payment_expected`
- `new_monthly_payment_high`
- `monthly_savings_low`
- `monthly_savings_expected`
- `monthly_savings_high`
- `true_refinance_cost_low`
- `true_refinance_cost_expected`
- `true_refinance_cost_high`
- `cash_to_close_low`
- `cash_to_close_expected`
- `cash_to_close_high`
- `break_even_months_low`
- `break_even_months_expected`
- `break_even_months_high`
- `current_full_term_total_payment`
- `current_full_term_interest_cost`
- `new_full_term_total_payment_low`
- `new_full_term_total_payment_expected`
- `new_full_term_total_payment_high`
- `new_full_term_interest_cost_low`
- `new_full_term_interest_cost_expected`
- `new_full_term_interest_cost_high`
- `full_term_finance_cost_delta_low`
- `full_term_finance_cost_delta_expected`
- `full_term_finance_cost_delta_high`
- `five_year_net_delta`
- `seven_year_net_delta`
- `ten_year_net_delta`
- `warnings`
- `assumptions`
- `computed_at`
- timestamps

Important: full-term finance cost should be displayed for every scenario, not hidden behind advanced details.

## Cost range modeling

Loan Center should estimate three bands for refinance costs:

- optimistic / low
- expected / typical
- conservative / high

For mortgage refinance, separate:

### True refinance costs

These affect break-even:

- origination
- underwriting
- processing
- application
- points
- appraisal
- credit report
- title search
- title insurance
- settlement/closing
- recording
- attorney/notary
- flood certification
- release fee
- prepayment penalty

### Cash-flow timing costs

These affect cash to close but should not be treated as true refinance cost:

- prepaid interest
- initial escrow deposit
- homeowners insurance prepaid
- property tax escrow deposit
- payoff interest adjustment

### Offsets

These reduce net cash burden or net cost depending on type:

- lender credits
- expected old escrow refund
- waived fees
- seller/third-party credits if relevant

The UI should show:

```text
True refinance cost range
Cash to close range
Estimated old escrow refund
Net cash impact range
```

## Monthly payment range modeling

Loan Center should estimate three monthly payment bands:

- optimistic / low
- expected / typical
- conservative / high

For mortgage refinance, payment range should include:

- principal and interest
- escrow estimate
- PMI/MIP if applicable
- HOA if user chooses to include it
- flood insurance if applicable

UI should display:

```text
New principal & interest
Estimated escrow
PMI/MIP
Other monthly loan-adjacent costs
Estimated total monthly payment
```

Users should be able to toggle whether non-loan items like HOA are included in the displayed total.

## Full-term finance cost

Every refinance scenario must show full-term numbers:

- total payments over full new term
- total interest over full new term
- total true refinance costs
- total financed fees impact
- full-term finance cost
- comparison to current loan if kept to payoff

For decision-making, display both:

1. **Full-term cost**: what happens if this loan is kept to payoff.
2. **Expected horizon cost**: what happens if the user sells/refinances again after their expected horizon.

This avoids the common trap where a refinance looks good monthly but increases long-term cost.

## Break-even calculation

Break-even should support ranges:

- low-cost / high-savings break-even
- expected break-even
- high-cost / low-savings break-even

Break-even should be based on true refinance costs, not escrow/prepaid timing costs.

The UI should also show the break-even date based on the assumed closing date.

Example:

```text
Expected break-even: 34 months, around March 2029
Conservative break-even: 52 months, around September 2030
```

## Rate and quote inputs

### Rate observations

Rate observations are market or benchmark rates. They are useful for trend watch and rough scenario generation, but they are not guaranteed offers.

Suggested tables:

#### `loan_rate_sources`

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

#### `loan_rate_observations`

- `id`
- `rate_source_id`
- `provider_key`
- `series_key`
- `loan_type`
- `product_type`
- `term_months`
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

Initial source types:

- manual
- public_benchmark
- csv_import
- lender_api later
- aggregator_api later

### Lender quotes

Lender quotes are more specific than rate observations and should be stored separately.

#### `loan_lender_quotes`

Suggested fields:

- `id`
- `user_id`
- `loan_id`
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
- `estimated_closing_costs_low`
- `estimated_closing_costs_expected`
- `estimated_closing_costs_high`
- `estimated_cash_to_close_low`
- `estimated_cash_to_close_expected`
- `estimated_cash_to_close_high`
- `estimated_monthly_payment_low`
- `estimated_monthly_payment_expected`
- `estimated_monthly_payment_high`
- `lock_available`
- `lock_expires_at`
- `quote_expires_at`
- `raw_payload`
- `status`
- timestamps

## Document import and extraction

### `loan_documents`

Suggested fields:

- `id`
- `user_id`
- `loan_id`
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
- auto_loan_statement
- student_loan_statement
- personal_loan_statement
- credit_card_statement
- other

### `loan_document_extractions`

Suggested fields:

- `id`
- `user_id`
- `loan_id`
- `mortgage_id`
- `loan_document_id`
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

Workflow:

1. User uploads document.
2. Store original document metadata and file.
3. Enqueue Oban extraction job.
4. Extract text/OCR.
5. Use Ollama to extract structured candidate fields.
6. Store candidate fields with confidence and source snippets.
7. User reviews and confirms selected values.
8. Confirmed values update loan/mortgage records, lender quotes, or scenario assumptions.

## Alert rules

### `loan_alert_rules`

Suggested fields:

- `id`
- `user_id`
- `loan_id`
- `mortgage_id`
- `name`
- `kind`
- `active`
- `threshold_config`
- `delivery_preferences`
- `last_evaluated_at`
- `last_triggered_at`
- timestamps

Initial alert kinds:

- `rate_below_threshold`
- `monthly_payment_below_threshold`
- `monthly_savings_above_threshold`
- `break_even_below_months`
- `full_term_cost_savings_above_threshold`
- `expected_horizon_savings_above_threshold`
- `lender_quote_expiring`
- `document_review_needed`

Use existing MoneyTree notifications and Swoosh delivery. Do not create a parallel alert delivery system.

## Backend module plan

Recommended modules:

```text
MoneyTree.Loans
MoneyTree.Loans.Loan
MoneyTree.Loans.RefinanceScenario
MoneyTree.Loans.RefinanceFeeItem
MoneyTree.Loans.RefinanceAnalysisResult
MoneyTree.Loans.RateSource
MoneyTree.Loans.RateObservation
MoneyTree.Loans.LenderQuote
MoneyTree.Loans.LoanDocument
MoneyTree.Loans.DocumentExtraction
MoneyTree.Loans.AlertRule
MoneyTree.Loans.Amortization
MoneyTree.Loans.RefinanceCalculator
MoneyTree.Loans.CostRangeEstimator
MoneyTree.Loans.PaymentRangeEstimator
MoneyTree.Loans.WarningEngine
MoneyTree.Loans.Workers.RateImportWorker
MoneyTree.Loans.Workers.DocumentExtractionWorker
MoneyTree.Loans.Workers.AlertEvaluationWorker
```

Mortgage-specific support can remain under `MoneyTree.Mortgages`, but generic refinance math should live under `MoneyTree.Loans`.

## Frontend plan

### Phase 1 Loan Center overview

Route:

- `/app/loans`

Contents:

- mortgage-first empty state
- list existing mortgages as loan cards
- CTA to add/import a mortgage
- CTA to start refinance analysis
- basic explanation that Loan Center starts with mortgages and will support other loans later

### Mortgage loan detail

Route:

- `/app/loans/:loan_id`

Contents:

- loan baseline summary
- current balance
- current rate
- remaining term
- current monthly payment
- escrow/mortgage-specific details when applicable
- linked obligation if present
- document review queue
- latest analysis summary

### Refinance analysis workspace

Route:

- `/app/loans/:loan_id/refinance`

Core UI outputs:

1. New monthly payment range
2. Break-even range
3. Full-term finance cost comparison

Secondary UI outputs:

- cost range
- cash to close range
- escrow/prepaid breakdown
- true cost breakdown
- interest comparison
- expected-horizon comparison
- assumptions
- warnings

### Scenario comparison table

Columns:

- scenario name
- term
- rate
- APR
- points
- expected monthly payment
- expected monthly savings
- expected true refinance cost
- expected cash to close
- expected break-even
- full-term total cost
- full-term savings/cost increase
- 5-year net
- 7-year net
- 10-year net
- warnings

## API contract plan

Update `apps/contracts/specs/openapi.yaml` before wiring frontend consumers.

Add schemas for:

- `Loan`
- `LoanDetail`
- `RefinanceScenario`
- `CreateRefinanceScenarioRequest`
- `UpdateRefinanceScenarioRequest`
- `RefinanceFeeItem`
- `RefinanceAnalysisResult`
- `PaymentRange`
- `CostRange`
- `BreakEvenRange`
- `FullTermCostComparison`
- `LoanRateSource`
- `LoanRateObservation`
- `LoanLenderQuote`
- `LoanDocument`
- `LoanDocumentExtraction`
- `LoanAlertRule`

Decimal values should remain string-encoded to match existing contract patterns.

## Implementation phases

### Current implementation status

| Phase | Status | Notes |
| --- | --- | --- |
| Phase 0: Loan Center destination | Done | Loan Center navigation, canonical `/app/loans` routes, mortgage compatibility routes, and mortgage-backed overview are in place. |
| Phase 1: Refinance math foundation | Done | Deterministic amortization, refinance comparisons, warnings, and payoff what-if calculations are implemented with focused tests. |
| Phase 2: Scenario persistence and API | Done | Refinance scenarios, fee items, analysis snapshots, context functions, controller routes, contracts, and authorization coverage are implemented. |
| Phase 3: Refinance UI | Partial | Scenario, fee, comparison, benchmark, lender quote bridge, loan tabs, the ephemeral what-if sandbox, a selected-scenario analysis detail panel, labeled range presentation, highlighted decision metrics, warning callouts, progressive disclosure for refinance forms, percentage-based scenario rate inputs, and mortgage-seeded scenario defaults are implemented. Broader UI/UX cleanup remains. |
| Phase 4: Documents and Ollama extraction | Partial | Document metadata, uploads, extraction candidates, stored text/PDF/image OCR extraction artifacts, row-level extraction triggers, extracted-text review context, Ollama/manual extraction, review, and confirmation flows exist. OCR depth and review ergonomics still need refinement. |
| Phase 5: Rates and lender quotes | Partial | Manual benchmark rates, configurable benchmark import worker, lender quote tracking, deterministic quote expiration refresh, and quote-to-scenario conversion exist. External benchmark provider integration and quote freshness polish remain. |
| Phase 6: Alerts | Partial | Alert rule UI, evaluation worker, durable notification delivery integration, and per-rule cooldown anti-noise behavior exist. Email delivery uses existing notification infrastructure. Broader alert polish and scheduled evaluation cadence remain. |
| Phase 7: Expand beyond mortgages | Pending | Mortgage-backed loans remain the only implemented loan type. |

### Phase 0: Rename product direction and add Loan Center destination

Tasks:

- update docs from Mortgage Center to Loan Center framing
- add `Loan Center` to `MoneyTreeWeb.Layouts.app_nav_items/0`
- add `/app/loans` route
- create authenticated placeholder/overview page
- show existing mortgage records as the first loan type if practical
- add route/navigation tests

Acceptance criteria:

- authenticated users can open Loan Center from the app menu
- page clearly says mortgage loans are supported first
- existing mortgage records are not duplicated

### Phase 1: Refinance math foundation

Tasks:

- implement amortization calculations
- implement full-term cost calculations
- implement payment range calculations
- implement cost range calculations
- implement break-even range calculations
- implement warning engine
- add unit tests with realistic mortgage examples

Acceptance criteria:

- every scenario returns monthly payment, break-even, and full-term cost
- true refinance cost is separated from cash-to-close timing costs
- lower payment but higher full-term cost generates a warning

### Phase 2: Scenario persistence and API

Tasks:

- add refinance scenario tables
- add fee item tables
- add analysis result snapshot table
- add context functions
- add API controllers/routes
- update OpenAPI contracts
- add controller tests and authorization tests

Acceptance criteria:

- user can save multiple refinance scenarios for a mortgage-backed loan
- scenario analysis is reproducible from stored assumptions
- users cannot access another user's loan scenarios

### Phase 3: Refinance UI

Tasks:

- build scenario form
- build fee/cost editor
- build scenario comparison table
- build ephemeral what-if sandbox sliders for rate, term, and extra monthly principal
- build analysis detail page/drawer
- highlight monthly payment, break-even, and full-term cost
- add assumptions and warnings panel
- continue Loan Center UI/UX cleanup after the backend workflow is complete

Acceptance criteria:

- user can compare at least two scenarios
- user can adjust rate, term, and extra principal without persisting a scenario
- UI shows low/expected/high ranges
- full-term cost is visible without opening advanced settings

### Phase 4: Documents and Ollama extraction

Tasks:

- add loan document tables
- add extraction review tables
- add upload endpoint
- add OCR/text extraction worker
- add Ollama extraction adapter
- add review/confirm UI
- update canonical records only after confirmation

Acceptance criteria:

- user can upload current mortgage papers
- extracted fields show confidence and source snippets
- user confirmation controls persistence

### Phase 5: Rates and lender quotes

Tasks:

- add rate source and observation tables
- add manual rate source
- add benchmark import worker
- add lender quote table/API
- add manual lender quote UI
- convert quote to scenario

Acceptance criteria:

- benchmark rates can seed scenarios but are labeled as estimates
- lender quotes are tracked separately from benchmark rates
- quote expiration is visible

### Phase 6: Alerts

Tasks:

- add loan alert rules
- add alert evaluation worker
- integrate with existing notification events
- send email alerts via existing mailer
- add alert editor UI

Acceptance criteria:

- user can create alerts for rate, payment, break-even, and full-term cost thresholds
- alerts are not noisy or duplicated
- delivery uses existing notification infrastructure

### Phase 7: Expand beyond mortgages

Tasks:

- introduce generic `loans` table if not already done
- add non-mortgage loan types
- add auto/personal/student loan input forms
- add non-mortgage refinance scenario templates
- keep mortgage-specific escrow/PMI logic isolated

Acceptance criteria:

- at least one non-mortgage loan type can use the same refinance engine
- mortgage-specific fields do not leak into non-mortgage flows

## Testing requirements

### Backend

Test:

- amortization schedule
- monthly payment range
- cost range
- break-even range
- full-term cost comparison
- scenario CRUD authorization
- fee classification
- document extraction confirmation
- alert evaluation thresholds

### Frontend

Test:

- Loan Center navigation
- mortgage-first empty state
- scenario form validation
- scenario comparison table
- full-term cost visibility
- warnings panel
- document review flow
- alert rule form

### End-to-end

Add one happy-path flow:

1. log in
2. open Loan Center
3. select or create mortgage loan
4. create refinance scenario
5. add fee assumptions
6. run analysis
7. verify monthly payment, break-even, and full-term cost appear

## Developer notes for Codex/agents

- Start with mortgage loans because the repo already has mortgage data.
- Do not duplicate mortgage records.
- Do not let LLM extraction directly update canonical loan data.
- Keep calculations deterministic and tested.
- Keep full-term finance cost as a first-class output.
- Keep monthly payment, break-even, and full-term cost visible in the UI.
- Use existing Oban, Swoosh, notification, contract, and app-shell patterns.
- Prefer small vertical slices over large rewrites.
- Run migrations against the local dev database after adding schemas.
- Run the relevant checks from `README.md` before committing implementation work.
