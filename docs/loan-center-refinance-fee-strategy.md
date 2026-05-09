# Loan Center Refinance Fee Strategy

## Purpose

Define a practical refinance fee strategy for MoneyTree's Loan Center so refinance scenarios do not default to unrealistic zero-cost assumptions.

The goal is to make refinance analysis useful before lender integrations exist by generating reasonable, editable low / expected / high fee ranges from documented assumptions.

This document supplements the existing Loan Center implementation plan. The existing plan already includes refinance fee items, true refinance costs, cash-flow timing costs, offsets, and low / expected / high cost ranges. This document turns that direction into a repo-adapted implementation strategy.

## Status

This plan is adapted to the current MoneyTree repo state as of May 9, 2026.

Market-rate provider v1 is complete enough to support this work:

- FRED imports are implemented through `MoneyTree.Loans.RateProviders.Fred`.
- Imported benchmark observations are normalized into existing `loan_rate_sources` and `loan_rate_observations`.
- Loan Center already exposes market snapshots, trend windows, source attribution, data-quality warnings, and the required FRED notice.
- Future market-rate work remains intentionally deferred: persistent snapshot cache, lock-period metadata, refinance opportunity score, and enterprise providers such as ICE Mortgage Technology or Optimal Blue.

This fee strategy should build on the current refinance structures instead of introducing a parallel model.

## Comparison To Uploaded Source

The uploaded source document adds important product requirements that were under-specified in the first repo-adapted version:

- It explicitly treats missing fees as incomplete analysis, not `$0.00`.
- It provides concrete generic national starting ranges.
- It defines source priority for fee assumptions.
- It calls out prepaid interest, escrow/prepaid timing, old escrow refunds, and lender credits in more detail.
- It suggests reusable template storage as a future option.

This version keeps those requirements, but adapts the implementation order to the current repo:

- First pass should use an in-code catalog and estimator, not a new `refinance_fee_templates` table.
- Template persistence remains a future additive migration after the static catalog proves useful.
- Existing `refinance_fee_items`, quote conversion, document extraction, and deterministic calculator code remain the system of record.
- Market-rate provider future work stays adjacent, not coupled to fee generation.

## Problem

The refinance calculator can compare payment, break-even, and full-term cost, but a refinance scenario with no fee assumptions produces misleading results.

Symptoms:

- break-even values can appear unrealistically short
- full-term deltas can look overly favorable
- cash-to-close can show `$0.00`
- users may anchor on incomplete results

MoneyTree should never silently treat missing fees as a complete zero-cost scenario. If no fee assumptions are loaded, the UI and analysis warnings should say so clearly.

## Current Repo Fit

Existing implementation surfaces:

- `apps/money_tree/lib/money_tree/loans/refinance_fee_item.ex`
  Existing line-item model for refinance cost and cash-flow timing assumptions.
- `apps/money_tree/lib/money_tree/loans/refinance_scenario.ex`
  Scenario assumptions including rate, term, points, lender credit, cash in/out, and quote linkage.
- `apps/money_tree/lib/money_tree/loans/lender_quote.ex`
  Lender quote model with closing-cost, cash-to-close, monthly payment, lock, and expiration fields.
- `apps/money_tree/lib/money_tree/loans/refinance_calculator.ex`
  Deterministic refinance math. This should remain the only place for calculation formulas.
- `apps/money_tree/lib/money_tree/loans.ex`
  Context functions for fee creation, quote conversion, document extraction conversion, scenario analysis, market snapshots, and alerts.
- `apps/money_tree/lib/money_tree_web/live/loans_live/index.ex`
  Loan Center Refinance workspace UI.

Existing fee behavior:

- Fee items already support `kind`, `category`, amount ranges, lender credits, paid-at-closing, financed, true-cost classification, prepaid/escrow timing classification, and sort order.
- Quote conversion already seeds:
  - `Estimated lender quote costs`
  - `Estimated prepaid and escrow timing costs`
- Document extraction conversion already creates fee items from confirmed extraction candidates.
- Break-even uses true refinance costs.
- Cash-to-close timing uses prepaid/escrow or timing-cost items.
- Imported market benchmarks remain informational and never overwrite user-entered mortgage or scenario records.

## Goal

Make refinance fees easier, safer, and less manual by introducing a structured fee strategy layer:

- classify fees consistently
- seed editable default assumptions
- separate real refinance costs from cash-flow timing items
- make lender credits and waived fees explicit
- make quote/document-derived fees traceable
- keep all calculations deterministic and reviewable
- prepare for future opportunity scoring without presenting benchmarks as offers

## Non-Goals

Do not implement these in the first fee-strategy pass:

- automatic personalized lender pricing
- automatic overwrite of user fee items
- persistent market snapshot cache
- refinance opportunity score
- ICE/Optimal Blue integrations
- new financial advice language
- AI-generated fee values without user review

## Design Principles

- Use existing `refinance_fee_items` first. Add schema fields only when the current model cannot represent a required distinction.
- Treat all seeded fees as editable assumptions.
- Never silently replace user-edited fee items.
- Keep source provenance visible enough to explain where a fee came from.
- Keep `is_true_cost` and `is_prepaid_or_escrow` semantics strict:
  - true cost affects break-even and full-term comparison
  - prepaid/escrow/timing cost affects cash-to-close context but should not be treated as lost refinance cost
- Lender credits, escrow refunds, waived fees, and other credits should reduce applicable cost totals through existing signed-fee behavior.
- Imported benchmarks can suggest context, but not guaranteed closing costs or personalized offers.

## Recommended Data Model

### Phase 1: No Migration

The existing `refinance_fee_items` table can support the first implementation:

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

Add a fee catalog in code rather than a new table first.

Suggested module:

- `MoneyTree.Loans.RefinanceFeeCatalog`

Responsibilities:

- define canonical categories and default labels
- define whether a category defaults to true cost or timing cost
- define whether a category is usually paid at closing
- expose preset fee templates for scenario seeding
- provide display ordering and grouping

### Future Additive Fields

Add these only if source traceability becomes too awkward in `notes` or `category`:

- `source_type` - `manual`, `lender_quote`, `document_extraction`, `catalog_default`, `provider_estimate`
- `source_id` - nullable string or UUID reference captured as text
- `review_status` - `draft`, `user_confirmed`, `user_modified`
- `calculation_basis` - `fixed`, `percentage_of_loan`, `quote`, `document`, `manual`

Do not add these until a focused implementation needs them.

## Fee Taxonomy

Use these canonical categories in the catalog:

| Category | Default Kind | True Cost | Prepaid/Escrow | Notes |
| --- | --- | --- | --- | --- |
| `origination` | `fee` | yes | no | lender origination or underwriting charge |
| `discount_points` | `fee` | yes | no | points paid to buy down rate |
| `appraisal` | `fee` | yes | no | third-party appraisal |
| `credit_report` | `fee` | yes | no | credit report or verification |
| `title_lender_policy` | `fee` | yes | no | lender title policy |
| `title_settlement` | `fee` | yes | no | settlement, escrow, or closing agent charge |
| `recording` | `fee` | yes | no | government recording charges |
| `transfer_tax` | `fee` | yes | no | where applicable |
| `prepaid_interest` | `timing_cost` | no | yes | timing/cash-flow item |
| `escrow_deposit` | `timing_cost` | no | yes | timing/cash-flow item |
| `property_tax_proration` | `timing_cost` | no | yes | timing/cash-flow item |
| `homeowners_insurance` | `timing_cost` | no | yes | timing/cash-flow item |
| `lender_credit` | `lender_credit` | yes | no | reduces true refinance cost |
| `escrow_refund` | `escrow_refund` | no | yes | can offset timing/cash-to-close context |
| `waived_fee` | `waived_fee` | yes | no | explicit waived cost |
| `other_credit` | `other_credit` | context-dependent | context-dependent | require user review |

## Implementation Phases

### Phase 1: Fee Catalog Foundation

Status: Ready.

Tasks:

- Add `MoneyTree.Loans.RefinanceFeeCatalog`.
- Add tests for catalog categories, defaults, grouping, and signed-cost behavior expectations.
- Keep catalog output as plain maps or structs local to the Loans domain.
- Do not change database schema.

Acceptance criteria:

- Code can ask for all known refinance fee categories.
- Code can ask for default attrs for a category.
- Defaults map cleanly to `RefinanceFeeItem.changeset/2`.

### Phase 2: Fee Strategy Service

Status: Ready after Phase 1.

Suggested module:

- `MoneyTree.Loans.RefinanceFeeStrategy`

Tasks:

- Add deterministic helpers to build editable fee-item attrs from:
  - catalog defaults
  - lender quote totals
  - confirmed document extraction fields
  - scenario points and lender credit
- Add guardrails so strategy output never overwrites existing user fee rows automatically.
- Prefer returning attrs for review over inserting rows directly, except where current flows already insert quote/extraction-derived rows.

Acceptance criteria:

- Existing quote conversion keeps working.
- Existing extraction conversion keeps working.
- New strategy helpers return explicit source labels in `notes` until source fields are added.
- Unit tests cover true-cost totals vs timing-cost totals.

### Phase 3: Loan Center Fee UX Cleanup

Status: Ready after Phase 2.

Tasks:

- Rework the Refinance workspace cost assumptions section into grouped fee cards:
  - True refinance costs
  - Prepaids and escrow timing
  - Credits and offsets
- Add a clear "Add common fees" action that seeds editable draft rows from the catalog.
- Keep manual "Add fee item" available for custom rows.
- Show a compact explanation of how each group affects break-even and cash-to-close.
- Avoid showing every form by default.

Acceptance criteria:

- User can seed common fees for a scenario without typing every category manually.
- Seeded rows remain editable.
- UI clearly distinguishes break-even costs from cash-flow timing.
- Existing scenario analysis table remains usable and not more crowded.

### Phase 4: Missing-Fee Warnings And Incomplete Analysis Labels

Status: Ready after Phase 2.

Tasks:

- Add deterministic fee assumption status, likely in `MoneyTree.Loans.RefinanceFeeStrategy`.
- Warn when a scenario has no fee items.
- Warn when only generic national assumptions are used.
- Warn when escrow/prepaid data is missing.
- Label break-even as incomplete when there are no true-cost assumptions.
- Avoid presenting `True cost $0.00` as complete unless the user explicitly confirms zero-cost assumptions.

Suggested warning text:

```text
This scenario does not include refinance fee assumptions yet. Break-even and cash-to-close values are incomplete.
```

```text
This scenario uses generic national fee estimates. Actual lender, title, recording, and escrow charges may vary.
```

Acceptance criteria:

- No-fee scenarios are visibly incomplete in the Refinance workspace.
- Existing deterministic analysis still runs, but warnings reduce confidence.
- Tests cover no-fee and generic-assumption warning states.

### Phase 5: Quote And Document Fee Mapping

Status: Partial, refine after Phase 2.

Current behavior already maps quote/document totals into fee items. This phase should make the mapping more structured.

Tasks:

- Route quote-derived fee rows through `RefinanceFeeStrategy`.
- Route document-derived fee rows through the same strategy.
- Preserve current behavior and tests while centralizing classification.
- Add tests for:
  - closing costs as true costs
  - cash-to-close amount above closing costs as timing cost
  - lender credit as credit
  - prepaid/escrow values not inflating break-even

Acceptance criteria:

- Quote conversion and extraction conversion share classification rules.
- The result is still user-reviewable and editable.

### Phase 6: Market Context, Not Fee Authority

Status: Ready after Phase 3.

Market benchmarks can enrich fee strategy but should not generate personalized costs.

Tasks:

- Use `Loans.mortgage_market_snapshot/0` only to explain market context beside fee assumptions.
- If market data is stale or incomplete, show warnings from snapshot quality.
- Do not infer closing costs from FRED rates.
- If future manual/provider imports include lender-advertised fee ranges, keep them as supplemental observations or quotes, not guaranteed offers.

Acceptance criteria:

- Fee UI can show market context without changing fee rows.
- Stale market data is labeled.
- No benchmark rate is described as a user offer.

### Phase 7: Optional Persistent Fee Templates

Status: Future, only after static catalog and estimator prove useful.

The uploaded plan suggested a reusable table named `refinance_fee_templates`. That shape is reasonable, but it should not be first because the current repo can validate the behavior without a migration.

Potential table:

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
- `manual_only`
- `per_county_schedule` in a later localized phase

Supported `confidence_level` values:

- `low`
- `moderate`
- `high`

Do not store provider secrets or external API keys in fee templates.

## Initial Static Assumptions

Add conservative national defaults first. These are not exact lender pricing. They exist to prevent zero-cost analysis and to help users understand likely ranges.

These defaults should be clearly labeled as generic assumptions until the user enters a lender quote or imports a Loan Estimate.

| Fee | Category | Kind | Low | Expected | High | Notes |
| --- | --- | --- | ---: | ---: | ---: | --- |
| Origination | `origination` | true cost | 0.00% | 0.50% | 1.00% | Percent of new loan amount |
| Discount points | `discount_points` | true cost | 0.00% | 0.00% | user-defined | Usually 1 point = 1% of loan amount |
| Appraisal | `appraisal` | true cost | $400 | $650 | $900 | May be waived for some refis |
| Credit report | `credit_report` | true cost | $25 | $50 | $100 | Small third-party fee |
| Flood certification | `flood_certification` | true cost | $10 | $20 | $40 | Mortgage-specific |
| Title search | `title_search` | true cost | $150 | $300 | $600 | Varies by state/provider |
| Title insurance | `title_insurance` | true cost | 0.20% | 0.40% | 0.80% | Very state-dependent |
| Settlement/closing | `settlement_or_closing` | true cost | $300 | $600 | $1,200 | Escrow/closing/settlement agent |
| Recording | `recording` | true cost | $50 | $150 | $400 | State/county dependent |
| Attorney/notary | `attorney_or_notary` | true cost | $0 | $250 | $900 | State-dependent; optional in many states |
| Release fee | `release_fee` | true cost | $0 | $75 | $200 | Payoff/release related |
| Prepaid interest | `prepaid_interest` | timing cost | computed | computed | computed | Depends on closing date and daily interest |
| Initial escrow deposit | `escrow_deposit` | timing cost | $0 | computed | computed | Depends on taxes/insurance and escrow setup |
| Homeowners insurance prepaid | `homeowners_insurance` | timing cost | $0 | user/current policy | user/current policy | Often not a true new cost |
| Property tax escrow | `property_tax_escrow` | timing cost | $0 | computed | computed | Based on tax due dates if known |
| Old escrow refund | `old_escrow_refund` | offset | $0 | estimated current escrow balance | user-confirmed | Shown separately from true costs |
| Lender credit | `lender_credit` | offset | $0 | $0 | user-entered | Usually tied to rate/APR tradeoff |

## Calculation Rules

### Fee Amount Calculation

For each catalog entry, generate low / expected / high fee item attrs.

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

### Lender Credits

Lender credits should be credit/offset items.

Rules:

- reduce cash to close
- may reduce true refinance cost depending on how the quote presents them
- should not be silently assumed
- should be tied to quote/rate assumptions when imported from a lender quote

### Prepaid Interest

Prepaid interest should be computed if the user provides an assumed closing date.

Suggested formula:

```text
daily_interest = new_principal_amount * annual_rate / 365
prepaid_interest = daily_interest * days_until_first_payment_period
```

Keep this estimate editable because lenders calculate prepaid interest based on exact closing and first-payment timing.

### Escrow And Prepaids

Escrow funding should be shown as cash timing, not true cost.

If existing mortgage or asset data later includes escrow inputs, use it as an estimate source:

- current property tax amount
- homeowners insurance amount
- flood insurance amount
- current escrow balance if available
- expected old escrow refund if available

If no escrow data exists, show an explicit missing-data warning.

## Generated Scenario Behavior

When a scenario is created from a benchmark rate, MoneyTree should offer to add estimated fee assumptions.

Suggested options:

- `No fees yet` - allowed, but produces a warning and disables strong recommendations.
- `Use generic national estimates` - generates editable low / expected / high fee items.
- `Use state/local estimates` - future option.
- `Enter lender quote manually` - user enters real quote values.
- `Import Loan Estimate` - document extraction workflow.

Do not automatically overwrite user-entered fee items when assumptions are refreshed. Offer a review step instead.

## Source Priority

When multiple fee sources exist, use this priority order:

1. User-confirmed lender quote or Loan Estimate
2. User-entered manual fee items
3. Parsed document values after user confirmation
4. State/local fee template
5. Generic national fee template
6. No fee assumptions, with warning

Never let generic assumptions override user-confirmed values without review.

## Suggested Context Functions

Names should follow repo conventions, but useful functions include:

```elixir
list_refinance_fee_catalog_entries(filters)
estimate_refinance_fee_range(scenario, opts)
generate_refinance_fee_item_attrs_for_scenario(scenario, opts)
create_generic_refinance_fee_items(user, scenario, opts)
fee_assumption_status(scenario)
```

If persistent templates are added later, extend with:

```elixir
list_refinance_fee_templates(filters)
get_refinance_fee_template!(id)
create_refinance_fee_template(attrs)
update_refinance_fee_template(template, attrs)
disable_refinance_fee_template(template)
```

## Future Work Alignment

### Persistent Snapshot Cache

Do not add a cache for fee strategy v1.

Add a persistent `loan_market_snapshots` cache only when repeated reads become expensive or when these features need shared snapshot inputs:

- dashboards
- alerts
- AI summaries
- refinance opportunity scoring
- trend widgets across multiple loans

Fee strategy should call existing snapshot functions until that need is real.

### Lock-Period Metadata

`LenderQuote` already has `lock_available` and `lock_expires_at`, but not `lock_period_days`.

Future additive fields:

- `loan_lender_quotes.lock_period_days`
- `loan_rate_observations.lock_period_days` if provider/manual observations include lock-period semantics

Do not add lock-period fields to FRED observations. FRED benchmark averages are not lock-period-specific personalized pricing.

### Refinance Opportunity Score

Do not implement in this fee strategy pass.

The eventual score should be rule-based and explainable, using:

- payment reduction
- break-even months
- full-term finance cost delta
- true refinance cost
- expected years before sale/refi
- market trend context
- data quality
- quote freshness
- lock availability
- user-entered or confirmed equity/LTV inputs

The score must never imply loan approval or a guaranteed offer.

### Enterprise Providers

ICE Mortgage Technology and Optimal Blue remain future provider candidates.

If added later, they should enter through the provider architecture documented in `docs/loan-center-market-rate-provider-implementation-plan.md`, not through fee UI components. Provider-derived lender pricing should create attributed lender quotes or supplemental market observations for user review.

## Test Plan

Unit tests:

- catalog category defaults
- strategy attrs for common fee rows
- true-cost total excludes prepaid/escrow timing items
- timing-cost total includes prepaid/escrow/timing items
- credits reduce applicable totals
- quote/extraction mapping remains deterministic

LiveView tests:

- Refinance workspace shows grouped cost assumptions.
- "Add common fees" seeds editable fee rows.
- Manual custom fee row still works.
- Seeded fees update break-even and cash-to-close outputs correctly.
- Fee seeding does not overwrite existing fee items.

Regression tests:

- lender quote conversion still creates a draft scenario with seeded fees
- confirmed document extraction still creates scenario/quote rows with fee items
- market snapshot warnings do not break Refinance workspace

## Validation

For any implementation slice:

- Run focused Loans tests.
- Run focused Loan Center LiveView tests.
- Run `mix test` before marking a phase done.
- Apply migrations immediately if a later phase adds schema fields.

## Open Implementation Choice

The first coding slice should be Phase 1 only: `RefinanceFeeCatalog` plus tests. It is low risk, requires no migration, and gives later UI/strategy work a stable vocabulary.
