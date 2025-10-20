# Account financial metadata

Accounts now persist additional financial metadata so downstream features can surface more context alongside balances. The new columns live on the `accounts` table and are exposed through `MoneyTree.Accounts.Account`:

- `apr` – stored as a decimal percentage (e.g. `4.25` for 4.25%) and validated to stay between 0 and 100.
- `fee_schedule` – free-form text that captures how maintenance or service fees are applied.
- `minimum_balance` / `maximum_balance` – currency thresholds expressed in the account's native currency.

## Populating the data

There are two supported ways to set these fields:

1. **Manual entry.** Internal operators can populate or override values in admin tooling or via direct database edits. Because the validations live in the `Account` changeset, any UI backed by `MoneyTree.Accounts.Account.changeset/2` will automatically enforce the allowed ranges (non-negative balances, APR ≤ 100, etc.). This path is ideal for institution-specific terms that are negotiated offline.
2. **Aggregator sync.** If an aggregator (e.g. Teller) provides APR or balance requirements in its payloads, extend the ingestion pipeline to map that data into the new columns when accounts are refreshed. The sync layer should only overwrite fields when the upstream value is present to avoid clobbering curated manual entries.

When neither source provides a value the fields remain `NULL`, and the UI omits the corresponding metadata row.

## Operational notes

- APR values appear on the dashboard without masking, while currency thresholds respect the balance toggle and remain hidden until a user reveals balances.
- Fee schedules are rendered verbatim; keep the text succinct and user-facing.
- Validation errors surface in tests under `MoneyTree.Accounts.AccountTest`, offering examples of acceptable inputs and edge cases to cover when wiring new ingestion flows.
