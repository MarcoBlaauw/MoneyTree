# RefiSignal Standalone + MoneyTree Implementation Plan

## Status

Archived as implemented for the MoneyTree-integrated scope as of 2026-05-26.

The original plan proposed building RefiSignal as a refinance decision tool inside MoneyTree first, then preserving enough boundaries to package it as a standalone satellite app later. The MoneyTree-integrated refinance decision functionality now exists under **Loan Center**, not as a separate `RefiSignal` route or product shell.

Do not implement the older phase list as written. Most phases have already landed under the `MoneyTree.Loans` context and `/app/loans` LiveView workspace, with route names and table names corrected from the original mortgage-specific proposal.

Standalone RefiSignal packaging remains a separate future product decision, not unfinished core MoneyTree functionality.

## Implemented Current State

### Product Surface

The integrated product surface is Loan Center:

- `/app/loans`
- `/app/loans/:loan_id`
- `/app/loans/:loan_id/refinance`
- `/app/loans/:loan_id/documents`
- `/app/loans/:loan_id/quotes`
- `/app/loans/:loan_id/alerts`
- compatibility routes under `/app/mortgages`

The code intentionally uses a generic Loan Center direction rather than a mortgage-only RefiSignal shell. Do not add a parallel `/app/refisignal` destination unless there is a renewed product decision to expose RefiSignal as a distinct brand.

### Domain Ownership

The active implementation lives in:

- `MoneyTree.Loans`
- `MoneyTree.Mortgages`
- `MoneyTree.Notifications`
- `MoneyTree.AI`
- `MoneyTreeWeb.LoansLive.Index`

Core files include:

- `apps/money_tree/lib/money_tree/loans.ex`
- `apps/money_tree/lib/money_tree/loans/loan.ex`
- `apps/money_tree/lib/money_tree/loans/refinance_scenario.ex`
- `apps/money_tree/lib/money_tree/loans/refinance_fee_item.ex`
- `apps/money_tree/lib/money_tree/loans/refinance_analysis_result.ex`
- `apps/money_tree/lib/money_tree/loans/refinance_calculator.ex`
- `apps/money_tree/lib/money_tree/loans/amortization.ex`
- `apps/money_tree/lib/money_tree/loans/warning_engine.ex`
- `apps/money_tree/lib/money_tree/loans/lender_quote.ex`
- `apps/money_tree/lib/money_tree/loans/lender_quote_fee_line.ex`
- `apps/money_tree/lib/money_tree/loans/loan_document.ex`
- `apps/money_tree/lib/money_tree/loans/loan_document_extraction.ex`
- `apps/money_tree/lib/money_tree/loans/rate_source.ex`
- `apps/money_tree/lib/money_tree/loans/rate_observation.ex`
- `apps/money_tree/lib/money_tree/loans/alert_rule.ex`
- `apps/money_tree/lib/money_tree_web/live/loans_live/index.ex`

### Completed Capabilities

The MoneyTree-integrated goal is complete:

- reviewed mortgage-backed loan baselines
- generic non-mortgage loans
- deterministic refinance scenario creation and comparison
- amortization, break-even, cash-to-close, fee, escrow/prepaid, and fixed-horizon analysis
- persisted refinance analysis snapshots
- editable refinance fee items
- structured loan fee configuration and jurisdiction rules
- fee prediction ranges and sparse-state warnings
- lender quote tracking
- quote fee-line classification and missing-fee review
- lender quote to scenario conversion
- document metadata and extraction review records
- stored text/PDF/image OCR extraction paths
- Ollama-backed document extraction candidates
- confirmation-gated mortgage/scenario/quote application
- FRED market-rate provider
- manual supplemental market-rate import
- market snapshot, trend, and data-quality labels
- benchmark-seeded review-first scenarios
- Loan Center alert rules
- alert evaluation workers
- durable notification integration
- email delivery through existing notifications
- cooldown behavior to reduce alert noise
- generic loan expansion for auto/personal/student baselines
- auto refinance preview and Louisiana auto fee assumptions

### API And Contracts

The original plan proposed mortgage-specific routes such as `/api/mortgages/:id/refinance_scenarios`. The implemented API is Loan Center-oriented and uses loan IDs where appropriate:

- `/api/loans/:loan_id/refinance_scenarios`
- `/api/refinance_scenarios/:id`
- `/api/refinance_scenarios/:id/fee_items`
- `/api/refinance_scenarios/:id/analyze`
- `/api/loans/:loan_id/documents`
- `/api/loan_documents/:id`
- `/api/loan_document_extractions/:id/...`
- `/api/loans/:loan_id/lender_quotes`
- `/api/lender_quotes/:id`
- `/api/lender_quotes/:id/convert`
- `/api/loans/:loan_id/alert_rules`
- `/api/loan_alert_rules/:id`

Contracts are maintained through `apps/contracts/specs/openapi.yaml` and generated artifacts.

## Superseded Original Plan Items

These original recommendations should not be implemented as written:

- create a separate `MoneyTree.Mortgages` refinance subdomain
- create mortgage-only `refisignal_*` tables
- create a new `/app/refisignal` route as the canonical integrated destination
- add a separate RefiSignal alert subsystem
- add a separate mortgage document pipeline outside Loan Center
- add separate mortgage rate source/observation tables
- create a separate fee template model for RefiSignal

The compatible implementation path is to extend the existing Loan Center modules and tables.

## Remaining Work

The intended MoneyTree-integrated refinance functionality is complete. Remaining work is optional, future-facing, or dependent on new product decisions.

### Standalone Packaging

This is the only major original goal that is not implemented.

Do not begin standalone packaging until there is a concrete product decision covering:

- whether RefiSignal should be a separate brand or remain Loan Center functionality
- whether standalone mode is single-user, hosted multi-tenant, or self-hosted
- authentication model
- deployment model
- billing or access-control requirements, if any
- which Loan Center features belong in the standalone subset

If approved later, the compatible path is extraction-by-boundary, not a rewrite:

- keep deterministic calculation modules in the Loans domain or move them only with compatibility shims
- reuse existing migrations where possible
- expose a route/app shell around existing Loan Center APIs
- do not fork calculation formulas
- do not create a second document extraction or notification system

### Route And Branding Decision

A distinct `/app/refisignal` route should only be added if it is a branding/navigation upgrade over Loan Center.

Acceptable route behavior if added later:

- route to the existing Loan Center refinance workspace
- preserve `/app/loans` as the canonical generic loan destination
- avoid duplicate UI state
- avoid separate RefiSignal-specific persistence

### Provider Expansion

FRED and manual supplemental observations are implemented. Future providers remain deferred:

- active API Ninjas/FMP/Alpha Vantage-style provider adapters
- richer auto refinance benchmark sources
- lender or aggregator quote APIs
- enterprise sources such as ICE Mortgage Technology or Optimal Blue

Provider-derived rates must remain market context unless the source is an actual user-specific quote. User-specific offers should become attributed lender quote records, not automatic scenario mutations.

### Lock-Period Metadata

Current lender quotes support lock availability and lock expiration. Add `lock_period_days` only when provider/manual data actually includes lock-period semantics.

Do not add lock-period fields to FRED benchmark observations.

### Refinance Opportunity Score

Still deferred.

If implemented later, the score must be deterministic, explainable, and visibly sensitive to missing data. It should not imply loan approval, eligibility, legal compliance, or a guaranteed offer.

Recommended inputs:

- payment reduction
- break-even months
- true refinance cost
- timing/cash-to-close cost
- fixed-horizon interest deltas
- full-term interest delta
- expected years before sale/refinance
- quote freshness
- market trend context
- fee assumption confidence
- data quality warnings

### Deeper Document Workflows

The review-first document flow exists. Future work should improve it only where real use shows gaps:

- better extraction field coverage
- improved OCR accuracy
- richer field-level review UI
- document retention/purge controls
- cross-domain reuse for insurance/rent/vehicle documents if evaluation work requires it

Do not introduce a generic document platform until another domain needs it.

### Non-Mortgage Refinement

Auto refinance has a limited usable path. Personal and student loan refinance support remains intentionally sparse.

Before broadening non-mortgage predictions, collect source-backed data for:

- fee rules
- benchmark rates
- refinance-specific rates where available
- source terms and attribution requirements
- credit-tier, LTV, term, new/used, or vehicle-age assumptions

## Implementation Rules For Future Work

Future work should follow these constraints:

- extend `MoneyTree.Loans` before creating new feature-owned contexts
- keep deterministic math in code with tests
- update OpenAPI source before generated contract artifacts
- keep document extraction review-first
- keep AI out of authoritative calculations
- use existing `MoneyTree.Notifications` for alerts and delivery
- preserve existing Loan Center routes and compatibility routes
- prefer additive migrations
- apply schema migrations to the development database before marking schema work complete

## Validation References

Relevant focused checks for future changes:

```sh
mix test apps/money_tree/test/money_tree/loans
mix test apps/money_tree/test/money_tree_web/live/loans_live_test.exs
mix test apps/money_tree/test/money_tree_web/controllers/refinance_scenario_controller_test.exs
mix test apps/money_tree/test/money_tree_web/controllers/lender_quote_controller_test.exs
mix test apps/money_tree/test/money_tree_web/controllers/loan_document_controller_test.exs
pnpm --dir apps/contracts verify
```

For schema-affecting work, run migrations against the active development database.

## Archive Boundary

This document is archived for implementation planning. It should remain as historical context for the RefiSignal product idea and for the decision to implement the refinance decision engine inside Loan Center first.

Use these active documents for future execution:

- `docs/03-mortgage-center-implementation-plan.md`
- `docs/loan-fee-subsystem-implementation-plan.md`
- `docs/loan-center-market-rate-provider-implementation-plan.md`
- `docs/04-financial-evaluation-implementation-plan.md`
