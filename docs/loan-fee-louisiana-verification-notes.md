# Louisiana Loan Fee Verification Notes

## Purpose

This document records the Louisiana-specific fee assumptions used by MoneyTree's Loan Center fee subsystem.

MoneyTree uses these values for modeled estimates only. They are not legal advice, lender disclosures, or compliance determinations.

## V1 Statewide Model

Louisiana is not modeled as a standard statewide percentage mortgage-tax state. MoneyTree v1 uses:

- recording-fee driven estimates
- title/settlement-fee driven estimates
- parish/local-fee warnings
- special handling for Orleans Parish documentary transaction tax

MoneyTree does not apply a statewide percentage-based Louisiana mortgage tax or transfer tax by default.

## Statewide Recording Fee Estimate

Modeled basis: Louisiana R.S. 13:844 recorder fee tiers plus common LCRAA/parish practice.

V1 modeled range:

- low: `$105`
- expected: `$205`
- high: `$305`
- local verification required

## Mortgage Cancellation Or Release

Modeled as a likely payoff/release-related government recording cost.

V1 modeled range:

- low: `$55`
- expected: `$55`
- high: `$105`
- local verification required

## Orleans Parish Documentary Transaction Tax

Orleans Parish is modeled as a special case. For normal residential refinance amounts over `$9,000`, MoneyTree adds:

- low: `$325`
- expected: `$325`
- high: `$325`

## Louisiana Title Insurance

Louisiana lender title policy cost is still modeled as a percentage estimate until a verified Louisiana rate table is added:

- low: `0.20%`
- expected: `0.50%`
- high: `1.00%`
- local verification required

## Settlement And Notary Costs

Louisiana settlement/notary practices support a non-zero notary/document expectation:

- settlement or closing fee: `$300` / `$600` / `$1,200`
- attorney, notary, or document fee: `$250` / `$500` / `$1,000`

## Required User Warnings

When Louisiana parish is unknown:

```text
Louisiana recording and local tax assumptions can vary by parish. MoneyTree is using a statewide estimate until the parish is known.
```

When Orleans Parish is applied:

```text
Orleans Parish documentary transaction tax has been included because the property is located in Orleans Parish.
```

For Louisiana title insurance:

```text
Louisiana title insurance is modeled from a generic percentage range until a verified Louisiana rate table or lender quote is available.
```

For statewide mortgage tax:

```text
MoneyTree did not apply a statewide percentage-based Louisiana mortgage tax. Parish-specific taxes or transaction fees may still apply.
```

## Roadmap

MoneyTree seeds low-confidence parish profile shells for:

- St. Charles Parish
- Jefferson Parish
- Orleans Parish
- St. John the Baptist Parish
- St. Tammany Parish
- East Baton Rouge Parish

Only Orleans Parish has a parish-specific fee override in v1. Other parish shells inherit Louisiana statewide modeled assumptions until parish-specific recording, tax, and title data is verified.

Use `docs/loan-fee-parish-research-template.md` to collect recording base fees, per-page fees, indexing fees, mortgage certificate fees, cancellation/release fees, e-recording surcharges, local documentary taxes, source URLs, last verified dates, and confidence level.
