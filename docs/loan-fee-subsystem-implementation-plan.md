# Loan Fee Subsystem Implementation Plan

## Purpose

Implement a structured fee subsystem for MoneyTree's Loan Center.

The goal is to replace loose, free-form fee entry with predefined, loan-type-aware fee types that can support:

- predicted total closing-cost ranges
- localized fee assumptions by state and parish/county
- lender quote comparison
- required-fee completeness checks
- unusual or high-fee warnings
- confidence scoring
- future credit-score-aware pricing assumptions

This plan builds on `docs/loan-fee-regulatory-research.md` and the existing Loan Center refinance fee strategy.

## Implementation status

Status as of May 10, 2026:

| Area | Status | Notes |
| --- | --- | --- |
| Persistent fee configuration | Done for v1 | Added fee types, jurisdiction profiles, jurisdiction rules, and default seed helpers. |
| Louisiana starter profile | Done for v1 | State-level Louisiana refinance overrides are available; Orleans Parish documentary transaction tax is modeled when parish is known. |
| Sparse non-mortgage shell | Done for v1 | Auto, personal, and student placeholder fee types exist with very-low confidence. |
| Prediction engine | Done for v1 | Computes low / expected / high ranges, true costs, timing costs, offsets, confidence, and warnings. |
| Quote fee-line model | Done for v1 | Lender quote fee lines persist classification, confidence, required/review flags, and notes. |
| Quote analyzer | Done for v1 | Maps labels to canonical fee types, classifies known/unknown/high/duplicate lines, and reports missing required fees. |
| Loan Center integration | Partial | Refinance workspace shows prediction ranges, “Add common fees,” editable/removable fee items, grouped fee assumptions, manual quote fee-line entry, and quote fee review. Remaining UX refinement is mostly deeper quote review workflows and localized data expansion. |
| Credit score support | Metadata only | Fee types can be marked credit-score-sensitive, but no pricing adjustment is applied. |
| Deferred future work | Pending | Additional parish-level rules beyond Orleans, verified title-insurance rate tables, prediction snapshots, opportunity scoring, and enterprise providers remain out of v1. |

Louisiana verification details are tracked in `docs/loan-fee-louisiana-verification-notes.md`.

## Core product principle

MoneyTree should help users understand and compare loan/refinance costs without pretending to be a lender, broker, underwriter, compliance system, or legal disclosure generator.

Use structured language:

```text
Estimated
Modeled range
High relative to MoneyTree's expected range
Missing from this quote
May be optional
Requires review
```

Avoid legal conclusions:

```text
Illegal
Approved
Compliant
Qualified Mortgage
High-cost mortgage determination
```

---

# 1. Problems to solve

Current or likely issues:

- Free-form fee names make comparison and validation difficult.
- Missing fee assumptions can produce unrealistic zero-cost scenarios.
- Lender quotes may omit prepaid or escrow timing costs.
- Users need low / expected / high ranges, not single-point estimates.
- Mortgage refinance fees vary by state and parish/county.
- Some fees affect true refinance cost, while others are cash-flow timing items.
- Credit score will affect rate/points/lender credit modeling later.

---

# 2. Desired user-facing capabilities

## 2.1 Fee prediction

For a loan or refinance scenario, MoneyTree should predict:

```text
total_closing_cost_low
total_closing_cost_expected
total_closing_cost_high
true_refinance_cost_low
true_refinance_cost_expected
true_refinance_cost_high
cash_to_close_low
cash_to_close_expected
cash_to_close_high
confidence_level
```

## 2.2 Fee quote review

When a user enters or imports a quote, MoneyTree should classify each fee:

```text
below_expected_range
within_expected_range
above_expected_range
extreme_outlier
missing_required_fee
not_required_or_optional
unknown_fee_type
possible_duplicate_fee
possible_junk_or_unusual_fee
```

## 2.3 Required fee checks

The system should identify expected fee categories that are missing from a quote.

Example:

```text
This quote does not list recording/government fees. The quote may be incomplete, or these costs may be listed elsewhere.
```

## 2.4 Localized prediction

Start with Louisiana.

Support future state/parish profiles that narrow generic national ranges.

## 2.5 Confidence

Show users how confident the estimate is.

Examples:

```text
Low confidence: generic national assumptions
Moderate confidence: Louisiana profile applied
High confidence: lender quote entered
Verified: final Closing Disclosure imported
```

---

# 3. Data model

Prefer additive migrations. Follow existing repo naming and schema conventions.

## 3.1 `loan_fee_types`

Defines allowed fee types per loan type and transaction type.

Suggested fields:

```text
id
loan_type
transaction_type
code
display_name
description
trid_section
tolerance_bucket
finance_charge_treatment
apr_affecting
points_and_fees_included
high_cost_included
is_true_cost
is_timing_cost
is_offset
is_required
is_optional
is_shoppable
is_lender_controlled
is_third_party
is_government_fee
is_state_localized
requires_local_verification
credit_score_sensitive
amount_calculation_method
fixed_low_amount
fixed_expected_amount
fixed_high_amount
percent_low
percent_expected
percent_high
minimum_amount
maximum_amount
warning_low_threshold_amount
warning_high_threshold_amount
extreme_high_threshold_amount
warning_low_threshold_percent
warning_high_threshold_percent
extreme_high_threshold_percent
confidence_level
source_label
source_url
last_verified_at
enabled
sort_order
notes
inserted_at
updated_at
```

### Suggested enums

`loan_type`:

```text
mortgage
auto
personal
student
heloc
credit_card_balance_transfer
other
```

`transaction_type`:

```text
purchase
refinance
cash_out_refinance
rate_term_refinance
new_loan
loan_modification
balance_transfer
```

`trid_section`:

```text
origination_charges
services_cannot_shop_for
services_can_shop_for
taxes_and_government_fees
prepaids
initial_escrow_payment
other
lender_credits
payoffs_and_payments
not_applicable
```

`tolerance_bucket`:

```text
zero_tolerance
ten_percent_aggregate
no_limit_best_information
not_applicable
unknown
```

`finance_charge_treatment`:

```text
included
excluded
conditional
unknown
```

`amount_calculation_method`:

```text
fixed_amount
percent_of_loan_amount
fixed_plus_percent
computed_prepaid_interest
computed_escrow_deposit
state_profile
county_or_parish_profile
manual_only
```

`confidence_level`:

```text
very_low
low
moderate
high
verified
```

## 3.2 `loan_fee_jurisdiction_profiles`

Stores state and local adjustments.

Suggested fields:

```text
id
country_code
state_code
county_or_parish
municipality
loan_type
transaction_type
confidence_level
source_label
source_url
last_verified_at
notes
enabled
inserted_at
updated_at
```

This table represents the jurisdiction, not individual fee rows.

## 3.3 `loan_fee_jurisdiction_rules`

Stores fee-specific rules for a jurisdiction.

Suggested fields:

```text
id
jurisdiction_profile_id
loan_fee_type_id
amount_calculation_method
fixed_low_amount
fixed_expected_amount
fixed_high_amount
percent_low
percent_expected
percent_high
minimum_amount
maximum_amount
requires_local_verification
source_label
source_url
last_verified_at
notes
enabled
inserted_at
updated_at
```

Example:

- Louisiana refinance recording fee profile
- Orleans Parish mortgage recording estimate
- Future title insurance rate profile

## 3.4 Scenario fee items

Reuse existing refinance/scenario fee item tables where possible.

If current fee item schema lacks metadata, add fields such as:

```text
loan_fee_type_id
source_type
source_confidence
classification
trid_section
tolerance_bucket
finance_charge_treatment
apr_affecting
points_and_fees_included
is_true_cost
is_timing_cost
is_offset
is_required
is_optional
requires_review
review_note
```

`source_type` enum:

```text
generated_generic
generated_state_profile
generated_local_profile
manual_user_input
lender_quote
document_extraction
closing_disclosure
```

## 3.5 `loan_fee_prediction_snapshots`

Optional but recommended once the engine is used in the UI.

Suggested fields:

```text
id
user_id
loan_id
mortgage_id
refinance_scenario_id
jurisdiction_profile_id
credit_score_band
prediction_version
total_closing_cost_low
total_closing_cost_expected
total_closing_cost_high
true_cost_low
true_cost_expected
true_cost_high
cash_to_close_low
cash_to_close_expected
cash_to_close_high
confidence_level
confidence_score
missing_fee_codes
warning_codes
assumptions
computed_at
inserted_at
updated_at
```

This makes analysis reproducible.

---

# 4. Initial fee type seed data

Seed only mortgage refinance fee types first.

## 4.1 Mortgage refinance required/core fee types

### `origination_fee`

```text
loan_type: mortgage
transaction_type: refinance
trid_section: origination_charges
tolerance_bucket: zero_tolerance
finance_charge_treatment: included
apr_affecting: true
points_and_fees_included: true
is_true_cost: true
is_required: false
amount_calculation_method: percent_of_loan_amount
percent_low: 0.0000
percent_expected: 0.0075
percent_high: 0.0150
warning_high_threshold_percent: 0.0200
extreme_high_threshold_percent: 0.0300
confidence_level: moderate
```

### `discount_points`

```text
trid_section: origination_charges
finance_charge_treatment: included
apr_affecting: true
points_and_fees_included: true
is_true_cost: true
amount_calculation_method: percent_of_loan_amount
percent_low: 0.0000
percent_expected: 0.0000
percent_high: 0.0200
warning_high_threshold_percent: 0.0300
```

### `appraisal_fee`

```text
trid_section: services_cannot_shop_for
finance_charge_treatment: excluded
apr_affecting: false
is_true_cost: true
amount_calculation_method: fixed_amount
fixed_low_amount: 400
fixed_expected_amount: 650
fixed_high_amount: 900
warning_high_threshold_amount: 1200
```

### `credit_report_fee`

```text
fixed_low_amount: 10
fixed_expected_amount: 50
fixed_high_amount: 100
```

### `flood_certification_fee`

```text
fixed_low_amount: 10
fixed_expected_amount: 20
fixed_high_amount: 40
```

### `title_search_fee`

```text
fixed_low_amount: 150
fixed_expected_amount: 300
fixed_high_amount: 600
```

### `title_insurance_lender_policy`

```text
amount_calculation_method: percent_of_loan_amount
percent_low: 0.0020
percent_expected: 0.0050
percent_high: 0.0100
is_state_localized: true
```

### `settlement_or_closing_fee`

```text
fixed_low_amount: 300
fixed_expected_amount: 600
fixed_high_amount: 1200
```

### `recording_fee`

```text
trid_section: taxes_and_government_fees
is_government_fee: true
is_state_localized: true
requires_local_verification: true
fixed_low_amount: 50
fixed_expected_amount: 150
fixed_high_amount: 500
```

### `attorney_or_notary_fee`

```text
fixed_low_amount: 0
fixed_expected_amount: 500
fixed_high_amount: 1000
is_state_localized: true
```

### `prepaid_interest`

```text
trid_section: prepaids
is_timing_cost: true
is_true_cost: false
amount_calculation_method: computed_prepaid_interest
```

### `escrow_deposit`

```text
trid_section: initial_escrow_payment
is_timing_cost: true
is_true_cost: false
amount_calculation_method: computed_escrow_deposit
```

### `lender_credit`

```text
trid_section: lender_credits
is_offset: true
amount_calculation_method: manual_only
```

---

# 5. Louisiana phase 1 profile

Add a Louisiana state profile with moderate-low confidence.

```text
country_code: US
state_code: LA
loan_type: mortgage
transaction_type: refinance
confidence_level: moderate
```

## 5.1 Louisiana adjustments

Initial adjustments:

- narrow total refinance cost range to 2.0% / 3.25% / 4.75%
- keep recording as local-verification-required
- keep title insurance as state-localized
- set attorney/notary/settlement expected amount above zero

Do not hard-code unverified statewide mortgage tax logic.

---

# 6. Fee prediction engine

Suggested module:

```text
MoneyTree.Loans.FeePredictionEngine
```

Responsibilities:

1. Load fee types for loan type and transaction type.
2. Load state/local jurisdiction profile.
3. Apply fee type defaults.
4. Apply jurisdiction overrides.
5. Apply scenario assumptions.
6. Compute low / expected / high ranges.
7. Separate true cost from cash timing cost.
8. Return warnings and confidence.

## 6.1 Suggested public functions

```elixir
predict_closing_cost_range(scenario, opts \\ [])
classify_quote_fee(fee_line, scenario, opts \\ [])
classify_quote(quote, scenario, opts \\ [])
missing_required_fees(quote_or_scenario, opts \\ [])
fee_confidence(scenario, opts \\ [])
```

## 6.2 Prediction result shape

```elixir
%{
  total_closing_cost: %{low: Decimal.t(), expected: Decimal.t(), high: Decimal.t()},
  true_cost: %{low: Decimal.t(), expected: Decimal.t(), high: Decimal.t()},
  cash_to_close: %{low: Decimal.t(), expected: Decimal.t(), high: Decimal.t()},
  confidence_level: :low | :moderate | :high | :verified,
  confidence_score: integer(),
  fee_items: [],
  warnings: [],
  missing_fee_codes: []
}
```

---

# 7. Quote analysis engine

Suggested module:

```text
MoneyTree.Loans.FeeQuoteAnalyzer
```

Responsibilities:

- map quote fee labels to known fee types
- classify each fee as low/normal/high/outlier
- detect duplicate fee patterns
- detect missing expected categories
- detect unusual/junk-like labels
- identify likely no-closing-cost tradeoffs

## 7.1 Fee label mapping

Support aliases.

Example:

```text
origination_fee:
  - Origination Fee
  - Loan Origination
  - Lender Origination Charge

underwriting_fee:
  - Underwriting Fee
  - UW Fee

settlement_or_closing_fee:
  - Settlement Fee
  - Closing Fee
  - Escrow Fee
```

Unknown labels should remain user-visible and require review.

## 7.2 Classification thresholds

Suggested logic:

```text
amount < modeled_low: below_expected_range
modeled_low <= amount <= modeled_high: within_expected_range
amount > modeled_high: above_expected_range
amount > extreme_threshold: extreme_outlier
```

For percent-based fees, compare as percentage of new loan amount.

---

# 8. Credit score preparation

Add optional scenario field or assumptions entry:

```text
credit_score_band
```

Suggested enum:

```text
excellent_760_plus
very_good_720_759
good_680_719
fair_620_679
subprime_below_620
unknown
```

Do not apply credit score adjustments yet unless a validated pricing model exists.

Future use:

- points adjustments
- lender credit expectations
- rate scenario range
- mortgage insurance estimates
- LLPA-style adjustments

---

# 9. UI requirements

## 9.1 Fee selection

Replace free-form fee type entry with:

- predefined fee type dropdown
- optional custom label field only after selecting `other` or `unknown_fee_type`

## 9.2 Cost prediction panel

Show:

```text
Predicted closing cost range
True refinance cost range
Cash-to-close timing range
Confidence level
Main assumptions
Missing fee warnings
Localized profile used
```

## 9.3 Quote review panel

For each quote line:

- fee name
- mapped fee type
- amount
- classification
- expected range
- notes

Example:

```text
Origination fee: $6,000
Classification: High relative to expected range
Expected range for this scenario: $0 - $4,500
```

## 9.4 Language rules

Use:

```text
High relative to expected range
May be missing
May be optional
Review recommended
```

Avoid:

```text
Illegal
Invalid
Non-compliant
```

---

# 10. API/contracts

Update OpenAPI contracts for:

- LoanFeeType
- LoanFeeJurisdictionProfile
- LoanFeeJurisdictionRule
- LoanFeePrediction
- QuoteFeeClassification
- MissingFeeWarning

Ensure decimals remain string-encoded if that is the repo convention.

---

# 11. Tests

## 11.1 Unit tests

- fee type defaults calculate fixed ranges correctly
- percentage fees scale with loan amount
- jurisdiction overrides replace generic defaults
- true cost excludes escrow/prepaids
- cash-to-close includes timing costs
- lender credits reduce cash impact
- missing fee detection works
- quote classification handles low/normal/high/outlier
- unknown labels require review

## 11.2 Context tests

- fee types are filtered by loan_type and transaction_type
- disabled fee types are ignored
- Louisiana profile is applied when state is LA
- generic profile is used when no state profile exists
- user-entered quote values do not overwrite templates

## 11.3 UI tests

- free-form fee type entry is not the default path
- user can select predefined fee type
- custom/unknown fee requires review label
- predicted range appears in refinance workspace
- missing required fees are shown
- quote line classifications appear

---

# 12. Implementation phases

## Phase 1: Schema and seed data

- Add loan fee type table.
- Add jurisdiction profile/rule tables.
- Seed mortgage refinance fee types.
- Seed Louisiana state profile.

Acceptance:

- Fee types can be listed by loan type and transaction type.
- Louisiana profile exists.

## Phase 2: Prediction engine

- Implement FeePredictionEngine.
- Generate low / expected / high ranges.
- Separate true cost and cash timing.

Acceptance:

- A refinance scenario returns predicted ranges and confidence.

## Phase 3: Quote analyzer

- Implement fee label mapping.
- Classify quote lines.
- Detect missing expected fees.

Acceptance:

- User-entered quote lines are classified against modeled expectations.

## Phase 4: UI integration

- Replace free-form fee type inputs with predefined fee types.
- Add cost prediction panel.
- Add quote review panel.

Acceptance:

- Users can no longer accidentally build meaningless zero-fee scenarios without warnings.

## Phase 5: Local refinement

- Add parish-level Louisiana profiles.
- Add title-insurance rate support if reliable source data is available.

Acceptance:

- Louisiana estimates become narrower and higher confidence.

---

# 13. Non-goals for first implementation

Do not implement:

- legal Loan Estimate generation
- legal Closing Disclosure generation
- QM certification
- HOEPA certification
- lender compliance audit
- full APR calculation engine
- automatic credit-score pricing adjustments
- lender API integrations

---

# 14. Acceptance criteria

This implementation is complete when:

- fee input uses predefined fee types by default
- generic mortgage refinance fee templates exist
- Louisiana profile exists
- prediction engine returns low / expected / high ranges
- quote analyzer classifies fees relative to modeled ranges
- missing expected fee categories are flagged
- confidence level is shown
- true refinance cost is separated from cash-to-close timing costs
- tests cover calculation, classification, and missing-fee logic

---

End of implementation plan.
