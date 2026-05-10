# Loan Fee Regulatory Research

## Purpose

This document summarizes U.S. federal and selected state-level regulatory concepts that are relevant to MoneyTree's Loan Center fee modeling, refinance analysis, and quote review features.

The goal is to help MoneyTree model realistic low / expected / high closing-cost ranges, classify quoted fees, identify missing or unusual fees, and avoid misleading zero-cost refinance scenarios.

This document is not legal advice. MoneyTree must not present generated estimates as a legal Loan Estimate, Closing Disclosure, Qualified Mortgage determination, HOEPA determination, underwriting result, or lender quote.

## Scope

Initial scope:

- Mortgage refinance fees
- New mortgage loan closing costs
- Federal fee-disclosure structure
- Typical market ranges
- State/local localization strategy, starting with Louisiana

Future scope:

- Auto loans
- Personal loans
- Student loans
- HELOCs
- Credit card balance-transfer scenarios
- Credit-score and pricing-adjustment modeling

## Key conclusion

There is no single universal federal table of legally allowed mortgage fees. Federal law usually controls how fees are disclosed, how they affect APR/finance charge treatment, whether they count toward points-and-fees thresholds, and how much quoted fees may change between disclosures.

For modeling, MoneyTree should distinguish four separate concepts:

1. Legal cap or threshold, where one exists.
2. Regulatory tolerance bucket.
3. Typical market range.
4. MoneyTree modeled best-case / expected / worst-case range.

The app should use structured fee types instead of free-form fee names so every quote line can be classified, compared, and explained.

---

# 1. Federal regulatory concepts

## 1.1 TILA / Regulation Z

Truth in Lending Act (TILA) and Regulation Z affect APR disclosure, finance charge classification, points-and-fees thresholds, Qualified Mortgage points-and-fees limits, high-cost mortgage / HOEPA thresholds, and treatment of mortgage broker fees.

Every fee type should include regulatory metadata:

```text
finance_charge_treatment: included | excluded | conditional | unknown
apr_affecting: true | false | conditional
points_and_fees_included: true | false | conditional
high_cost_included: true | false | conditional
```

MoneyTree should not attempt a legal APR, QM, or HOEPA determination in the first implementation. It can still provide informational warnings when fees are unusually high.

## 1.2 Finance charge treatment

Some fees paid as a condition of credit are finance charges. Many real-estate-related charges may be excluded if bona fide and reasonable, including common third-party items such as appraisal, credit report, title examination, title insurance, document preparation, notary, flood determination, and escrow amounts.

Suggested values:

- `included`: lender/broker fees, origination, points
- `excluded`: bona fide third-party fees, recording, taxes, escrow/prepaids
- `conditional`: affiliate fees, retained third-party fees, ambiguous admin fees
- `unknown`: imported quote labels that cannot be mapped confidently

## 1.3 TRID fee categories

For mortgage transactions, TRID organizes costs into standardized sections. MoneyTree should mirror these sections for mortgage and refinance scenarios.

Suggested `trid_section` enum:

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

Examples:

- Origination Charges: origination fee, discount points, application fee, underwriting fee, processing fee, broker compensation.
- Services You Cannot Shop For: appraisal, credit report, flood determination, tax service, upfront mortgage insurance when applicable.
- Services You Can Shop For: title search, settlement/closing agent, survey, pest inspection where applicable.
- Taxes and Government Fees: recording fees, transfer taxes, mortgage taxes where applicable.
- Prepaids: prepaid interest, homeowners insurance premium, property taxes, mortgage insurance premium when treated as prepaid.
- Initial Escrow Payment at Closing: property tax escrow, homeowners insurance escrow, flood insurance escrow, mortgage insurance escrow.

## 1.4 TRID tolerance buckets

TRID tolerance buckets are disclosure-change rules. They are not market price limits, and they do not tell MoneyTree what a fee should be. They are still useful metadata for quote review.

Suggested `tolerance_bucket` enum:

```text
zero_tolerance
ten_percent_aggregate
no_limit_best_information
not_applicable
unknown
```

### Zero tolerance

Generally includes fees paid to the creditor, mortgage broker, affiliates unless an exception applies, fees for services the consumer cannot shop for, and transfer taxes.

MoneyTree interpretation:

- These are not allowed to increase from the creditor's Loan Estimate except through valid changed-circumstance rules.
- In the app, classify them as high-confidence quote-review fields when a lender quote is available.

### 10% aggregate tolerance

Generally includes recording fees and third-party services where the consumer is allowed to shop but chooses a provider on the lender's written provider list.

MoneyTree interpretation:

- When comparing a lender quote to a later imported Closing Disclosure, the aggregate increase can be reviewed.
- For planning estimates, this bucket should be treated as moderately variable.

### No tolerance / best information

Generally includes prepaid interest, property insurance premiums, property taxes, initial escrow deposits, and services where the consumer chooses a provider not on the lender's list.

MoneyTree interpretation:

- These may change substantially.
- They should affect cash-to-close but usually should not be treated as true refinance cost.

## 1.5 RESPA / Regulation X

RESPA prohibits referral kickbacks and unearned fee splitting for federally related mortgage settlement services.

Do not create normalized default fee templates for vague or suspicious fee labels such as referral fee, partner fee, marketing fee, kickback fee, or administrative surcharge without service description.

If a user imports one from a quote, classify it as:

```text
category: unknown_or_unusual
requires_review: true
```

The app should avoid implying such fees are normal or required.

## 1.6 Qualified Mortgage points-and-fees threshold

Qualified Mortgage rules include points-and-fees limits. For most larger covered loans, the common threshold is 3% of the total loan amount, with different thresholds for smaller loans and annual adjustments.

This threshold is not a universal legal cap on all closing costs. It applies to specific included points-and-fees categories and legal loan classification.

MoneyTree should calculate an informational `estimated_points_and_fees_percent` for quote-review purposes.

Suggested warnings:

- `points_and_fees_above_common_qm_threshold`
- `origination_and_points_high_relative_to_loan_amount`

Important UI text:

```text
This warning is informational. MoneyTree does not determine whether a loan is a Qualified Mortgage.
```

## 1.7 HOEPA / high-cost mortgage threshold

HOEPA high-cost mortgage rules can be triggered by APR thresholds, points-and-fees thresholds, and prepayment penalty thresholds.

MoneyTree should not determine HOEPA status in v1. It may flag unusual fee patterns.

Suggested warnings:

- `possible_high_cost_fee_pattern`
- `prepayment_penalty_present`
- `points_and_fees_extreme`

Important UI text:

```text
This does not determine legal high-cost mortgage status. Review official lender disclosures or consult a qualified professional.
```

---

# 2. Typical market ranges for mortgage/refinance fees

These are modeling ranges, not legal caps.

## 2.1 Total closing costs

Common consumer-facing sources often cite total closing costs around 2% to 6% of the loan amount.

Recommended MoneyTree default ranges:

| Scenario | Modeled range |
| --- | ---: |
| Best-case refinance | 1.0% - 2.0% |
| Typical refinance | 2.0% - 5.0% |
| Conservative high refinance | 5.0% - 7.0% |
| Extreme / review needed | > 7.0% |

For mortgage refinance, if no localized data or quote is available, use a wide generic range:

```text
low: 2.0%
expected: 3.5%
high: 5.5%
confidence: low
```

Then narrow the range as state, parish/county, and quote data become available.

## 2.2 Origination fee

Observed market range:

```text
low: 0.00%
expected: 0.50% - 1.00%
high: 1.50%
review_threshold: > 2.00%
```

MoneyTree should not treat origination above 2% as illegal by default, but should classify it as high relative to common market expectations and potentially relevant to points-and-fees review.

## 2.3 Discount points

1 point equals 1% of the loan amount.

Typical range:

```text
low: 0 points
expected: 0 - 1 point
high: 2 points
review_threshold: > 3 points
```

Discount points must be modeled separately from origination because they are rate-price tradeoffs.

## 2.4 Appraisal fee

Typical range:

```text
low: $400
expected: $650
high: $900
complex_property_high: $1,200+
```

For refinance, an appraisal may be waived. The fee engine should support:

```text
appraisal_required: true | false | unknown
```

## 2.5 Credit report fee

Typical range:

```text
low: $10
expected: $50
high: $100
```

For multiple borrowers, this may scale by borrower count.

## 2.6 Flood certification

Typical range:

```text
low: $10
expected: $20
high: $40
```

## 2.7 Title search / title services

Typical range:

```text
low: $150
expected: $500
high: $2,000
```

This varies by state and whether title services are bundled.

## 2.8 Title insurance

Typical national range:

```text
low: 0.20%
expected: 0.40% - 0.60%
high: 1.00%
```

Title insurance is highly state-specific. Some states regulate title rates. Louisiana should eventually use a dedicated title-insurance rate table or state profile.

## 2.9 Settlement / closing / escrow agent fee

Typical range:

```text
low: $300
expected: $600
high: $1,200
```

## 2.10 Attorney / notary

Typical range:

```text
low: $0
expected: $250 - $750
high: $1,000+
```

State-specific behavior matters. For Louisiana, model a non-zero notary/closing cost expectation.

## 2.11 Recording fees

Typical national range:

```text
low: $50
expected: $150
high: $500
```

However, government recording and transfer/mortgage taxes can be much higher in some states.

## 2.12 Prepaid interest

Prepaid interest should be computed, not static.

Suggested formula:

```text
daily_interest = principal * annual_rate / 365
prepaid_interest = daily_interest * days_until_first_payment_period
```

This is a timing cost, not a true refinance cost.

## 2.13 Escrow deposits

Escrow deposits should be computed from tax and insurance assumptions when available.

Suggested inputs:

- annual_property_tax
- annual_homeowners_insurance
- annual_flood_insurance
- current_escrow_balance
- expected_old_escrow_refund
- next_tax_due_date
- next_insurance_due_date

Escrow funding affects cash-to-close but should not increase true refinance cost.

---

# 3. Louisiana starting profile

Louisiana should be the first localized profile, but exact parish-level values must be verified before being treated as high confidence.

Recommended initial Louisiana profile:

```text
state_code: LA
confidence: moderate_low
```

Initial modeled refinance total closing cost:

```text
low: 2.0%
expected: 3.25%
high: 4.75%
```

Recommended line-item adjustments:

| Fee | LA starting behavior |
| --- | --- |
| Title insurance | Use state-specific profile, moderate range until rate table is added |
| Recording | Parish-specific; use moderate fixed range until parish lookup exists |
| Attorney/notary/settlement | Non-zero expected amount |
| Transfer/mortgage taxes | Require verification before automated inclusion |
| Escrow/prepaids | User/property-specific |

Do not hard-code a statewide Louisiana mortgage tax percentage without verifying the current statute, parish practice, and transaction type.

Use `requires_local_verification: true` for any Louisiana recording tax, transfer tax, mortgage tax, or parish fee calculation until verified source tables are added.

Parish localization roadmap:

- St. Charles Parish
- Jefferson Parish
- Orleans Parish
- St. John the Baptist Parish
- St. Tammany Parish
- East Baton Rouge Parish

For each parish, collect:

- mortgage recording base fee
- per-page fee
- indexing fee
- mortgage certificate fee if applicable
- cancellation/release fee
- e-recording surcharge if applicable
- source URL
- last_verified_at

---

# 4. Quote classification model

When a user enters or imports a lender quote, MoneyTree should classify each fee line against structured expectations.

Suggested classifications:

```text
missing_required_fee
below_expected_range
within_expected_range
above_expected_range
extreme_outlier
not_required_or_optional
unknown_fee_type
possible_duplicate_fee
possible_junk_or_unusual_fee
```

## 4.1 Required but missing

A mortgage refinance quote may be incomplete if it lacks categories such as title/settlement services, recording/government fees, prepaid interest, or escrow/prepaid assumptions when escrow applies.

Do not assume the lender quote is wrong. Mark it as incomplete or possibly not fully itemized.

## 4.2 High fee detection

Examples:

- Origination > 2%: high relative to typical market range
- Discount points > 3: high, review rate tradeoff
- Total closing costs > 7%: extreme, review quote assumptions
- Appraisal > $1,200: high, may be justified for complex property
- Recording/government fee far above state profile: verify locality or taxes

## 4.3 Low fee detection

Examples:

- $0 appraisal: possible waiver
- $0 origination: possibly offset by rate or lender credits
- Very low total costs: possible no-closing-cost refinance or costs rolled into rate

Low is not automatically good. It may indicate hidden rate tradeoff.

---

# 5. Confidence model

Confidence should narrow the range.

Suggested confidence levels:

```text
very_low
low
moderate
high
verified
```

Confidence sources:

| Data source | Confidence impact |
| --- | --- |
| Generic national defaults | low |
| State profile | moderate |
| Parish/county profile | moderate/high |
| User-entered quote | high if complete |
| Uploaded Loan Estimate after user confirmation | high |
| Closing Disclosure after user confirmation | verified |

Suggested range width:

| Confidence | Range behavior |
| --- | --- |
| very_low | wide stress range |
| low | generic 2% - 5.5% |
| moderate | state-adjusted 2% - 4.75% |
| high | quote-based exact values plus known uncertainty |
| verified | actual imported final values |

---

# 6. Credit score impact preparation

Credit score can affect interest rate, points, lender credits, mortgage insurance, approval terms, and pricing overlays.

The first implementation should prepare the data model but not apply automatic credit-score pricing unless validated.

Suggested enum:

```text
excellent_760_plus
very_good_720_759
good_680_719
fair_620_679
subprime_below_620
unknown
```

Suggested future fields:

```text
credit_score_band
pricing_adjustment_percent
points_adjustment_percent
mi_adjustment_percent
llpa_factor
```

MoneyTree should eventually model credit score as a scenario assumption, not as a hidden user profile decision.

---

# 7. Regulatory metadata fields for fee templates

Recommended fields for structured fee templates:

```text
code
display_name
loan_type
transaction_type
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
fixed_low
fixed_expected
fixed_high
percent_low
percent_expected
percent_high
warning_low_threshold
warning_high_threshold
extreme_high_threshold
confidence_level
source_label
source_url
last_verified_at
notes
```

---

# 8. Non-goals

MoneyTree must not:

- create legal Loan Estimates
- create legal Closing Disclosures
- certify QM status
- certify HOEPA/high-cost status
- provide underwriting decisions
- imply lender approval
- imply fees are legally allowed or disallowed without proper context

Use language such as:

```text
This fee is high relative to MoneyTree's modeled range.
```

Avoid:

```text
This fee is illegal.
```

---

# 9. Recommended next implementation step

Create a structured loan fee subsystem that uses this research to:

1. Define allowed fee types per loan type.
2. Generate expected closing-cost ranges.
3. Compare lender quotes against research-backed ranges.
4. Localize assumptions by state and parish/county.
5. Prepare for future credit-score-aware pricing.

See `docs/loan-fee-subsystem-implementation-plan.md` for implementation details.
