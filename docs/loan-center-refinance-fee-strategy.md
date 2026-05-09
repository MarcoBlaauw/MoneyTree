# Loan Center Refinance Fee Strategy

## Status

This plan is adapted to the current MoneyTree repo state as of May 9, 2026.

Market-rate provider v1 is complete enough to support this work:

- FRED imports are implemented through `MoneyTree.Loans.RateProviders.Fred`.
- Imported benchmark observations are normalized into existing `loan_rate_sources` and `loan_rate_observations`.
- Loan Center already exposes market snapshots, trend windows, source attribution, data-quality warnings, and the required FRED notice.
- Future market-rate work remains intentionally deferred: persistent snapshot cache, lock-period metadata, refinance opportunity score, and enterprise providers such as ICE Mortgage Technology or Optimal Blue.

This fee strategy should build on the current refinance structures instead of introducing a parallel model.

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

### Phase 4: Quote And Document Fee Mapping

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

### Phase 5: Market Context, Not Fee Authority

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
