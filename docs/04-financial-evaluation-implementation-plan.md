# Financial Evaluation Implementation Plan

## Purpose

This document is a planning artifact for extending the existing MoneyTree monorepo with financial evaluation features.

It is written against the current codebase and follows the repo's `AGENTS.md` guidance:

- extend existing modules where possible
- keep schema changes additive
- keep deterministic finance logic in backend code
- keep AI-assisted extraction separate from persistence
- avoid duplicating logic across Phoenix and Next

This is not a greenfield design. It is an execution-oriented plan for the current repo shape.

## Assumptions

- `apps/money_tree` remains the source of truth for persistence, calculations, orchestration, and authenticated APIs.
- `apps/next` remains the place for richer multi-step authenticated workflows that are already routed through Phoenix proxying.
- `apps/contracts` should become the source of truth for any new REST response/request shapes consumed by Next.
- Existing account aggregation remains account-centric. New mortgage, insurance, and vehicle evaluation data will initially be curated by the user or imported from documents rather than inferred automatically from bank sync alone.

## 1. Codebase Inspection

### Backend contexts and boundaries

Current backend contexts under `apps/money_tree/lib/money_tree` are already split by domain:

- `MoneyTree.Accounts` owns users, sessions, account access, account summaries, net worth rollups, and user settings.
- `MoneyTree.Institutions` owns institution connections, sync state, and connection lifecycle.
- `MoneyTree.Transactions` owns transaction queries, pagination, category rollups, and subscription spend summaries.
- `MoneyTree.Assets` owns tangible asset CRUD and asset dashboard summaries.
- `MoneyTree.Budgets` owns budget state and planner logic.
- `MoneyTree.Recurring` owns recurring-series detection and anomaly recording.
- `MoneyTree.Obligations` owns recurring payment obligations plus daily due-state evaluation.
- `MoneyTree.Notifications` owns durable notification events, alert preferences, and delivery orchestration.
- `MoneyTree.Loans` currently provides dashboard-only derived loan summaries from account data. It is not yet a persisted loan domain.

The strongest reuse points for the requested work are:

- `MoneyTree.Assets` for property and vehicle anchors
- `MoneyTree.Obligations` for bills, due dates, and renewal alerts
- `MoneyTree.Notifications` for durable alert/event delivery
- `MoneyTree.Accounts` for net-worth, liabilities, and financial-profile-adjacent user/account data
- `MoneyTree.Recurring` and `MoneyTree.Obligations.Evaluator` as existing examples of deterministic evaluators plus worker-driven checks

### Schemas, changesets, and query patterns

The repo consistently uses:

- binary IDs
- additive Ecto schemas per domain
- context functions that normalize attrs and enforce access
- changesets with explicit validation and `foreign_key_constraint/1`
- query helpers scoped through user/account access checks

Relevant current schemas:

- `MoneyTree.Users.User` stores auth identity plus encrypted full name
- `MoneyTree.Accounts.Account` stores synced/manual financial account balances and metadata such as `apr`, `fee_schedule`, `minimum_balance`, `maximum_balance`
- `MoneyTree.Transactions.Transaction` stores transaction-level categorization metadata and encrypted metadata
- `MoneyTree.Assets.Asset` stores tangible asset records and `document_refs`
- `MoneyTree.Obligations.Obligation` stores recurring bill/payment metadata and per-obligation alert overrides
- `MoneyTree.Notifications.Event` stores durable dashboard and delivery events
- `MoneyTree.Recurring.Series` and `MoneyTree.Recurring.Anomaly` store anomaly-oriented derived data

Important pattern: derived or operational signals already live in dedicated tables instead of being stuffed into user/account rows. That supports adding evaluation results and import drafts as separate persisted records.

### Existing business logic and services

Relevant existing deterministic logic:

- `MoneyTree.Accounts.net_worth_snapshot/2`
- `MoneyTree.Accounts.running_card_balances/2`
- `MoneyTree.Transactions.subscription_spend/2`
- `MoneyTree.Recurring.detect_for_user/2`
- `MoneyTree.Obligations.Evaluator.evaluate/2`
- `MoneyTree.Notifications.pending/2`

Relevant current gap:

- `MoneyTree.Loans` is present, but it is dashboard formatting logic built from account balances and rough heuristics. It should not be reused as the core evaluation engine for mortgage or vehicle analysis without being tightened or split.

### Jobs and background processing

Background work already exists and uses Oban:

- `MoneyTree.Obligations.CheckWorker`
- `MoneyTree.Recurring.DetectorWorker`
- sync workers for Teller/Plaid
- notification delivery worker(s)

This is a strong fit for:

- daily or scheduled status checks
- benchmark/rate snapshot refreshes
- asynchronous document extraction after upload
- stale-data and renewal alert generation

### Existing evaluation or rules logic

There is already a code pattern for explainable, deterministic evaluation:

- obligations compute due state from stored rules and transactions
- recurring detection computes confidence from repeat intervals and amount windows
- notifications materialize durable events from evaluation outcomes

That pattern should be reused for mortgage/refinance, insurance renewal, vehicle finance, and data-quality status checks.

### Web layer usage patterns

The Phoenix web layer currently splits responsibilities as follows:

- JSON controllers for authenticated APIs under `/api`
- LiveViews for financial-product CRUD, overviews, and internal app pages under `/app/*`
- Phoenix session/auth and security flows in controllers and server-rendered templates

Current LiveView-heavy product areas:

- dashboard
- accounts/institutions
- transactions
- obligations
- assets
- budgets
- settings

Current controller-backed JSON APIs used by Next:

- `/api/accounts`
- `/api/obligations`
- `/api/settings`
- auth, KYC, bank-link, and owner APIs

### Interactive flow patterns

Interactive flows currently live in two places:

- Phoenix LiveView for first-party financial management pages and simple forms
- Next.js for richer multi-step experiences and specialized flows such as control panel, link-bank, verify-identity, and owner users

That is the clearest precedent for placing a document-review wizard and evaluation detail screens in Next while keeping persistence and calculations in Phoenix.

### Next.js structure and fetching patterns

`apps/next/app` currently uses the app router with server-rendered pages and `app/lib/*` helpers.

Current patterns:

- route entry file delegates to a render helper
- server components call `fetchWithSession()` to proxy through Phoenix with the current cookie and CSRF token
- `app/lib/*` contains response-shape normalization for Phoenix JSON endpoints
- page-level components are split between server renderers and client components when forms/widgets are needed

Important constraint:

- Next currently defines local TS types manually for API payloads instead of using generated contract types. New work should not make that inconsistency worse.

### Contracts layer

`apps/contracts` exists but is still minimal:

- source specs live in `apps/contracts/specs`
- generated TypeScript outputs live in `apps/contracts/src/generated`
- OpenAPI generation and verification are already wired in package scripts

Current gap:

- the contract package does not yet describe the authenticated APIs that Next already consumes, beyond a basic health endpoint

For the new features, this package should become the formal source of truth rather than leaving new endpoints as undocumented ad hoc JSON.

### Data layer

Current first-class persisted domains:

- users: `users`
- accounts: `accounts`
- transactions: `transactions`
- institution connections: `institution_connections`
- assets: `assets`
- budgets: `budgets`, `budget_revisions`
- recurring detection: `recurring_series`, `recurring_anomalies`
- obligations and bills/reminders: `obligations`
- alerts/reminders: `alert_preferences`, `notification_events`, `notification_delivery_attempts`

Important gaps relative to requested scope:

- no first-class mortgage detail table
- no first-class rent detail table
- no first-class vehicle finance detail table
- no first-class insurance policy table
- no first-class document/file/import table
- no first-class evaluation result table
- no first-class benchmark/rate snapshot table
- no dedicated liabilities table; liabilities are currently inferred mainly from account types/subtypes and obligations

### Existing capabilities

What exists:

- authenticated APIs
- durable alerting
- background jobs
- dashboard aggregation logic
- account aggregation and transaction sync
- document reference fields on assets only
- KYC-related redaction example in `MoneyTreeWeb.KycController`

What does not exist yet:

- file upload persistence pipeline
- OCR
- PDF/screenshot classification
- LLM extraction orchestration
- review/confirm import workflow
- mortgage/refinance benchmark ingestion
- structured financial evaluation engine outside obligations/recurring

## 2. Architecture Fit

### Context ownership

Recommended ownership in the current codebase:

- `MoneyTree.Assets`
  - own property and vehicle asset anchors
  - own additive property/vehicle detail records when they attach directly to a tracked asset
- `MoneyTree.Obligations`
  - continue owning recurring bill semantics, due dates, renewal reminders, and policy-payment reminders
  - own insurance renewal and payment reminder records when they behave like obligations
- `MoneyTree.Notifications`
  - continue owning durable event persistence and delivery
  - extend event kinds and statuses for evaluation and stale-data alerts
- `MoneyTree.Accounts`
  - remain the source of user/account summaries, liability rollups, and user-level profile access
  - absorb only narrow user-level financial profile fields that are clearly profile-like and not tied to a single mortgage/vehicle/policy record
- `MoneyTree.Evaluations` as a new context
  - own deterministic mortgage, refinance, insurance, vehicle, and status-check calculations
  - own benchmark/rate snapshots and persisted evaluation results
- `MoneyTree.Imports` as a new context
  - own uploaded files, extraction jobs, extraction results, review state, and confirmation flow

### Why two new contexts are justified

`MoneyTree.Loans` is currently too presentation-oriented to become the system of record for persisted mortgage/vehicle evaluation. `MoneyTree.Assets` and `MoneyTree.Obligations` are good anchors for subject records, but neither is a good home for document-import orchestration or cross-domain evaluation snapshots.

Adding these two bounded contexts is still incremental:

- `MoneyTree.Evaluations` prevents mortgage/vehicle/insurance calculation code from leaking into `Accounts`, `Assets`, or controllers
- `MoneyTree.Imports` prevents upload, extraction, and review lifecycle code from contaminating domain contexts

### Where logic should live

- deterministic formulas, eligibility rules, missing-data checks, stale-data checks
  - `apps/money_tree/lib/money_tree/evaluations/*`
- record CRUD and query APIs for the new subject tables
  - existing contexts when the subject belongs there
- orchestration that combines uploads, extraction runs, review state, and confirmation
  - `apps/money_tree/lib/money_tree/imports/*`
- scheduled checks and benchmark refreshes
  - Oban workers under `evaluations` and `imports`
- JSON shaping for Next
  - Phoenix controllers
- simple in-app summaries and compact CRUD
  - LiveView
- richer multi-step review and evaluation detail flows
  - Next pages backed by Phoenix APIs

### Avoiding Phoenix/Next logic duplication

Rules:

- all formulas and eligibility logic must live in Elixir context/service modules
- Next should only render results returned by Phoenix and submit edits/review decisions
- Next can do display formatting and client-side form state, but not authoritative calculations
- if a status or recommendation appears in both LiveView and Next, it should come from the same Phoenix serializer shape or the same context function

## 3. Gap Analysis

### Reusable existing pieces

- account/liability rollups in `MoneyTree.Accounts`
- obligation due-state checks in `MoneyTree.Obligations.Evaluator`
- durable alerts in `MoneyTree.Notifications`
- recurring anomaly patterns in `MoneyTree.Recurring`
- account metadata support for APR and balance constraints
- asset CRUD and document reference handling in `MoneyTree.Assets`
- authenticated Next proxy and session fetch helpers
- Oban scheduling and reporting queue usage

### Missing pieces

- structured mortgage, rent, vehicle finance, and insurance persistence
- evaluation result persistence and history
- benchmark/rate snapshot persistence
- file upload and extraction lifecycle
- review-first import flow
- contracts for new financial APIs
- Next views for evaluation and import review
- dashboard cards and badges for these new domains

### Refactoring required

Minimal refactoring that is worth doing:

- treat `MoneyTree.Loans` as presentation-only and avoid building new persisted domain behavior into it
- expand `MoneyTree.Notifications.Event` allowed `kind` and `status` values to support more than payment obligations
- formalize Phoenix JSON contract shapes before adding many new Next fetch helpers

### What should be deferred

Post-MVP items to defer:

- automatic lender- or insurer-specific optimization recommendations beyond basic deterministic rules
- multi-document merging into a single canonical record without explicit user confirmation
- historical trend charts for evaluation results
- OCR provider swapping abstractions beyond one configured adapter
- full asset valuation history
- broad replacement of all existing ad hoc Next types with generated contract types

## 4. Data Model Plan

### Guiding rule

Do not create one giant financial profile row. Use additive, narrow records attached to existing anchors.

### Proposed additive tables

#### `mortgage_profiles`

Purpose:

- stores user-reviewed mortgage details for a home loan evaluation subject

Relationships:

- `belongs_to :user`
- `belongs_to :account` for synced loan balance account when present
- `belongs_to :asset` for the associated property asset when present
- `belongs_to :obligation` for payment schedule linkage when present

Suggested fields:

- `loan_name`
- `servicer_name`
- `property_use`
- `occupancy_type`
- `original_principal_amount`
- `current_principal_balance`
- `interest_rate`
- `interest_rate_type`
- `term_months`
- `remaining_term_months`
- `monthly_principal_interest`
- `monthly_escrow`
- `monthly_total_payment`
- `origination_date`
- `maturity_date`
- `home_value_amount`
- `home_value_currency`
- `purchase_price_amount`
- `purchase_price_currency`
- `pmi_amount`
- `pmi_end_ltv_threshold`
- `last_rate_reviewed_at`
- `last_balance_reviewed_at`
- metadata fields:
  - `source`
  - `source_confidence`
  - `verification_state`
  - `last_reviewed_at`
  - `source_payload`

#### `rent_profiles`

Purpose:

- supports renter evaluation and insurance/budget/status checks without forcing mortgage ownership

Relationships:

- `belongs_to :user`
- `belongs_to :obligation` when rent is modeled as a recurring payment obligation

Suggested fields:

- `housing_status`
- `monthly_rent_amount`
- `currency`
- `lease_start_on`
- `lease_end_on`
- `renewal_notice_days`
- `landlord_name`
- metadata fields:
  - `source`
  - `source_confidence`
  - `verification_state`
  - `last_reviewed_at`
  - `source_payload`

#### `vehicle_finance_profiles`

Purpose:

- supports car loan and lease evaluation

Relationships:

- `belongs_to :user`
- `belongs_to :asset` for the vehicle asset when present
- `belongs_to :account` for synced loan/lease account when present
- `belongs_to :obligation` for recurring payment linkage when present

Suggested fields:

- `finance_type` with values like `loan` and `lease`
- `lender_name`
- `vehicle_label`
- `vin_last4`
- `original_amount`
- `current_balance`
- `interest_rate`
- `monthly_payment_amount`
- `term_months`
- `remaining_term_months`
- `lease_maturity_on`
- `residual_value_amount`
- `mileage_limit_annual`
- `current_odometer`
- `excess_mileage_fee_per_unit`
- `vehicle_value_amount`
- `currency`
- metadata fields:
  - `source`
  - `source_confidence`
  - `verification_state`
  - `last_reviewed_at`
  - `source_payload`

#### `insurance_policies`

Purpose:

- supports home, renters, auto, umbrella, and similar evaluation tools

Relationships:

- `belongs_to :user`
- `belongs_to :asset` when policy is tied to a property or vehicle
- `belongs_to :obligation` when a recurring payment reminder exists

Suggested fields:

- `policy_type`
- `carrier_name`
- `policy_number_last4`
- `coverage_start_on`
- `coverage_end_on`
- `renewal_date`
- `premium_amount`
- `premium_period`
- `deductible_amount`
- `liability_limit_amount`
- `dwelling_coverage_amount`
- `personal_property_coverage_amount`
- `vehicle_collision_deductible_amount`
- `vehicle_comprehensive_deductible_amount`
- `currency`
- metadata fields:
  - `source`
  - `source_confidence`
  - `verification_state`
  - `last_reviewed_at`
  - `source_payload`

#### `financial_profile_facts`

Purpose:

- stores narrow user-level facts that do not belong to a single mortgage/vehicle/policy record

Relationships:

- `belongs_to :user`

Suggested fields:

- `fact_key`
- `fact_value_string`
- `fact_value_decimal`
- `fact_value_date`
- metadata fields:
  - `source`
  - `source_confidence`
  - `verification_state`
  - `last_reviewed_at`

Use cases:

- annual household income
- filing status
- credit score band
- state/zip for benchmark relevance
- homeownership intent or refinance intent

This avoids a monolithic profile table while still giving evaluations access to structured profile inputs.

#### `evaluation_results`

Purpose:

- stores deterministic evaluation outputs and status checks for later display and alerting

Relationships:

- `belongs_to :user`
- nullable links to the primary subject:
  - `mortgage_profile_id`
  - `vehicle_finance_profile_id`
  - `insurance_policy_id`
  - `rent_profile_id`

Suggested fields:

- `evaluation_type`
- `subject_type`
- `status`
- `summary`
- `confidence_score`
- `missing_fields`
- `stale_fields`
- `computed_facts`
- `recommendations`
- `benchmark_snapshot_id`
- `computed_at`
- `expires_at`

#### `benchmark_rate_snapshots`

Purpose:

- stores fetched rate and benchmark data used by deterministic evaluators

Relationships:

- no direct domain ownership beyond evaluation references

Suggested fields:

- `benchmark_type`
- `market_scope`
- `rate_value`
- `apr_value`
- `term_months`
- `effective_on`
- `fetched_at`
- `source_name`
- `source_url`
- `raw_payload`

#### `import_documents`

Purpose:

- stores uploaded file metadata independently of extraction and persistence

Relationships:

- `belongs_to :user`

Suggested fields:

- `storage_key`
- `original_filename`
- `content_type`
- `byte_size`
- `checksum`
- `upload_status`
- `classification_status`
- `review_status`
- `captured_at`

#### `import_extractions`

Purpose:

- stores extraction attempts and structured draft payloads

Relationships:

- `belongs_to :document, import_document`
- `belongs_to :user`

Suggested fields:

- `extractor`
- `model_name`
- `status`
- `document_type`
- `confidence_score`
- `draft_payload`
- `field_confidences`
- `review_notes`
- `confirmed_at`
- `discarded_at`

### Verification metadata storage

Use the same metadata vocabulary across the new persisted records:

- `source`
- `source_confidence`
- `verification_state`
  - suggested values: `draft`, `user_confirmed`, `synced`, `needs_review`, `superseded`
- `last_reviewed_at`

This should be stored directly on the domain table for the current active record, not only on the import tables. The import tables should also preserve the original extraction payload and field confidence map.

## 5. Status / Evaluation Engine

### Recommended module layout

Under `apps/money_tree/lib/money_tree/evaluations`:

- `MoneyTree.Evaluations`
- `MoneyTree.Evaluations.Result`
- `MoneyTree.Evaluations.BenchmarkRateSnapshot`
- `MoneyTree.Evaluations.MortgageEvaluator`
- `MoneyTree.Evaluations.VehicleEvaluator`
- `MoneyTree.Evaluations.InsuranceEvaluator`
- `MoneyTree.Evaluations.StatusChecker`
- `MoneyTree.Evaluations.BenchmarkFetcher`
- worker modules for scheduled refresh and recheck

### Supported deterministic checks

#### Mortgage/refinance

- refinance candidate detection
  - compare reviewed current rate against recent benchmark snapshot plus configurable spread threshold
- break-even months
  - closing-cost estimate divided by monthly payment savings
- PMI removal eligibility
  - use reviewed current balance and reviewed home value to calculate LTV
- overpayment detection
  - detect reviewed monthly payment materially above scheduled minimum with no explicit user intent flag
- missing data detection
  - rate, current balance, home value, term, payment, and closing cost assumptions missing
- stale data detection
  - home value or balance review date older than threshold

#### Insurance

- renewal upcoming
- premium increase check when previous premium exists
- deductible mismatch check against user-stored preference facts
- missing coverage fields
- stale policy review check

#### Vehicle loan / lease

- loan payoff horizon sanity check
- rate competitiveness vs benchmark if available
- lease end approaching
- excess mileage risk when odometer plus annualized usage exceed limit
- missing data and stale data checks

### Confidence scoring

Confidence should be deterministic and transparent.

Recommended model:

- start from `1.0`
- reduce score for each required missing field
- reduce score for stale fields
- reduce score when benchmark freshness is poor
- never increase confidence based on LLM output alone

Store component reasons in `missing_fields` and `stale_fields`, not only one opaque score.

### Trigger strategy

Synchronous:

- run evaluation immediately after user confirms edited mortgage/vehicle/insurance data
- run evaluation when a benchmark snapshot is manually refreshed for a viewed subject

Background:

- daily benchmark refresh
- daily status checker for stale data, renewal windows, lease end windows, PMI checks, and refinance candidate reevaluation
- on import confirmation, enqueue a post-confirm recompute instead of doing all work inline

### Storage model

Recommended approach:

- persist latest evaluation result rows in `evaluation_results`
- optionally replace prior result for the same subject/evaluation type while also keeping enough timestamps for freshness
- emit durable `notification_events` only when a state transition is important

This mirrors the obligations pattern:

- evaluator computes
- durable event layer decides whether to surface and deliver

## 6. Document Import Pipeline

### Required flow

upload -> extract -> classify -> structure -> confidence -> review -> confirm -> persist

### Backend placement

Use a new `MoneyTree.Imports` context with modules such as:

- `MoneyTree.Imports`
- `MoneyTree.Imports.Document`
- `MoneyTree.Imports.Extraction`
- `MoneyTree.Imports.Storage`
- `MoneyTree.Imports.Classifier`
- `MoneyTree.Imports.Extractor`
- `MoneyTree.Imports.ReviewMapper`
- `MoneyTree.Imports.ExtractWorker`

### File handling

MVP storage strategy:

- persist file metadata in `import_documents`
- store file bytes in app-managed storage keyed by `storage_key`
- keep storage implementation simple and replaceable

Recommended MVP implementation:

- local private storage for development and initial deployment
- storage path not served directly from public static assets
- signed/backend-mediated retrieval for preview/download later

### Extraction flow

1. User uploads PDF or screenshot.
2. Backend stores file and creates `import_documents` row with `upload_status=uploaded`.
3. Oban worker classifies document type and runs extraction.
4. Worker stores extraction payload, field confidences, and document classification in `import_extractions`.
5. User opens a review UI that shows proposed structured fields before any domain write occurs.
6. User confirms, edits, or discards fields.
7. Backend maps confirmed fields into the target domain table and stamps verification metadata.
8. Backend triggers domain evaluation and optional alert generation.

### Review-first mapping

The review layer should map extracted fields into one of:

- mortgage profile draft
- rent profile draft
- vehicle finance profile draft
- insurance policy draft
- financial profile fact draft

Important rule:

- extraction payloads are drafts
- domain tables hold only user-confirmed or explicitly synced data

### Confidence storage

Store confidence at two levels:

- extraction-level `confidence_score`
- field-level `field_confidences` map

Do not collapse these into evaluation confidence. Evaluation confidence must remain deterministic and derive from data completeness/freshness, not model self-reporting.

## 7. Backend Implementation Plan

### Routes and endpoints

New authenticated API groups should likely live under `/api`:

- `/api/evaluations/mortgages`
- `/api/evaluations/mortgages/:id`
- `/api/evaluations/mortgages/:id/result`
- `/api/evaluations/vehicles`
- `/api/evaluations/vehicles/:id`
- `/api/evaluations/vehicles/:id/result`
- `/api/evaluations/insurance`
- `/api/evaluations/insurance/:id`
- `/api/evaluations/insurance/:id/result`
- `/api/evaluations/status-summary`
- `/api/imports/documents`
- `/api/imports/documents/:id`
- `/api/imports/documents/:id/extractions`
- `/api/imports/extractions/:id/review`
- `/api/imports/extractions/:id/confirm`

Keep the controller style consistent with:

- `MoneyTreeWeb.ObligationController`
- `MoneyTreeWeb.SettingsController`

### Context functions

Likely context functions:

- `MoneyTree.Evaluations.list_mortgage_profiles/2`
- `MoneyTree.Evaluations.create_mortgage_profile/2`
- `MoneyTree.Evaluations.update_mortgage_profile/3`
- `MoneyTree.Evaluations.evaluate_mortgage/2`
- `MoneyTree.Evaluations.list_vehicle_finance_profiles/2`
- `MoneyTree.Evaluations.evaluate_vehicle_finance/2`
- `MoneyTree.Evaluations.list_insurance_policies/2`
- `MoneyTree.Evaluations.evaluate_insurance_policy/2`
- `MoneyTree.Evaluations.status_summary/2`
- `MoneyTree.Evaluations.refresh_benchmark_rates/1`
- `MoneyTree.Imports.create_document/2`
- `MoneyTree.Imports.fetch_document/2`
- `MoneyTree.Imports.list_documents/2`
- `MoneyTree.Imports.enqueue_extraction/1`
- `MoneyTree.Imports.fetch_extraction_for_review/2`
- `MoneyTree.Imports.confirm_extraction/3`
- `MoneyTree.Imports.discard_extraction/2`

### Services and orchestration

Service-level modules should handle:

- benchmark fetch and freshness rules
- evaluation composition from profile + benchmark + status checks
- import classification and extraction mapping
- post-confirm domain upserts

### Background jobs

Add Oban workers for:

- benchmark refresh
- evaluation recheck
- import extraction

Possible worker names:

- `MoneyTree.Evaluations.BenchmarkRefreshWorker`
- `MoneyTree.Evaluations.StatusCheckWorker`
- `MoneyTree.Imports.ExtractWorker`

### Rate and benchmark storage

Store snapshots rather than mutating one global row. Evaluators should select the most recent non-stale snapshot that matches:

- benchmark type
- market scope
- term
- effective date window

That makes recommendations auditable and avoids silent moving targets.

## 8. Frontend Implementation Plan

### What belongs in Phoenix LiveView

Keep compact product-integrated surfaces in LiveView:

- dashboard cards and badges
- assets page summary badges for property/vehicle/insurance attachment state
- obligations page summary of insurance and housing payment alerts
- accounts page stale-data or benchmark freshness warnings

These should be summary and launch-point surfaces, not the full wizard.

### What belongs in Next.js

Place the richer flows in `apps/next/app`:

- mortgage evaluation list/detail page
- refinance opportunity detail and explanation page
- insurance evaluation list/detail page
- vehicle loan/lease evaluation list/detail page
- import upload and review wizard

Suggested routes:

- `apps/next/app/evaluations/page.tsx`
- `apps/next/app/evaluations/mortgages/[id]/page.tsx`
- `apps/next/app/evaluations/vehicles/[id]/page.tsx`
- `apps/next/app/evaluations/insurance/[id]/page.tsx`
- `apps/next/app/imports/page.tsx`
- `apps/next/app/imports/[id]/page.tsx`

### UI shape

Mortgage evaluation views:

- current loan snapshot
- benchmark comparison
- refinance candidate badge
- break-even summary
- missing/stale data checklist
- review history and source metadata

Status indicators:

- compact badges for `healthy`, `needs_review`, `stale`, `opportunity`, `expiring`, `incomplete`
- visible confidence and missing-data messaging

Import review screens:

- file preview
- extracted field list grouped by target record type
- editable confirmation form
- field-level confidence display
- explicit confirm button
- explicit discard button

### Progressive enrichment UX

The UX should not require full data up front.

Recommended approach:

- allow creation of a minimal mortgage/vehicle/insurance record
- show incomplete status with missing field prompts
- let imports enrich existing records later
- let dashboard and evaluation pages explain exactly what additional fields unlock better recommendations

### Avoiding clutter

Do not push full evaluation forms into the Phoenix dashboard. Use:

- summary cards on dashboard
- dedicated Next detail pages for full workflows
- concise “missing fields” prompts that deep-link into Next pages

This aligns with the existing app-shell plan where the dashboard should stop accumulating management workflows.

## 9. Contracts Integration

### Required changes

For every new Phoenix JSON endpoint used by Next:

- add request and response schemas to `apps/contracts/specs/openapi.yaml`
- regenerate `apps/contracts/src/generated/rest.ts`
- keep any Next local response normalizers aligned with generated types

### Practical rollout

Because the contracts package is currently underused, do not try to retrofit the whole existing API in one step.

Instead:

- make the new evaluation and import APIs contract-driven from day one
- optionally add the existing obligations/settings/accounts shapes later as a separate cleanup stream

### Generation flow

- edit `apps/contracts/specs/openapi.yaml`
- run `pnpm --dir apps/contracts generate`
- verify with `pnpm --dir apps/contracts verify`

## 10. AI / LLM Boundaries

### AI allowed

- document parsing
- classification
- summarization
- user-facing explanation text that describes deterministic outputs

### AI not allowed

- calculations
- eligibility logic
- refinance recommendation thresholds
- break-even math
- PMI logic
- payment or premium assumptions
- final persistence without user confirmation

### Deterministic-to-AI handoff

Recommended pattern:

1. Phoenix evaluator computes facts such as LTV, break-even months, stale fields, and status.
2. Those facts are returned as structured data.
3. AI may generate a natural-language explanation from those facts.
4. The UI should still display the raw deterministic facts and status labels even if an explanation is generated.

## 11. External Data / Benchmarks

### Data needed

- mortgage rates
- refinance benchmarks
- potentially vehicle loan benchmark rates later

### Fetch/store/cache plan

Use `Req` and the existing backend HTTP stack for benchmark ingestion.

Flow:

- scheduled worker fetches benchmark data daily
- rows stored in `benchmark_rate_snapshots`
- evaluator reads only fresh-enough snapshots
- if no fresh benchmark exists, evaluation degrades gracefully and records low confidence plus a stale-benchmark reason

### Snapshot strategy

Do not overwrite in place. Store snapshots with:

- source metadata
- effective date
- fetch timestamp
- raw payload

This is important for explainability and testing.

### Avoiding stale recommendations

Recommended freshness rules:

- benchmark row older than configurable threshold marks opportunity checks as stale
- status checker emits a `benchmark_stale` or `needs_refresh` style evaluation result
- user-visible recommendation text should clearly say when benchmark freshness is insufficient

## 12. Incremental Rollout Plan

### Phase 1: Schema and foundations

Deliverables:

- additive tables for mortgage, rent, vehicle finance, insurance, evaluation results, benchmark snapshots, import documents, and import extractions
- basic `MoneyTree.Evaluations` and `MoneyTree.Imports` contexts
- contract scaffolding for new APIs

Independently useful result:

- backend can persist reviewed evaluation subjects and benchmark snapshots even before full UI is present

### Phase 2: Mortgage and refinance

Deliverables:

- mortgage profile CRUD
- benchmark fetch
- refinance and PMI deterministic evaluator
- durable alerts for refinance opportunity and stale mortgage data
- Next mortgage evaluation pages
- dashboard/status integration

Independently useful result:

- mortgage evaluation tool works end to end without import support

### Phase 3: Import pipeline

Deliverables:

- document upload
- extraction worker
- extraction review UI
- confirm-to-persist mapping for mortgage first

Independently useful result:

- user can import a mortgage statement PDF or screenshot, review extracted data, and persist it safely

### Phase 4: Insurance and vehicle

Deliverables:

- insurance policy CRUD and evaluator
- vehicle finance profile CRUD and evaluator
- renewal/lease alerts
- Next detail pages and summary badges

Independently useful result:

- insurance and vehicle evaluation tools work using manual entry first, import later

### Phase 5: Alerts and dashboard integration

Deliverables:

- richer dashboard badges, cards, and deep links
- status summary API
- broader notification event support
- stale-data and missing-data alert surfacing across LiveView and Next

Independently useful result:

- evaluation outputs are discoverable from core product surfaces instead of isolated tools

## 13. Risks And Guardrails

### Data quality

- imported statements may contain conflicting values
- synced account balances may not be enough to infer mortgage or lease structure
- manual values and imported values may diverge

Guardrail:

- preserve source metadata and explicit verification state

### Extraction errors

- OCR/classification can misread balances, dates, and rates

Guardrail:

- no silent persistence
- field-level review required

### False precision

- refinance recommendations can look more certain than the available data supports

Guardrail:

- expose missing/stale fields
- keep confidence deterministic and visible

### Privacy and security

- uploaded PDFs and screenshots may contain highly sensitive financial data

Guardrail:

- store outside public static paths
- enforce auth on access
- redact where possible in logs
- keep raw payload access narrow

### UX complexity

- adding too many evaluation forms to LiveView pages will clutter the product

Guardrail:

- keep dashboard and core LiveViews summary-oriented
- move detailed workflows into dedicated Next pages

### Monorepo coordination

- backend, contracts, and Next pages can drift

Guardrail:

- each feature slice should land backend shape, contract, and one consuming UI together when that slice crosses layers

## 14. Codex Task Breakdown

### Task 1

Task Name

Evaluation Schema Foundations

Scope

- add additive database tables and base schemas for mortgage, rent, vehicle finance, insurance, evaluation results, and benchmark snapshots

Files likely affected

- `apps/money_tree/priv/repo/migrations/*`
- `apps/money_tree/lib/money_tree/evaluations.ex`
- `apps/money_tree/lib/money_tree/evaluations/*.ex`

What to implement

- new migration
- base schemas
- changesets
- minimal list/fetch/create/update APIs

What NOT to touch

- Next pages
- dashboard UI
- import pipeline

Validation steps

- `mix ecto.migrate`
- targeted schema/context tests

### Task 2

Task Name

Benchmark Snapshot Ingestion

Scope

- add benchmark fetcher, snapshot persistence, and worker scheduling

Files likely affected

- `apps/money_tree/lib/money_tree/evaluations/benchmark_fetcher.ex`
- `apps/money_tree/lib/money_tree/evaluations/benchmark_refresh_worker.ex`
- related tests and config

What to implement

- fetch/store/cache logic
- freshness selection helper

What NOT to touch

- UI
- import extraction

Validation steps

- targeted unit tests for stale/fresh snapshot selection

### Task 3

Task Name

Mortgage Evaluator

Scope

- deterministic mortgage/refinance/PMI evaluator plus persisted result writing

Files likely affected

- `apps/money_tree/lib/money_tree/evaluations/mortgage_evaluator.ex`
- `apps/money_tree/lib/money_tree/evaluations.ex`
- tests

What to implement

- break-even logic
- refinance candidate detection
- PMI removal check
- missing/stale/confidence calculations

What NOT to touch

- Next pages
- import worker

Validation steps

- evaluator tests with explicit numeric fixtures

### Task 4

Task Name

Evaluation Notification Integration

Scope

- extend durable event kinds/statuses and emit alerts for evaluation transitions

Files likely affected

- `apps/money_tree/lib/money_tree/notifications.ex`
- `apps/money_tree/lib/money_tree/notifications/event.ex`
- `apps/money_tree/lib/money_tree/evaluations/*.ex`
- migration if event enum-like validations need expansion

What to implement

- new event kind/status support
- dedupe strategy for evaluation alerts

What NOT to touch

- Next UI beyond consuming existing notification outputs

Validation steps

- notification event tests
- evaluator-triggered alert tests

### Task 5

Task Name

Mortgage API and Contracts

Scope

- authenticated controllers plus OpenAPI entries for mortgage CRUD and result endpoints

Files likely affected

- `apps/money_tree/lib/money_tree_web/router.ex`
- new `apps/money_tree/lib/money_tree_web/controllers/*`
- `apps/contracts/specs/openapi.yaml`
- `apps/contracts/src/generated/*`

What to implement

- JSON endpoints
- serializer shapes
- contract updates and regeneration

What NOT to touch

- dashboard LiveView
- import UI

Validation steps

- controller tests
- `pnpm --dir apps/contracts verify`

### Task 6

Task Name

Mortgage Next Screens

Scope

- add Next evaluation listing/detail screens backed by mortgage APIs

Files likely affected

- `apps/next/app/evaluations/*`
- `apps/next/app/lib/*`
- Next unit tests

What to implement

- list/detail view
- server fetch helpers
- missing-data and confidence UI

What NOT to touch

- Phoenix evaluation formulas
- import pipeline

Validation steps

- `pnpm --dir apps/next test`
- `pnpm --dir apps/next lint`

### Task 7

Task Name

Import Persistence Foundations

Scope

- add document and extraction tables, schemas, and storage hooks

Files likely affected

- migration files
- `apps/money_tree/lib/money_tree/imports.ex`
- `apps/money_tree/lib/money_tree/imports/*.ex`

What to implement

- uploaded document metadata
- extraction record persistence
- review status lifecycle

What NOT to touch

- mortgage evaluator math
- dashboard UI

Validation steps

- migration and context tests

### Task 8

Task Name

Import Extraction Worker

Scope

- asynchronous classify/extract workflow with draft payload persistence

Files likely affected

- `apps/money_tree/lib/money_tree/imports/extract_worker.ex`
- `apps/money_tree/lib/money_tree/imports/extractor.ex`
- tests

What to implement

- worker lifecycle
- extraction failure handling
- confidence storage

What NOT to touch

- final domain persistence
- Next review UI

Validation steps

- worker tests with mocked extractor

### Task 9

Task Name

Import Review and Confirm API

Scope

- review payload endpoints and confirm-to-persist mortgage mapping

Files likely affected

- import controllers
- `MoneyTree.Imports`
- `MoneyTree.Evaluations`
- contracts

What to implement

- review fetch endpoint
- confirm endpoint
- confirmed mapping into mortgage profile
- post-confirm re-evaluation enqueue

What NOT to touch

- insurance and vehicle persistence

Validation steps

- controller and integration tests
- contracts verify

### Task 10

Task Name

Import Review Next Flow

Scope

- upload and review wizard in Next for mortgage documents first

Files likely affected

- `apps/next/app/imports/*`
- `apps/next/app/lib/*`

What to implement

- upload screen
- review screen
- field confidence display
- explicit confirm/discard actions

What NOT to touch

- backend evaluation formulas
- dashboard LiveView

Validation steps

- Next unit tests and lint

### Task 11

Task Name

Insurance Persistence and Evaluator

Scope

- add insurance policy domain plus renewal/stale-data evaluator

Files likely affected

- evaluations schemas and modules
- controller/routes
- tests

What to implement

- policy CRUD
- deterministic renewal and missing-data status logic

What NOT to touch

- vehicle flows
- import extraction unless needed for policy mapping later

Validation steps

- schema, evaluator, and controller tests

### Task 12

Task Name

Vehicle Finance Persistence and Evaluator

Scope

- add vehicle loan/lease domain plus status checks

Files likely affected

- evaluations schemas and modules
- controllers/routes
- tests

What to implement

- loan/lease CRUD
- lease-end, mileage-risk, and missing-data logic

What NOT to touch

- insurance flows
- mortgage import mapping

Validation steps

- schema, evaluator, and controller tests

### Task 13

Task Name

Dashboard and LiveView Summary Integration

Scope

- add compact evaluation summary cards/badges and deep links into Next pages

Files likely affected

- `apps/money_tree/lib/money_tree_web/live/dashboard_live.ex`
- `apps/money_tree/lib/money_tree_web/live/assets_live/index.ex`
- `apps/money_tree/lib/money_tree_web/live/obligations_live/index.ex`
- maybe `apps/money_tree/lib/money_tree/accounts.ex` summary helpers

What to implement

- summary counts
- stale/opportunity badges
- deep links to evaluation pages

What NOT to touch

- full import wizard
- benchmark fetcher internals

Validation steps

- targeted LiveView tests

### Task 14

Task Name

Status Summary API and Next Index Page

Scope

- aggregate evaluation status checker output across domains

Files likely affected

- evaluation context aggregation helper
- status summary controller
- contracts
- `apps/next/app/evaluations/page.tsx`

What to implement

- one API for incomplete/stale/opportunity/expiring counts
- Next landing page for all evaluation tools

What NOT to touch

- low-level evaluator formulas already covered by earlier tasks

Validation steps

- controller tests
- contracts verify
- Next tests

## Recommended Execution Order

The safest order for Codex execution is:

1. schema foundations
2. benchmark ingestion
3. mortgage evaluator
4. notification integration
5. mortgage API and contracts
6. mortgage Next screens
7. import persistence foundations
8. extraction worker
9. import review and confirm API
10. import review Next flow
11. insurance domain
12. vehicle domain
13. dashboard/live summary integration
14. status summary aggregation

That order keeps early tasks backend-focused, independently testable, and additive before introducing cross-layer review UI.
