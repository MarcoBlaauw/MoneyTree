# Archived implementation plans

These documents are retained for design history, acceptance criteria, and deferred ideas. They are
not the current execution queue. Some preserve historical references to Next.js, Teller, or earlier
product names; those references describe the repository at the time and must not be treated as
current architecture.

Use [`../roadmap.md`](../roadmap.md) for current sequencing and
[`../architecture`](../architecture/README.md) for current technical references.

| Document | Archive reason |
| --- | --- |
| [Transaction identity and transfer prerequisites](00-transaction-identity-transfer-matching-prerequisites.md) | Completed for the manual-import MVP. |
| [Plaid integration plan](01-plaid-integration-implementation-plan.md) | Superseded by the SimpleFIN-first direction; Plaid remains optional and on hold. |
| [Manual transaction import plan](02-manual-transaction-import-implementation-plan.md) | Completed for the short-term import goal. |
| [Loan Center plan](03-mortgage-center-implementation-plan.md) | All defined Loan Center phases are marked done. |
| [SimpleFIN migration guide](03-simplefin-bridge-migration-implementation-guide.md) | SimpleFIN-first v1 migration completed; subsequent Teller/Next cleanup has occurred. |
| [Ollama assistant plan](04-ollama-ai-finance-assistant-implementation-plan.md) | Core provider, settings, suggestion persistence, review flows, recurring integration, and import assistance are implemented. |
| [RefiSignal plan](04-refisignal-standalone-moneytree-implementation-plan.md) | Integrated scope completed in Loan Center; standalone packaging is a future product decision. |
| [App shell and navigation](99-app-shell-and-navigation-plan.md) | Phoenix app-shell/navigation scope completed. |
| [Payment obligations guide](99-payment-obligations-implementation-guide.md) | V1 backend, delivery, dashboard, settings, and history surfaces completed. |
| [UI/UX implementation plan](99-ui-ux-implementation-plan.md) | Structural dashboard/restyling scope completed. |
| [Dashboard overhaul](100-dashboard-overhaul-implementation-plan.md) | All nine planned slices completed. |
| [Refinance fee strategy](loan-center-refinance-fee-strategy.md) | Superseded and completed by the structured loan-fee subsystem. |
| [Loan-fee subsystem plan](loan-fee-subsystem-implementation-plan.md) | V1 persistence, prediction, quote analysis, Louisiana starter data, and Loan Center integration completed. |
| [Bills & Subscriptions rename plan](101-bills-and-subscriptions-rename-implementation-plan.md) | UI rename and obligation-type taxonomy realignment completed; internal context/table/routes intentionally unchanged. |
| [Vehicle and tangible-asset plan](102-vehicle-asset-management-implementation-plan.md) | Manual and provider-backed vehicle assets, valuation history, linked-debt equity, quota controls, and progressive onboarding completed. |

Deferred work mentioned inside archived plans has been normalized into the roadmap instead of keeping
the plans active indefinitely.
