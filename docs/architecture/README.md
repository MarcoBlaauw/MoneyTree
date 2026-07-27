# Architecture and technical references

This folder contains current technical, operational, integration, and domain-research references.
Completed or superseded implementation plans belong in [`../archive`](../archive/README.md), while
active product work is summarized in [`../roadmap.md`](../roadmap.md).

## Current architecture baseline

- MoneyTree is a Phoenix/LiveView application; the separate Next.js application has been removed.
- `apps/money_tree` owns the application runtime and `apps/ui` owns shared Tailwind/UI styling.
- PostgreSQL is the system of record and Oban runs scheduled/background work.
- SimpleFIN Bridge and manual imports are the default account-data paths.
- Plaid is optional and legacy-disabled by default. The active Teller integration and Stripe have
  been removed; historical Teller-shaped fields may remain for safe legacy-data reads.
- Secrets resolve through the environment or OpenBao provider boundary.
- FRED supplies public benchmark data; Ollama is an optional local-first AI provider.

Evidence for this baseline lives in `README.md`, `apps/money_tree/lib/money_tree_web/router.ex`,
`apps/money_tree/lib/money_tree/application.ex`, `config/config.exs`, and `config/runtime.exs`.

## Runtime and integration references

| Document | Purpose |
| --- | --- |
| [Environment variables](environment-variables.md) | Canonical runtime configuration reference. |
| [Account metadata](account-metadata.md) | Account metadata fields and provider normalization notes. |
| [Vendor integrations](vendor-integrations.md) | Browser CSP origins and embedded-provider boundaries. |
| [Plaid runbook](plaid_runbook.md) | Operations for the optional, explicitly enabled Plaid adapter. |
| [OpenBao production runbook](openbao-production-runbook.md) | Production provisioning, cutover, validation, rotation, and rollback. |
| [OpenBao security implementation](openbao-security-implementation-plan.md) | Secret-provider architecture and remaining production-hardening work. |
| [Loan market-rate providers](loan-center-market-rate-provider-implementation-plan.md) | FRED adapter, normalized benchmark semantics, and provider expansion boundaries. |

## Loan-fee and jurisdiction references

| Document | Purpose |
| --- | --- |
| [Loan-fee regulatory research](loan-fee-regulatory-research.md) | Federal/state concepts and modeling guardrails. |
| [Louisiana verification notes](loan-fee-louisiana-verification-notes.md) | Current Louisiana assumptions and verification gaps. |
| [Louisiana parish/title normalization](louisiana-mortgage-title-fees-parish-level.md) | Implementation-ready parish and title-fee source mapping. |
| [Parish research template](loan-fee-parish-research-template.md) | Repeatable source/provenance template for additional jurisdictions. |
| [Deep research report](deep-research-report.md) | Parish recording and title-insurance source synthesis. |
| [Extended deep research](deep-research-report-2.md) | Additional mortgage, auto, personal, and student-loan research. |
| [Source PDF](loan-fee-deep-research-sources.pdf) | Source-bearing research export. |

## Maintenance rules

- Update technical references when runtime behavior changes.
- Put execution status and sequencing in `docs/roadmap.md`, not in multiple competing plans.
- Archive an implementation plan once its scoped acceptance criteria are met or it is superseded.
- Historical documents may mention removed systems; the current baseline above and the roadmap take
  precedence.
