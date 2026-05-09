# Loan Center refinance fee strategy

## Purpose

Define a practical refinance fee strategy for MoneyTree's Loan Center so refinance scenarios do not default to unrealistic zero-cost assumptions.

The goal is to make refinance analysis useful before lender integrations exist by generating reasonable, editable, low / expected / high fee ranges from documented assumptions.

This document supplements the existing Loan Center implementation plan. The existing plan already calls out refinance fee items, true refinance costs, cash-flow timing costs, offsets, and low / expected / high cost ranges. This document turns that direction into a Codex-friendly implementation strategy.

## Problem

The refinance calculator can compare payment, break-even, and full-term cost, but a refinance scenario with no fee assumptions produces misleading results.

Symptoms:

- break-even values can appear unrealistically short
- full-term deltas can look overly favorable
- cash-to-close can show `$0.00`
- users may anchor on incomplete results

MoneyTree should never silently treat missing fees as zero. If no fee assumptions are loaded, the UI should say so clearly.

## Core principles

1. Fee assumptions are estimates, not lender quotes.
2. Every estimate must be editable by the user.
3. True refinance costs must be separated from escrow/prepaid timing costs.
4. Low / expected / high ranges should be first-class values.
5. Missing fee assumptions should produce a warning, not a zero-cost scenario.
6. Lender quotes and uploaded Loan Estimate documents should override generic assumptions only after user confirmation.
7. The calculator must remain deterministic and covered by tests.

## Fee categories

Use the existing `refinance_fee_items` model where possible. Do not create a parallel fee system unless the current schema cannot support reusable templates cleanly.

### True refinance costs

These affect break-even and long-term refinance economics:

- origination
- points
- underwriting
- processing
- application
- appraisal
- credit report
- flood certification
- title search
- title insurance
- settlement or closing
- recording
- attorney or notary
- release fee
- prepayment penalty
- other required lender or third-party charges

### Cash-flow timing costs

These affect cash to close but should not be treated as true refinance costs:

- prepaid interest
- initial escrow deposit
- homeowners insurance prepaid
- property tax escrow deposit
- payoff interest adjustment

### Offsets and credits

These reduce cash burden or net cost depending on type:

- lender credits
- waived fees
- expected old escrow refund
- third-party credits if applicable

## Recommended data model

### Option A: Reuse existing scenario fee items

Keep `refinance_fee_items` as the source of per-scenario fee rows.

Use it for:

- user-entered fee items
- generated fee assumptions copied into a scenario
- imported fees from quotes or documents after user confirmation

### Option B: Add reusable fee templates

Add reusable templates if they do not already exist.

Suggested table: `refinance_fee_templates`

Suggested fields:

- `id`
- `loan_type`
- `state_region`
- `county_or_parish`
- `category`
- `code`
- `name`
- `description`
- `kind`
- `is_true_cost`
- `is_prepaid_or_escrow`
- `calculation_method`
- `fixed_low_amount`
- `fixed_expected_amount`
- `fixed_high_amount`
- `percent_low`
- `percent_expected`
- `percent_high`
- `minimum_amount`
- `maximum_amount`
- `required`
- `confidence_level`
- `source_label`
- `source_url`
- `notes`
- `enabled`
- `sort_order`
- timestamps

Supported `calculation_method` values:

- `fixed_amount`
- `percent_of_loan_amount`
- `fixed_plus_percent`
- `per_county_schedule`
- `manual_only`

Supported `confidence_level` values:

- `low`
- `moderate`
- `high`

Do not store provider secrets or external API keys in these templates.

## Initial static assumptions

Add conservative national defaults first. These are not exact lender pricing. They exist to prevent zero-cost analysis and to help users understand likely ranges.

Suggested starting ranges:

| Fee | Category | Kind | Low | Expected | High | Notes |
| --- | --- | --- | ---: | ---: | ---: | --- |
| Origination | origination | true_cost | 0.00% | 0.50% | 1.00% | Percent of new loan amount |
| Discount points | points | true_cost | 0.00% | user/default 0.00% | user-defined | Usually 1 point = 1% of loan amount |
| Appraisal | appraisal | true_cost | $400 | $650 | $900 | May be waived for some refis |
| Credit report | credit_report | true_cost | $25 | $50 | $100 | Small third-party fee |
| Flood certification | flood_certification | true_cost | $10 | $20 | $40 | Mortgage-specific |
| Title search | title_search | true_cost | $150 | $300 | $600 | Varies by state/provider |
| Title insurance | title_insurance | true_cost | 0.20% | 0.40% | 0.80% | Very state-dependent |
| Settlement/closing | settlement_or_closing | true_cost | $300 | $600 | $1,200 | Escrow/closing/settlement agent |
| Recording | recording | true_cost | $50 | $150 | $400 | State/county dependent |
| Attorney/notary | attorney_or_notary | true_cost | $0 | $250 | $900 | State-dependent; optional in many states |
| Release fee | release_fee | true_cost | $0 | $75 | $200 | Payoff/release related |
| Prepaid interest | prepaid_interest | timing_cost | computed | computed | computed | Depends on closing date and daily interest |
| Initial escrow deposit | escrow_deposit | timing_cost | $0 | computed | computed | Depends on taxes/insurance and escrow setup |
| Homeowners insurance prepaid | homeowners_insurance | timing_cost | $0 | user/current policy | user/current policy | Often not a true new cost |
| Property tax escrow | property_tax_escrow | timing_cost | $0 | computed | computed | Based on tax due dates if known |
| Old escrow refund | old_escrow_refund | offset | $0 | estimated current escrow balance | user-confirmed | Should be shown separately |
| Lender credit | lender_credit | offset | $0 | $0 | user-entered | Usually tied to rate/APR tradeoff |

Important: These defaults should be clearly labeled as generic assumptions. They are placeholders until the user enters a lender quote or imports a Loan Estimate.

## Calculation rules

### Fee amount calculation

For each template, generate a low / expected / high fee item.

Pseudo-logic:

```text
if calculation_method == fixed_amount:
  amount = fixed range

if calculation_method == percent_of_loan_amount:
  amount = new_loan_amount * percent range

if calculation_method == fixed_plus_percent:
  amount = fixed range + (new_loan_amount * percent range)

if calculation_method == manual_only:
  do not generate automatically unless user provides value
```

Apply `minimum_amount` and `maximum_amount` when present.

### Points

Discount points should be modeled separately from the interest rate.

Rules:

- 1 point = 1% of the new loan amount.
- Points are true refinance costs.
- Points may reduce rate, but MoneyTree should not automatically infer that reduction unless the user or quote provides it.
- If a market benchmark scenario uses zero points, label it clearly.

### Lender credits

Lender credits should be negative fee/offset items.

Rules:

- reduce cash to close
- may reduce true refinance cost depending on how the quote presents them
- should not be silently assumed
- should be tied to quote/rate assumptions when imported from a lender quote

### Prepaid interest

Prepaid interest should be computed if the user provides an assumed closing date.

Suggested formula:

```text
daily_interest = new_principal_amount * annual_rate / 365
prepaid_interest = daily_interest * days_until_first_payment_period
```

Keep this estimate editable because lenders calculate prepaid interest based on exact closing and first-payment timing.

### Escrow and prepaids

Escrow funding should be shown as cash timing, not true cost.

If the existing mortgage has escrow data, use it as an estimate source:

- current property tax amount
- homeowners insurance amount
- flood insurance amount
- current escrow balance if available
- expected old escrow refund if available

If no escrow data exists, show an explicit missing-data warning.

## Generated scenario behavior

When a scenario is created from a benchmark rate, MoneyTree should offer to add estimated fee assumptions.

Suggested options:

- `No fees yet` — allowed, but produces a warning and disables strong recommendations.
- `Use generic national estimates` — generates editable low / expected / high fee items.
- `Use state/local estimates` — future option.
- `Enter lender quote manually` — user enters real quote values.
- `Import Loan Estimate` — future document extraction workflow.

Do not automatically overwrite user-entered fee items when assumptions are refreshed. Instead, offer a review step.

## UI strategy

### Avoid zero-cost anchoring

If no fee assumptions exist, do not show `True cost $0.00` as if it is a valid result.

Prefer:

```text
No fee assumptions loaded
```

or:

```text
Fee estimate needed before break-even is meaningful
```

### Required UI sections

Add or update the Refinance workspace to show:

- fee assumption status
- estimated true refinance cost range
- estimated cash to close range
- prepaid/escrow timing costs
- expected old escrow refund
- lender credits
- user overrides
- confidence level
- source/notes for generated assumptions

### Warning examples

Add warnings when:

- no fee assumptions exist
- only generic national assumptions are used
- title/government fees are not localized
- escrow/prepaid data is missing
- user has points but no APR/lender quote context
- lower payment is mostly caused by term reset
- break-even is shown despite incomplete fee data

Example warning text:

```text
This scenario does not include refinance fee assumptions yet. Break-even and cash-to-close values are incomplete.
```

```text
This scenario uses generic national fee estimates. Actual lender, title, recording, and escrow charges may vary.
```

## Source priority

When multiple fee sources exist, use this priority order:

1. User-confirmed lender quote or Loan Estimate
2. User-entered manual fee items
3. Parsed document values after user confirmation
4. State/local fee template
5. Generic national fee template
6. No fee assumptions, with warning

Never let generic assumptions override user-confirmed values without review.

## Future data sources

### Public educational sources

Use these for documentation and sanity-checking ranges, not necessarily as APIs:

- CFPB Loan Estimate and Closing Disclosure educational materials
- Freddie Mac refinance education materials
- Fannie Mae refinance education materials
- state title insurance or department of insurance references
- county/parish recorder fee schedules

### Lender quote imports

Later, allow users to enter or import lender quotes with:

- lender name
- quote date
- rate
- APR
- points
- lender credits
- origination fees
- estimated third-party fees
- estimated prepaid/escrow items
- lock expiration
- quote expiration

### Document extraction

Future document types that can improve fee accuracy:

- Loan Estimate
- Closing Disclosure
- payoff quote
- escrow statement
- homeowners insurance bill
- property tax bill

All extracted values require user confirmation before becoming scenario assumptions.

## Backend implementation steps

1. Inspect existing Loan Center fee tables, contexts, calculators, and LiveViews.
2. Confirm whether reusable fee templates already exist.
3. If not, add an additive migration for `refinance_fee_templates` or an equivalent repo-consistent name.
4. Add schema/context functions for listing enabled templates by loan type/state/county.
5. Add a deterministic fee-estimation module, such as `MoneyTree.Loans.RefinanceFeeEstimator`.
6. Add a function to generate fee items for a scenario from selected templates.
7. Add source metadata and confidence fields to generated fee items if missing.
8. Update refinance analysis so missing fee assumptions produce warnings.
9. Update the UI so zero-cost scenarios are clearly marked incomplete.
10. Add seed data for generic mortgage refinance templates.
11. Add tests for fee generation, classification, ranges, and warnings.
12. Run migrations with `mix ecto.migrate`.
13. Run focused Loan Center tests, then full `mix test`.

## Suggested context functions

Names should follow repo conventions, but suggested functions are:

```elixir
list_refinance_fee_templates(filters)
get_refinance_fee_template!(id)
create_refinance_fee_template(attrs)
update_refinance_fee_template(template, attrs)
disable_refinance_fee_template(template)
generate_refinance_fee_items_for_scenario(scenario, opts)
estimate_refinance_fee_range(scenario, opts)
fee_assumption_status(scenario)
```

## Suggested estimator module

Suggested module:

```text
MoneyTree.Loans.RefinanceFeeEstimator
```

Responsibilities:

- select relevant templates
- calculate low / expected / high amounts
- classify true costs vs timing costs vs offsets
- return generated fee item attributes
- report confidence level
- report warnings
- avoid persistence unless called by a context function that explicitly saves generated fee items

The estimator should be pure/deterministic where possible.

## Test plan

### Unit tests

- fixed fee template produces expected low / expected / high values
- percentage fee template scales with loan amount
- fixed plus percentage template works
- minimum and maximum bounds are applied
- points are calculated as percentage of loan amount
- lender credits reduce cash impact
- prepaids are excluded from true refinance cost
- missing fees produce warnings
- generic assumptions produce lower confidence warnings

### Context tests

- generated fee items are associated with the correct scenario
- generic templates do not overwrite user-entered fee items without review
- disabled templates are ignored
- state/local templates take priority over generic templates when available

### Calculator tests

- break-even uses true refinance cost, not escrow/prepaid timing costs
- cash-to-close includes timing costs and credits
- full-term cost includes true refinance costs and financed fees where applicable
- no-fee scenarios are marked incomplete

### LiveView/UI tests

- scenario with no fee assumptions shows incomplete warning
- scenario with generated assumptions shows estimated fee ranges
- user can add/edit fee items
- cost assumptions panel shows source and confidence
- break-even display is labeled incomplete when fees are missing

## Acceptance criteria

This work is complete when:

- refinance scenarios no longer silently imply zero closing costs
- users can generate editable generic fee assumptions for mortgage refinance scenarios
- generated assumptions include low / expected / high ranges
- true refinance costs are separated from cash-flow timing costs
- break-even calculations use true refinance costs only
- cash-to-close calculations include timing costs and offsets
- UI clearly labels generic estimates and missing assumptions
- user-entered or confirmed quote/document values take priority over generic assumptions
- tests cover estimator behavior and refinance calculator integration

## Non-goals for first implementation

Do not implement these in the first pass:

- lender API integrations
- exact state/county recording fee imports
- automatic title insurance pricing by state
- PDF/OCR Loan Estimate extraction
- AI-generated fee estimates
- automatic rate/points optimization
- refinance recommendations or approvals

These can be added later once the deterministic fee template system is stable.
