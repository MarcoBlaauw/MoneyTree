# Loan Center Refinance Fee Strategy

## Status

Archived as implemented for the current MoneyTree Loan Center scope as of 2026-05-26.

This plan was originally written to prevent refinance analysis from treating missing fees as a complete `$0.00` cost scenario. That intended functionality is now implemented through the broader structured loan-fee subsystem and Loan Center refinance workspace.

Do not use this document to schedule the older no-migration `RefinanceFeeCatalog` or `RefinanceFeeStrategy` path. That path was superseded by `docs/archive/loan-fee-subsystem-implementation-plan.md`.

## Implemented Current State

The active implementation now lives in the Loans domain:

- `apps/money_tree/lib/money_tree/loans.ex`
- `apps/money_tree/lib/money_tree/loans/refinance_scenario.ex`
- `apps/money_tree/lib/money_tree/loans/refinance_fee_item.ex`
- `apps/money_tree/lib/money_tree/loans/refinance_calculator.ex`
- `apps/money_tree/lib/money_tree/loans/fee_prediction_engine.ex`
- `apps/money_tree/lib/money_tree/loans/fee_quote_analyzer.ex`
- `apps/money_tree/lib/money_tree/loans/loan_fee_defaults.ex`
- `apps/money_tree/lib/money_tree/loans/loan_fee_type.ex`
- `apps/money_tree/lib/money_tree/loans/loan_fee_jurisdiction_profile.ex`
- `apps/money_tree/lib/money_tree/loans/loan_fee_jurisdiction_rule.ex`
- `apps/money_tree/lib/money_tree/loans/lender_quote_fee_line.ex`
- `apps/money_tree/lib/money_tree_web/live/loans_live/index.ex`

Persistence for the completed strategy is provided by:

- `refinance_fee_items` as editable per-scenario fee rows
- `loan_fee_types` as canonical fee definitions
- `loan_fee_jurisdiction_profiles` as loan-type and geography-specific fee profiles
- `loan_fee_jurisdiction_rules` as localized fee calculation rules
- `loan_lender_quote_fee_lines` as structured lender quote fee review rows

The current implementation covers the original fee-strategy goals:

- refinance scenarios no longer need to rely on silent zero-cost assumptions
- fee assumptions can be seeded through "Add common fees"
- seeded fee rows remain editable and reviewable
- true refinance costs are separated from prepaid, escrow, and timing costs
- credits and offsets are modeled separately from fees
- deterministic analysis remains in Elixir code
- quote and document-derived values can create reviewable fee/scenario records
- no imported market benchmark is treated as a personalized lender offer
- missing, generic, sparse, or low-confidence assumptions are surfaced through warnings/status

## Superseded Design Choices

These older recommendations should not be implemented as written:

- Add `MoneyTree.Loans.RefinanceFeeCatalog`
- Add `MoneyTree.Loans.RefinanceFeeStrategy`
- Keep first-pass fee definitions only in code
- Add a future `refinance_fee_templates` table

Those ideas were replaced by the durable loan-fee subsystem. Any future fee configuration work should extend `loan_fee_types`, jurisdiction profiles, and jurisdiction rules rather than introducing a parallel catalog/template model.

## Current Fee Strategy

Use this source priority when presenting or applying refinance fee assumptions:

1. User-confirmed lender quote or Loan Estimate-derived values
2. User-entered manual fee items
3. Confirmed document extraction values
4. State/local fee profile rules
5. Generic or sparse default fee profile rules
6. No assumptions, with explicit incomplete-analysis warning

Rules that remain binding:

- Never silently overwrite user-entered or user-confirmed fee items.
- Never treat missing fee assumptions as a complete zero-cost scenario.
- Keep lender/title/recording/origination costs separate from escrow and prepaid timing costs.
- Keep fee estimates editable.
- Keep market-rate observations as context, not offers.
- Do not use AI-generated fee values as authoritative calculations.

## Remaining Work

The intended functionality of this plan is complete. Remaining items are future enhancements, not blockers for archiving this guide.

### Localized Data Hardening

Improve source quality for existing and future jurisdiction rules:

- parish/county source URL verification
- exact Louisiana endorsement pricing where source-backed
- broader non-Louisiana mortgage refinance profiles
- broader auto refinance fee research
- source-backed personal/student loan fee research before expanding sparse estimates

### Fee Provenance

Only add more provenance fields if the current combination of fee type, quote fee lines, document extraction records, and notes becomes insufficient.

Potential additive fields on `refinance_fee_items` could include:

- `source_type`
- `source_id`
- `review_status`
- `calculation_basis`

Do not add these preemptively. Use the existing structured quote/document/fee-type records first.

### Prediction Snapshots

Consider persisted prediction snapshots only when there is a concrete consumer that needs historical comparison or reproducibility beyond current analysis results.

Possible consumers:

- dashboards
- financial evaluations
- alerts
- AI summaries
- future opportunity scoring

### Refinance Opportunity Score

Still deferred. If implemented later, it must be rule-based and explainable. It should use current deterministic outputs such as:

- payment change
- break-even months
- true refinance cost
- cash-to-close timing cost
- full-term and fixed-horizon interest deltas
- expected years before sale/refinance
- quote freshness
- market data quality
- fee assumption confidence

It must not imply approval, eligibility, legal compliance, or a guaranteed lender offer.

### Provider Expansion

Enterprise or lender-pricing providers remain future work. If added, they should enter through the existing Loans provider/quote architecture:

- market context through rate observations
- user-specific offers through lender quotes
- fee rows only after review or explicit conversion

Do not couple provider-specific logic directly to Loan Center UI components.

## Validation References

Relevant focused checks for future changes:

```sh
mix test apps/money_tree/test/money_tree/loans/loan_fee_subsystem_test.exs
mix test apps/money_tree/test/money_tree/loans/refinance_calculator_test.exs
mix test apps/money_tree/test/money_tree_web/live/loans_live_test.exs
```

For schema-affecting changes, apply migrations to the development database before treating work as complete.

## Archive Boundary

This document is archived for implementation planning. Keep it as historical context for why refinance fee assumptions exist and why missing fees must be visibly incomplete.

Use these active documents for future work:

- `docs/archive/loan-fee-subsystem-implementation-plan.md`
- `docs/architecture/loan-center-market-rate-provider-implementation-plan.md`
- `docs/archive/03-mortgage-center-implementation-plan.md`
