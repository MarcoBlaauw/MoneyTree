# Transaction Identity And Transfer Matching Prerequisites Plan

## Purpose

This document defines the prerequisite work MoneyTree should complete before building the manual transaction import workflow described in `docs/02-manual-transaction-import-implementation-plan.md`.

Manual imports will only be useful if MoneyTree can correctly distinguish real spending from money movement. A checking account payment to a credit card, a transfer to Ally savings, or a payment split across checking accounts should not inflate household expenses. This plan creates the foundation for reliable transaction identity, transfer matching, account relationship modeling, category rules, and cash-flow reporting.

## Problem Statement

MoneyTree needs to support transactions coming from multiple sources:

- Plaid or other live institution syncs
- manual CSV imports
- manual XLSX imports
- future PDF/screenshot extraction
- user-entered transactions

These sources may include overlapping data. The same real-world money movement can appear as two or more rows:

- checking account outflow to Amex
- Amex payment credit
- checking account transfer to Ally savings
- Ally savings deposit
- Venmo/PayPal outflow and later bank settlement
- truck payment split into multiple ACH rows

Without a shared transaction identity and matching system, MoneyTree will double-count transfers, misstate spending, and make the deficit/surplus dashboard misleading.

## Goals

1. Define a canonical transaction identity model used by all ingestion paths.
2. Add enough account metadata to distinguish assets, liabilities, and internal accounts.
3. Create deterministic fingerprints for imported/synced transactions.
4. Detect exact duplicates and likely duplicates across imports and provider syncs.
5. Match internal transfers between checking, savings, and credit card accounts.
6. Treat credit card payments correctly so purchases count once and payments reduce liability.
7. Preserve auditability so users can see why MoneyTree matched or ignored a transaction.
8. Expose a review workflow for uncertain matches.
9. Update reporting rules so internal transfers do not appear as household spending.

## Non-Goals

- building the manual upload/import wizard itself
- implementing CSV/XLSX parsers
- implementing Plaid sync
- building investment account support
- building a full double-entry accounting ledger
- forcing automatic transfer matching when confidence is low
- using AI as the primary source of truth for transaction identity

## Recommended Product Slice

Build a transaction identity and transfer foundation before manual imports:

1. Normalize account types and ownership metadata.
2. Add canonical transaction identity fields.
3. Add transaction fingerprints.
4. Add duplicate detection helpers.
5. Add transfer match models.
6. Add deterministic transfer matching rules.
7. Add review states for uncertain matches.
8. Update reporting to exclude confirmed internal transfers from spending.
9. Add tests using checking, savings, and credit card scenarios.

This gives the manual import feature a safe place to land staged and committed rows.

## Phase 0: Inspect Existing Models

Before changing schema, inspect current modules and migrations for:

- accounts
- institutions
- institution connections
- transactions
- categories
- sync cursors/provider metadata
- dashboard/reporting queries
- tests around transactions and accounts

Document current transaction assumptions before changing them.

Questions to answer:

1. Does `transactions` already store provider/source transaction IDs?
2. Does `transactions` distinguish pending, posted, credit, debit, transfer, and payment?
3. Does `accounts` distinguish checking, savings, credit card, loan, mortgage, and cash?
4. Can one household/user own multiple accounts at the same institution?
5. Is there a category model already?
6. Do reports use signed amounts directly, or do they already understand account type?

Do not start manual imports until these assumptions are clear.

## Phase 1: Normalize Account Types

MoneyTree needs explicit account type metadata because transfer matching depends on the source and destination account type.

Recommended account fields:

- `account_type`: `checking`, `savings`, `credit_card`, `loan`, `mortgage`, `cash`, `investment`, `other`
- `account_subtype`: optional provider/user subtype
- `liability_type`: nullable; examples `credit_card`, `auto_loan`, `student_loan`, `pool_loan`, `mortgage`
- `is_internal`: boolean, true when the account belongs to the user/household
- `include_in_cash_flow`: boolean
- `include_in_net_worth`: boolean
- `display_name`
- `last_four` nullable
- `institution_name` nullable
- `manual_account`: boolean

Rules:

1. Checking and savings accounts are internal asset accounts.
2. Credit cards are internal liability accounts when owned by the household.
3. Loans are internal liability accounts when owned by the household.
4. External merchants are not accounts unless explicitly modeled later.
5. Account type must be available before transfer matching runs.

## Phase 2: Define Signed Amount Semantics

Create one consistent convention for stored transaction amounts.

Recommended convention:

- Store `amount` as signed from the perspective of the account.
- Positive amount increases that account balance.
- Negative amount decreases that account balance.

Examples:

- paycheck deposit into checking: positive
- grocery purchase from checking: negative
- credit card purchase on credit card account: negative if using household net-worth perspective, or positive if using provider liability perspective only if normalized before reporting
- credit card payment from checking: negative on checking
- credit card payment credit on card account: positive on card liability account if it reduces the owed balance
- transfer from checking to savings: negative on checking, positive on savings

Implementation requirement:

Document the chosen convention in code comments and tests. Do not let each provider/importer interpret signs differently.

If current storage uses provider-native signs, add normalized reporting helpers before changing ingestion behavior.

## Phase 3: Add Transaction Identity Fields

Each committed transaction should carry source and identity metadata.

Recommended fields on canonical transactions:

- `source`: `plaid`, `manual_import`, `user_manual`, `teller`, `pdf_extract`, `screenshot_extract`
- `source_account_id` or `account_id`
- `source_transaction_id` nullable
- `source_reference` nullable
- `source_fingerprint`
- `normalized_fingerprint`
- `posted_date`
- `authorized_date` nullable
- `description`
- `original_description` nullable
- `merchant_name` nullable
- `amount`
- `currency` default `USD`
- `status`: `pending`, `posted`, `void`, `deleted`
- `transaction_kind`: `income`, `expense`, `internal_transfer`, `credit_card_payment`, `loan_payment`, `adjustment`, `unknown`
- `category_id` nullable
- `excluded_from_spending`: boolean
- `needs_review`: boolean
- `review_reason` nullable

Rules:

1. Do not require `source_transaction_id`; many manual exports will not have one.
2. Always create a `source_fingerprint` for imported/synced rows.
3. Always create a `normalized_fingerprint` for cross-source duplicate detection.
4. Keep source reference fields because card exports often include useful reference IDs.

## Phase 4: Define Fingerprint Strategy

MoneyTree should generate deterministic fingerprints before duplicate detection or transfer matching.

### Source Fingerprint

Purpose: identify the same source row from the same provider/import file.

Recommended inputs:

- source
- account ID or source account hint
- source transaction ID when available
- source reference when available
- posted date
- amount
- normalized original description
- currency

For manual import rows, include:

- source institution/preset
- file hash if needed
- row-level reference ID if available

### Normalized Fingerprint

Purpose: identify likely same real-world transaction across sources.

Recommended inputs:

- account ID
- posted date
- signed amount
- normalized merchant or description
- currency

For fuzzy duplicate detection, do not rely only on the fingerprint. Use a confidence model.

## Phase 5: Add Duplicate Detection Service

Create a provider-agnostic duplicate detector used by Plaid sync, manual imports, and future OCR imports.

Suggested module:

- `MoneyTree.Transactions.DuplicateDetector`

Inputs:

- account ID
- posted date
- amount
- currency
- source transaction ID
- source reference
- source fingerprint
- normalized fingerprint
- merchant/description

Outputs:

- duplicate status: `none`, `exact`, `high`, `medium`, `low`
- candidate transaction ID
- confidence score
- explanation

Rules:

1. Exact source ID match should block duplicate commit.
2. Exact source fingerprint match should block duplicate commit.
3. Same account/date/amount/normalized merchant should be high confidence.
4. Same account/amount/date within +/- 3 days should be medium confidence unless merchant also matches.
5. Same amount and similar merchant outside the date window should be low confidence.
6. Medium and low confidence matches should be reviewable, not silently skipped.

## Phase 6: Add Transfer Match Model

Create a transfer-match model instead of storing transfer state only on transactions.

Suggested table: `transaction_transfer_matches`

Fields:

- `id`
- `outflow_transaction_id`
- `inflow_transaction_id`
- `match_type`: `checking_to_savings`, `checking_to_credit_card`, `checking_to_loan`, `peer_transfer`, `manual_link`, `unknown`
- `status`: `suggested`, `confirmed`, `rejected`, `auto_confirmed`, `broken`
- `confidence_score`
- `matched_by`: `system`, `user`, `rule`, `import_batch`
- `match_reason`
- `amount_difference`
- `date_difference_days`
- timestamps

Rules:

1. One transaction should not be confirmed into multiple active transfer matches unless split transfers are explicitly supported later.
2. Suggested matches must not affect reporting until confirmed or auto-confirmed.
3. Rejected matches should be remembered so they are not repeatedly suggested.
4. Broken matches should preserve audit history if a linked transaction is deleted or rolled back.

## Phase 7: Transfer Matching Rules

Suggested module:

- `MoneyTree.Transactions.TransferMatcher`

The matcher should look for opposite-sign transactions that represent the same movement of money.

### General Transfer Match

Inputs:

- two internal accounts
- opposite signs
- same absolute amount or within tolerance
- posted dates within configurable window, default +/- 5 days
- transfer-like descriptions

Examples:

- checking outflow: `ALLY BANK TRANSFER -600.00`
- savings inflow: `TRANSFER FROM CHECKING +600.00`

### Checking To Savings

Rules:

- from account type `checking`
- to account type `savings`
- same amount
- window +/- 5 days
- known transfer terms: `transfer`, `ally`, `savings`, `external transfer`, `ach`

Reporting behavior:

- exclude both sides from spending/income cash-flow totals
- optionally show as savings contribution

### Checking To Credit Card

Rules:

- outflow from checking
- inflow/payment credit on credit card account
- same amount
- window +/- 7 days
- known payment terms: `payment`, `autopay`, `credit card`, `amex`, `chase`, `discover`, card issuer names

Reporting behavior:

- exclude checking payment from spending if credit card purchases are imported
- credit card payment should reduce liability, not count as income
- unmatched checking credit-card payments may be shown as liability payment until the card side is imported

### Credit Card Purchase Versus Payment

Credit card purchase transactions should count as expenses when categorized as spending.

Credit card payment transactions should not count as expenses if the underlying purchases are already imported.

Rules:

- Card account purchase: expense
- Checking outflow to card: liability transfer/payment
- Card account payment credit: liability reduction
- Card refund: negative expense or credit depending on reporting model

### Checking To Loan

Examples:

- auto loan
- student loan
- pool loan
- mortgage

Rules:

- checking outflow to loan servicer may be a loan payment
- if loan account is tracked separately, match to loan account inflow/reduction
- if loan account is not tracked, classify as loan payment expense/debt service category

Reporting behavior:

- show as debt service in cash-flow reporting
- avoid double-counting if a liability account transaction is also imported

## Phase 8: Match Review Workflow

Add a review state for uncertain matches.

User actions:

- confirm suggested match
- reject suggested match
- manually link two transactions
- unlink a confirmed match
- mark transaction as not a transfer
- mark transaction as internal transfer without a matching counterpart

UI surfaces:

- transaction detail page
- import preview grid
- account reconciliation page
- dashboard warning card for unmatched likely transfers

Suggested filters:

- likely transfer
- unmatched credit card payment
- unmatched savings transfer
- duplicate candidate
- needs review

## Phase 9: Category Foundation

Create or normalize category rules before manual import categorization.

Minimum categories needed:

- Income
- Mortgage / Housing
- Auto Loan
- Student Loan
- Pool Loan / Home Improvement Loan
- Credit Card Payment
- Internal Transfer
- Savings Transfer
- Groceries / Household
- Dining / Coffee
- Fuel
- Utilities / Phone / Internet
- Medical / Pharmacy
- Insurance
- Fees
- Uncategorized

Rules:

1. Internal transfers should use a transfer kind, not merely a spending category.
2. Credit card payments should be distinguishable from credit card purchases.
3. Loan payments can be reported as debt service, but should not be confused with card payments.
4. User-defined merchant rules should override system suggestions.

## Phase 10: Reporting Semantics

Update reports before manual imports rely on them.

Dashboard views should support at least:

- cash-flow income
- spending expenses
- debt service
- savings contributions
- internal transfers
- net household cash flow
- net worth movement, where applicable

Default household spending report:

- include normal expenses
- include credit card purchases
- include loan payments if no loan liability account is tracked
- exclude confirmed checking-to-savings transfers
- exclude confirmed checking-to-credit-card payments when card transactions are imported
- exclude both sides of confirmed internal transfers

Show transfer movement separately so users can still see savings behavior.

## Phase 11: Migration And Backfill Strategy

If existing transactions lack identity fields, add migrations carefully.

Recommended order:

1. Add nullable columns first.
2. Backfill account types where known.
3. Backfill transaction source as `unknown` or existing provider name.
4. Generate fingerprints for existing posted transactions.
5. Add indexes after backfill.
6. Add constraints only after data is clean.

Suggested indexes:

- transactions account/date/amount
- transactions source/source_transaction_id
- transactions source_fingerprint
- transactions normalized_fingerprint
- transfer matches outflow transaction ID
- transfer matches inflow transaction ID
- transfer matches status

## Phase 12: Tests

Testing should be scenario-driven.

### Account Type Tests

Cover:

- checking account cash-flow behavior
- savings account transfer behavior
- credit card liability behavior
- loan liability behavior
- manual account behavior

### Fingerprint Tests

Cover:

- same source row produces same fingerprint
- different row produces different fingerprint
- minor description spacing/case differences normalize correctly
- missing source transaction ID still produces stable fingerprint

### Duplicate Detection Tests

Cover:

- exact source transaction ID duplicate
- exact source fingerprint duplicate
- same account/date/amount/merchant high-confidence duplicate
- same amount/date but different merchant medium or low confidence
- repeated legitimate same-day purchases are not automatically blocked

### Transfer Matching Tests

Cover:

- checking to savings exact match
- checking to credit card exact match
- checking to credit card with date delay
- checking to loan account
- rejected match is not suggested again
- confirmed match affects reporting
- suggested but unconfirmed match does not affect reporting
- rollback or deletion breaks match safely

### Reporting Tests

Cover:

- card purchases count as expenses
- checking payment to imported card does not double-count
- savings transfer excluded from spending but visible as savings
- unmatched loan payment appears as debt service
- internal transfer excluded from net spending

## Manual Verification Scenarios

Use realistic household examples:

1. Checking payroll deposit.
2. Checking grocery purchase.
3. Checking to Ally savings transfer of `$600`.
4. Checking to kids savings transfer of `$50` twice per month.
5. Checking outflow to Amex.
6. Amex payment credit.
7. Amex purchases from Walmart, Target, dining, and medical.
8. Two car notes.
9. Truck payment split into two `ICPayment` transactions.
10. Pool loan payment to LendKey.
11. Medical and dental copays.

Expected result:

- payroll counts as income
- purchases count as expenses
- checking-to-savings transfers do not count as spending
- checking-to-credit-card payments do not double-count if card purchases are imported
- loan payments are reported as debt service
- unmatched or ambiguous rows are surfaced for review

## Delivery Order

Implement in this order:

1. Inspect existing account/transaction/reporting models.
2. Normalize account type metadata.
3. Decide and document signed amount semantics.
4. Add transaction identity columns.
5. Add fingerprint generation helpers.
6. Add duplicate detection service.
7. Add transfer match schema.
8. Add deterministic transfer matching service.
9. Add category foundations for transfers, card payments, and loan payments.
10. Update dashboard/reporting semantics.
11. Add review UI/API hooks for uncertain matches.
12. Add tests for all scenarios.
13. Only then proceed with manual import parser/upload work.

Each phase should be kept small enough for a focused PR and should include migrations and tests together. Always run migrations in the development instance through the normal project workflow before treating a phase as complete.

## Completion Criteria

This prerequisite work is complete only when all of the following are true:

1. Accounts have reliable type metadata for checking, savings, credit cards, and loans.
2. Transactions have source, reference, fingerprint, kind, and review fields.
3. Duplicate detection works without depending on one provider-specific ID.
4. Transfer matches can be suggested, confirmed, rejected, and audited.
5. Checking-to-savings transfers can be matched and excluded from spending.
6. Checking-to-credit-card payments can be matched to credit card payment credits.
7. Credit card purchases and credit card payments are reported differently.
8. Loan payments can be reported as debt service without being confused with transfers.
9. Reports avoid double-counting confirmed internal transfers.
10. Uncertain matches are reviewable by the user.
11. Tests cover duplicate detection, transfer matching, and reporting behavior.
12. The manual import plan can safely stage and commit rows into this model.

If any of these are missing, manual transaction import should not be considered ready for implementation.
