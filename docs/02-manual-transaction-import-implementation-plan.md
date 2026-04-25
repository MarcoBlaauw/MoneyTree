# Manual Transaction Import Implementation Plan

## Purpose

This document defines the first implementation plan for manual transaction imports in `MoneyTree`.

The Plaid integration plan covers connected-account synchronization, but MoneyTree also needs a reliable fallback path for exported bank and card files such as USAA CSV downloads and American Express XLSX activity exports. Manual import should not be treated as a throwaway utility. It should use the same persistence, categorization, review, and audit principles as connected provider syncs.

Manual import is especially important for:

- accounts that are not yet connected through Plaid
- credit cards or banks with unreliable aggregation support
- historical backfills before a live connection exists
- reconciliation when provider sync misses or changes transactions
- privacy-conscious users who prefer file import over direct institution linking

## Goals

1. Support CSV and XLSX transaction uploads from common financial institutions.
2. Provide institution-specific mapping presets for known export formats.
3. Let users preview, correct, categorize, and exclude rows before committing anything.
4. Persist imports as auditable batches so imported data can be reviewed or rolled back.
5. Detect duplicates before commit and prevent accidental double imports.
6. Match internal transfers and credit card payments so cash flow reports do not double-count movement between accounts.
7. Apply category rules consistently across manual imports and provider syncs.
8. Keep raw uploaded files and parsed rows secure, private, and easy to purge.

## Non-Goals

- replacing Plaid or other live institution integrations
- building a full bookkeeping/general-ledger system in this phase
- importing brokerage lots, investment positions, or tax documents
- relying on AI categorization as the only categorization path
- automatically committing uploaded files without user review
- supporting every bank format in the first release

## Recommended Product Slice

Implement a safe, review-first manual import flow:

1. User selects an account or creates a placeholder/manual account.
2. User uploads a CSV or XLSX file.
3. MoneyTree detects the institution/export preset when possible.
4. User confirms or adjusts field mappings.
5. MoneyTree parses rows into a staging table.
6. User previews rows, duplicate warnings, categories, and transfer-match suggestions.
7. User commits accepted rows into the canonical transaction table.
8. MoneyTree records the import batch and supports rollback.

This is the smallest coherent slice that makes manual import useful without polluting real transaction history.

## Current Surfaces To Inspect

Before implementation, inspect the existing transaction, account, institution connection, and sync modules. The import feature should reuse persistence paths where possible instead of creating a parallel transaction system.

Likely areas to review:

- Phoenix contexts for accounts, transactions, institutions, and synchronization
- existing transaction schemas and changesets
- existing provider transaction identifiers and idempotency rules
- account-linking or institution-connection models
- category models, merchant normalization, or rule systems if present
- dashboard/reporting queries that consume transactions
- Next.js account/transaction pages and navigation shell

If these surfaces do not exist yet, implement the manual import schema in a way that will not block future Plaid/Teller provider syncs.

## Data Model

Add the smallest set of tables needed to stage, audit, commit, and roll back imports.

### `manual_import_batches`

Tracks each uploaded file and import lifecycle.

Suggested fields:

- `id`
- `user_id`
- `account_id` nullable until user chooses or creates an account
- `institution_connection_id` nullable
- `source_institution` such as `usaa`, `american_express`, `chase`, `generic_csv`
- `source_account_label` optional user-facing account label from the file
- `file_name`
- `file_mime_type`
- `file_size_bytes`
- `file_sha256`
- `raw_file_storage_key` nullable if raw files are not retained
- `detected_preset_key`
- `selected_preset_key`
- `mapping_config` JSONB
- `status` enum-like string: `uploaded`, `mapped`, `parsed`, `reviewed`, `committing`, `committed`, `rolled_back`, `failed`
- `row_count`
- `accepted_count`
- `excluded_count`
- `duplicate_count`
- `committed_count`
- `error_count`
- `started_at`
- `committed_at`
- `rolled_back_at`
- timestamps

Rules:

- Do not delete batch records when rolling back.
- Store enough metadata to explain what happened later.
- Use `file_sha256` to warn when the same file is uploaded again.

### `manual_import_rows`

Stores parsed staging rows before commit.

Suggested fields:

- `id`
- `manual_import_batch_id`
- `row_index`
- `raw_row` JSONB
- `parse_status`: `parsed`, `warning`, `error`, `excluded`, `committed`
- `parse_errors` JSONB
- `posted_date`
- `authorized_date` nullable
- `description`
- `original_description`
- `merchant_name`
- `amount`
- `currency` default `USD`
- `direction`: `income`, `expense`, `transfer`, nullable before classification
- `external_transaction_id` nullable
- `check_number` nullable
- `category_id` nullable
- `category_name_snapshot` nullable
- `merchant_rule_id` nullable
- `duplicate_candidate_transaction_id` nullable
- `duplicate_confidence` nullable
- `transfer_match_candidate_transaction_id` nullable
- `transfer_match_confidence` nullable
- `review_decision`: `accept`, `exclude`, `needs_review`
- `committed_transaction_id` nullable
- timestamps

Rules:

- Never commit rows with `parse_status = error`.
- Never commit rows marked `exclude`.
- Keep raw parsed rows for audit until the user purges the batch.

### `manual_import_presets`

Presets may be code-defined at first. A table is optional in the first release. If added, use it for user-defined mappings and custom institution formats.

Suggested fields:

- `id`
- `user_id` nullable for global presets
- `key`
- `display_name`
- `institution_name`
- `file_type`: `csv`, `xlsx`
- `header_detection_config` JSONB
- `column_mapping` JSONB
- `amount_sign_config` JSONB
- `date_format_config` JSONB
- `is_system`
- `is_active`
- timestamps

## Supported File Types

### CSV

Support UTF-8 CSV files first.

Implementation requirements:

1. Detect delimiter where practical, but default to comma.
2. Support quoted values and embedded commas.
3. Trim BOM if present.
4. Preserve original headers and raw row values.
5. Validate required columns before parsing rows.

### XLSX

Support `.xlsx` files using a server-side parser.

Implementation requirements:

1. Read the first worksheet by default.
2. Allow institution presets to specify a header row offset.
3. Ignore empty leading metadata rows.
4. Preserve the workbook sheet name and detected header row in batch metadata.
5. Reject macro-enabled or legacy binary formats unless explicitly supported later.

Do not parse files in the browser as the source of truth. Browser parsing may be used for quick UX hints, but Phoenix must parse and validate the file before staging rows.

## Institution-Specific Presets

Start with system presets for formats already observed:

### USAA Bank CSV

Observed columns:

- `Date`
- `Description`
- `Original Description`
- `Category`
- `Amount`
- `Status`

Mapping:

- `Date` -> `posted_date`
- `Description` -> `description`
- `Original Description` -> `original_description`
- `Category` -> source category snapshot
- `Amount` -> signed amount
- `Status` -> raw metadata

Rules:

- Positive amounts are income/inflows.
- Negative amounts are expenses/outflows.
- Rows with `Status` other than `Posted` should be staged with a warning unless pending imports are intentionally supported.

### American Express XLSX

Observed export includes leading metadata rows before the actual header row.

Observed columns after the header row:

- `Date`
- `Description`
- `Card Member`
- `Account #`
- `Amount`
- `Extended Details`
- `Appears On Your Statement As`
- `Address`
- `City/State`
- `Zip Code`
- `Country`
- `Reference`
- `Category`

Mapping:

- `Date` -> `posted_date`
- `Description` -> `description`
- `Appears On Your Statement As` -> `merchant_name` fallback
- `Extended Details` -> raw metadata
- `Card Member` -> raw metadata
- `Account #` -> source account hint
- `Amount` -> unsigned charge/payment amount, interpreted by row type
- `Reference` -> external transaction ID candidate
- `Category` -> source category snapshot

Rules:

- Purchase rows should import as expenses.
- Credits/payments/refunds must be identified and imported as inflows/credits, not expenses.
- Use `Reference` as part of duplicate detection when present.
- Preserve card member metadata for household reporting, but do not require it for transaction identity.

### Generic CSV

Provide a manual mapping flow for unknown files.

Minimum required fields:

- posted date
- description
- amount, or separate debit/credit columns

Optional fields:

- original description
- merchant
- category
- account
- transaction ID/reference
- check number
- status

## Mapping Flow

The mapping screen should be part of the import wizard and should support:

1. detected preset confirmation
2. manual preset selection
3. manual column mapping
4. date format confirmation
5. amount sign behavior confirmation
6. debit/credit split-column support
7. account selection or account creation
8. import name/notes

Mapping output should be saved as `mapping_config` on the batch so the parse can be reproduced.

For a known preset, default mappings should be prefilled but still visible.

## Import Wizard UX

Recommended steps:

1. Upload
2. Account & preset
3. Mapping
4. Preview & review
5. Commit
6. Results

### Upload

- Accept CSV and XLSX.
- Show maximum file size.
- Show privacy note that files contain financial data.
- Calculate file fingerprint server-side.
- Warn if the same file appears to have been uploaded before.

### Account & Preset

- User selects an existing account or creates a manual account.
- MoneyTree attempts to detect the source preset.
- User can override the preset.

### Mapping

- Show detected columns.
- Show required and optional mappings.
- Preview a few parsed rows live after mapping.
- Validate date and amount parsing before moving forward.

### Preview & Review

Show rows with:

- date
- description / merchant
- amount
- proposed category
- duplicate status
- transfer-match suggestion
- review decision

Allow bulk actions:

- accept all non-duplicate rows
- exclude duplicate candidates
- change category for selected rows
- mark selected rows as transfer
- clear transfer match
- search/filter by merchant, category, warning, duplicate, or amount

### Commit

- Show final counts before commit.
- Require explicit confirmation.
- Commit in a database transaction where practical.
- If async commit is needed for large files, use a worker and make the batch state visible.

### Results

- Show committed count, skipped count, duplicate count, and errors.
- Link to the affected account and transactions.
- Offer rollback for the batch.

## Duplicate Detection

Duplicate detection should be conservative. It should prevent obvious duplicates without hiding legitimate repeated transactions.

### Exact Identity

Use exact identifiers when available:

- provider/source transaction ID
- Amex `Reference`
- check number plus amount/date/account
- imported row fingerprint

### Fingerprint Matching

Create a deterministic fingerprint from normalized fields:

- account ID
- posted date
- normalized description or merchant
- signed amount
- currency
- optional reference/check number

Store a `source_fingerprint` or equivalent on committed transactions when imported manually.

### Fuzzy Matching

For files without reliable identifiers, flag likely duplicates using:

- same account
- same amount
- date within configurable window, such as +/- 3 days
- similar normalized merchant/description

Confidence levels:

- `exact`: block by default
- `high`: exclude by default, user can override
- `medium`: needs review
- `low`: informational only

Do not silently discard rows unless the user has chosen a clear bulk action.

## Import Batches And Commit Semantics

Manual imports must be batch-aware.

Rules:

1. Each upload creates one batch.
2. Parsed rows belong to one batch.
3. Committed transactions should store `manual_import_batch_id` and `manual_import_row_id` where possible.
4. A batch can be committed once.
5. A committed batch can be rolled back only if affected transactions have not been materially changed in ways that would make rollback unsafe.
6. Batch status transitions should be explicit and tested.

Recommended statuses:

- `uploaded`
- `mapped`
- `parsed`
- `reviewed`
- `committing`
- `committed`
- `rollback_pending`
- `rolled_back`
- `failed`

## Rollback

Rollback should undo the import batch without damaging unrelated user edits.

Minimum behavior:

1. Delete or soft-delete transactions created by the batch.
2. Clear `committed_transaction_id` on affected rows.
3. Mark batch as `rolled_back`.
4. Preserve batch and row audit metadata.

Safety checks:

- If a transaction was split, reconciled, matched to a transfer, edited manually, or used in another workflow, require a safer rollback path.
- Prefer soft-delete or reversal markers if hard deletion would break reports.
- Show a rollback preview before applying it.

Rollback should be covered by tests because it is easy to get dangerously wrong.

## Transfer Matching

Manual imports need transfer detection so cash-flow dashboards do not treat money movement as spending.

Examples:

- checking account payment to Amex credit card
- checking account payment to Chase/Discover
- savings transfers to Ally
- Venmo/PayPal transfers where the counterparty transaction may appear separately
- internal transfers between user-owned accounts

Matching rules:

1. Opposite signs.
2. Similar absolute amount.
3. Date within a configurable window, such as +/- 5 days.
4. Known transfer/payment merchant patterns.
5. Different accounts unless explicitly allowed.

Transfer match states:

- `suggested`
- `confirmed`
- `rejected`
- `auto_confirmed` only for very high confidence rules

Dashboard/reporting rules:

- confirmed internal transfers should not count as expenses or income in household cash-flow views
- credit card payments should reduce liability but should not double-count already-imported card purchases
- savings transfers should be visible as savings behavior, not normal spending

## Category Rules

Manual imports should use the same category engine as synced transactions.

Rule inputs:

- normalized merchant
- original description
- source category
- amount
- account type
- card member or household member metadata
- transaction direction

Rule outputs:

- category ID
- confidence
- reason/source rule
- whether user review is needed

Initial default rules should cover common patterns:

- mortgage/rent
- payroll/income
- credit card payments
- internal savings transfers
- auto loans
- student loans
- pool loan / home improvement loan
- utilities, phone, internet
- groceries/household shopping
- dining/coffee
- fuel
- medical/pharmacy
- fees

User rule support:

- Allow users to create rules from a reviewed transaction.
- Allow rules to apply during staging before commit.
- Preserve the rule ID or rule snapshot on the import row for auditability.

Do not let AI override deterministic user rules. If AI suggestions are added later, they should sit below explicit user rules and require review unless confidence is very high.

## Security And Privacy

Financial files are sensitive.

Requirements:

1. Require authentication for all import endpoints.
2. Scope every batch and row by user/household authorization.
3. Validate file type and size server-side.
4. Store raw files only if necessary.
5. If raw files are retained, store them in private object storage with restricted access.
6. Allow users to purge raw files after parsing/commit.
7. Do not log raw transaction rows, full account numbers, card numbers, or uploaded file contents.
8. Do not send raw financial rows to external AI services without explicit opt-in.
9. Sanitize telemetry and error reports.

## API Design

Suggested Phoenix routes:

- `POST /api/manual-imports` upload file and create batch
- `GET /api/manual-imports` list batches
- `GET /api/manual-imports/:id` show batch summary
- `PUT /api/manual-imports/:id/mapping` save mapping config
- `POST /api/manual-imports/:id/parse` parse/stage rows
- `GET /api/manual-imports/:id/rows` list staged rows with filters
- `PATCH /api/manual-imports/:id/rows` bulk update review decisions/categories
- `POST /api/manual-imports/:id/commit` commit accepted rows
- `POST /api/manual-imports/:id/rollback` roll back committed batch
- `DELETE /api/manual-imports/:id/raw-file` purge retained raw file

All write endpoints should require CSRF/session protections consistent with the rest of the app.

## Backend Modules

Suggested modules:

- `MoneyTree.ManualImports`
- `MoneyTree.ManualImports.Batch`
- `MoneyTree.ManualImports.Row`
- `MoneyTree.ManualImports.Parser`
- `MoneyTree.ManualImports.Presets`
- `MoneyTree.ManualImports.DuplicateDetector`
- `MoneyTree.ManualImports.TransferMatcher`
- `MoneyTree.ManualImports.Committer`
- `MoneyTree.ManualImports.Rollback`
- `MoneyTreeWeb.ManualImportController`

Keep parser modules pure where possible so tests can cover them without database setup.

## Frontend Surfaces

Suggested Next.js pages/components:

- `/imports`
- `/imports/new`
- `/imports/[id]`
- upload dropzone component
- account/preset selector
- column mapping table
- staged transaction review grid
- duplicate warning badges
- transfer-match review controls
- commit confirmation modal
- rollback confirmation modal
- import result summary

The review grid should be practical and dense. This is not a marketing page; it is a financial cleanup workflow.

## Reporting Behavior

Manual imports should immediately feed the same reports as synced transactions after commit.

Reporting rules:

- Do not include staged rows in normal dashboards.
- Include committed rows unless excluded by report filters.
- Confirmed internal transfers should be excluded from net spending views by default.
- Savings transfers should be separately reportable.
- Credit card payments should not double-count expenses when the card purchases are also imported.

## Test Strategy

Testing must be implemented alongside the feature, not after.

### Backend Unit Tests

Cover:

- CSV parsing with quoted values, BOM, empty rows, and malformed rows
- XLSX parsing with leading metadata rows
- USAA preset detection and mapping
- Amex preset detection and mapping
- generic CSV mapping validation
- date parsing errors
- amount sign handling
- debit/credit split-column handling
- duplicate fingerprint generation
- fuzzy duplicate confidence levels
- transfer-match suggestions
- category rule application

### Context And Persistence Tests

Cover:

- batch creation
- row staging
- status transitions
- commit creates canonical transactions
- commit is idempotent or safely blocked on repeat
- duplicate rows are skipped or blocked according to review decision
- rollback removes or soft-deletes only batch-created transactions
- rollback refuses unsafe cases
- raw file purge clears storage reference without deleting audit metadata

### Controller Tests

Cover:

- unauthenticated upload rejected
- wrong household/user rejected
- unsupported file type rejected
- oversized file rejected
- successful upload creates batch
- mapping update validates required fields
- parse returns staged row counts
- row bulk update validates permissions and row ownership
- commit requires explicit confirmation
- rollback requires explicit confirmation

### Frontend Tests

Cover:

- upload flow
- preset detection display
- manual mapping validation
- preview table filters
- duplicate warning display
- category bulk-edit interaction
- transfer-match accept/reject interaction
- commit confirmation
- rollback confirmation
- useful error states

### Manual Verification

Verify with real sample exports:

1. USAA CSV bank activity export
2. American Express XLSX activity export
3. generic CSV with single signed amount column
4. generic CSV with separate debit and credit columns
5. re-upload of the same file
6. overlapping files with duplicate rows
7. checking and credit card files imported together to verify transfer/payment matching
8. rollback after commit

## Delivery Order

Recommended implementation order:

1. Add schemas/migrations for batches and rows.
2. Add parser behavior and preset definitions for USAA CSV and Amex XLSX.
3. Add upload and batch creation endpoints.
4. Add mapping save and parse/stage endpoints.
5. Add duplicate detection.
6. Add category rule application.
7. Add transfer matching.
8. Add preview/review UI.
9. Add commit path into canonical transactions.
10. Add rollback.
11. Add raw file purge.
12. Add reporting adjustments for transfer exclusion and savings transfer visibility.
13. Add full tests and manual verification docs.

Each phase should include tests and should keep the app runnable through `./scripts/dev.sh`.

## Completion Criteria

Manual transaction import is complete only when all of the following are true:

1. CSV and XLSX uploads are accepted and validated server-side.
2. USAA CSV and American Express XLSX presets are implemented and tested.
3. Unknown CSV files can be manually mapped.
4. Parsed rows are staged and reviewable before commit.
5. Duplicate candidates are detected and surfaced before commit.
6. Category rules are applied during staging and can be adjusted before commit.
7. Transfer matches can be suggested and confirmed or rejected.
8. Accepted rows commit into the canonical transaction table.
9. Import batches are auditable after commit.
10. A committed batch can be rolled back safely.
11. Raw uploaded files can be purged without destroying import audit metadata.
12. Reports include committed manual imports and avoid double-counting confirmed transfers.
13. Backend and frontend tests cover the happy path, failure paths, duplicates, transfer matching, and rollback.

If any of these are missing, manual import should still be treated as incomplete.
