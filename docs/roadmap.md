# MoneyTree roadmap

Last consolidated: 2026-07-27

This file is the canonical status and sequencing view for work described across `docs/`. Current
technical behavior is documented in [`architecture/`](architecture/README.md); completed and
superseded plans are indexed in [`archive/`](archive/README.md).

## Product and architecture direction

- Keep one Phoenix/LiveView application runtime. Next.js has been removed.
- Keep SimpleFIN Bridge and manual import as the default account-data strategy.
- Keep Plaid optional and disabled unless explicitly configured. Do not restore Teller or Stripe.
- Keep financial calculations deterministic and source-backed.
- Keep AI and document extraction review-first; generated output must not silently become canonical.
- Keep provider-specific behavior behind adapters while domain contexts own persistence,
  deduplication, tenant authorization, and audit state.

## Past work

| Capability | Status | Source |
| --- | --- | --- |
| Transaction identity, duplicate detection, and internal-transfer matching | Completed for the manual-import MVP. | [Archived prerequisite plan](archive/00-transaction-identity-transfer-matching-prerequisites.md) |
| Manual CSV/XLSX import, staged review, commit, rollback, and AI category hints | Core flow completed and available in Phoenix LiveView/API. | [Archived manual-import plan](archive/02-manual-transaction-import-implementation-plan.md) |
| SimpleFIN-first bank linking and synchronization | V1 migration completed; manual import remains the fallback. | [Archived SimpleFIN guide](archive/03-simplefin-bridge-migration-implementation-guide.md) |
| Runtime consolidation | Next.js, Stripe, and the active Teller integration were removed; Phoenix/LiveView is the application surface. | [Architecture baseline](architecture/README.md) |
| Loan Center | Refinance math, scenarios, documents/OCR, reviewed AI extraction, lender quotes, FRED rates, alerts, and non-mortgage loan shells completed. | [Archived Loan Center plan](archive/03-mortgage-center-implementation-plan.md) |
| Structured refinance fees | V1 prediction, fee taxonomy, quote analysis, Louisiana profiles, and visible incomplete-data warnings completed. | [Archived fee subsystem](archive/loan-fee-subsystem-implementation-plan.md) |
| FRED market benchmarks | Provider adapter, persistence, scheduled imports, trends, quality labels, and Loan Center presentation completed. | [Market-rate provider reference](architecture/loan-center-market-rate-provider-implementation-plan.md) |
| Local-first AI assistance | Ollama settings, diagnostics, persisted runs/suggestions, categorization review, recurring candidates, import hints, and loan-document extraction completed. | [Archived Ollama plan](archive/04-ollama-ai-finance-assistant-implementation-plan.md) |
| App shell, navigation, dashboard, and visual-system overhaul | Planned structural work completed in Phoenix. | [App shell](archive/99-app-shell-and-navigation-plan.md), [UI/UX](archive/99-ui-ux-implementation-plan.md), [dashboard](archive/100-dashboard-overhaul-implementation-plan.md) |
| Payment obligations and notifications | V1 obligations, evaluation worker, durable notification events, delivery audit, settings, and UI completed. | [Archived obligations guide](archive/99-payment-obligations-implementation-guide.md) |
| Initial financial evaluations | Deterministic status summary, JSON endpoint, `/app/evaluations`, dashboard entry points, and notification integration completed. | [Active evaluation plan](04-financial-evaluation-implementation-plan.md) |
| OpenBao application integration | Environment/OpenBao provider boundary, AppRole KV reads, owner-only health status, local validation, production policy, and runbook completed. | [OpenBao architecture plan](architecture/openbao-security-implementation-plan.md) |
| Bills & Subscriptions naming and categorization | Renamed the user-facing Obligations workspace to Bills & Subscriptions and replaced `obligation_type` with an expense-category taxonomy (subscription, utility, insurance, housing, debt_payment, tax_or_fee, membership, other), including a data migration for existing rows. Internal context, table, routes, and JSON fields intentionally unchanged. | [Archived rename plan](archive/101-bills-and-subscriptions-rename-implementation-plan.md) |
| Vehicle and tangible-asset management | Direct ownership, encrypted vehicle profiles, append-only valuations, linked-debt equity, progressive MarketCheck onboarding, persistent quota controls, scheduled refresh, and source/range/trend history presentation completed and validated with the configured provider. | [Archived vehicle-assets plan](archive/102-vehicle-asset-management-implementation-plan.md) |

## Current work

Work in this section is sequenced, not parallel by default.

1. **Financial evaluation expansion**
   - Add evaluation-owned data only where no current domain owns the facts.
   - Sequence insurance and rent profiles after the completed Bills & Subscriptions rename and
     coordinate vehicle evaluation work with the asset schema from plan 102.
   - Preserve deterministic statuses and review-first document extraction.
   - Source: [financial evaluation plan](04-financial-evaluation-implementation-plan.md).

2. **Investment portfolio management, Phase 1**
   - Add manual investment accounts, instruments, an append-only activity ledger, tax lots,
     manually entered end-of-day pricing, and deterministic positions.
   - Keep contributions separate from returns and expose explicit insufficient-data states.
   - After manual positions and Plan 102 net-equity calculations are ready, perform the explicit
     household net-worth integration across tangible assets and investments in one pass, with
     linked-debt and investment-account double-count prevention.
   - Defer automated prices and AI narrative until the manual ledger and analytics are proven.
   - Source: [103 implementation plan](103-investment-portfolio-implementation-plan.md).

3. **OpenBao production readiness**
   - Validate a real staging/production deployment with persistent storage, TLS, network controls,
     least-privilege AppRole, FRED and other required secret groups, rotation, and rollback.
   - Reduce redundant plaintext production secrets only after a successful cutover.
   - Source: [production runbook](architecture/openbao-production-runbook.md).

## Deferred work

Deferred items have value but are intentionally not in the immediate execution queue.

- **Plaid expansion:** keep the optional adapter legacy-disabled. Do not resume the older Plaid-first
  plan unless SimpleFIN coverage or product requirements materially change.
- **Standalone RefiSignal:** MoneyTree-integrated refinance functionality is complete; standalone
  packaging and branding require a separate product decision.
- **Loan-market enhancements:** persistent market snapshots, lock-period metadata, a transparent
  rule-based opportunity score, and enterprise providers remain deferred.
- **Loan-fee hardening:** expand direct parish source coverage, exact endorsement pricing,
  prediction snapshots, and broader non-mortgage source data when reliable sources exist.
- **Transfer/reconciliation depth:** broader bulk adjudication and historical reconciliation tooling
  remain follow-up work beyond the safe import flow.
- **Notification channels:** SMS/push providers and deeper operational delivery analytics remain
  deferred beyond the current durable email/in-app pipeline.
- **Persisted cross-domain evaluation results:** add only when transient evaluation summaries no
  longer satisfy history, deduplication, or audit needs.
- **Generalized document imports:** wait for a second real non-loan document workflow before
  extracting a shared framework.

## Future work

- **Vehicle valuation provider follow-ups:** evaluate MarketCheck webhook subscriptions after their
  event/signature/quota contract is verified; consider KBB or J.D. Power later behind the same
  provider boundary.
- **Insurance and rent evaluation domains:** model renewal, premium/rent, verification, and staleness
  without duplicating Assets, Loans, or Obligations.
- **Automated investment market data:** add Twelve Data after the manual ledger is proven and a
  real API contract/key can be validated; keep source and freshness visible.
- **Advanced portfolio phases:** add charting, TWR/XIRR where inputs are complete, optional
  read-only Ollama narrative, and advanced tax-lot/risk analytics incrementally.
- **Crypto holdings:** keep outside the first investment model until crypto-specific tax-lot and
  corporate-action assumptions are explicitly designed.
- **Non-mortgage benchmark depth:** add source-backed auto refinance, used-auto, personal-loan, and
  student-loan benchmark data with clear APR/term/credit assumptions.
- **Additional jurisdiction coverage:** use the
  [parish research template](architecture/loan-fee-parish-research-template.md) and retain source,
  verification date, and confidence for every modeled rule.
- **Evaluation-driven workflows:** add insurance/rent/vehicle document extraction and persisted
  evaluation history only when the corresponding reviewed domain records exist.

## Roadmap maintenance

- Update this file when a plan starts, pauses, completes, or is superseded.
- Move completed plans to `docs/archive/` and record the result under Past work.
- Keep technical truth in `docs/architecture/`; avoid using archived plans as current setup guides.
- Create a focused implementation plan before beginning any future item that changes schemas,
  providers, or cross-domain financial semantics.
