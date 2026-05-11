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

Louisiana lender title policy cost is modeled from the filed-rate tier schedule summarized in `docs/deep-research-report.md`.

V1 behavior:

- low: filed-rate premium with the refinance/reissue credit applied
- expected: filed-rate premium with the refinance/reissue credit applied
- high: standard filed-rate premium before reissue credit

MoneyTree still asks users to confirm refinance/reissue eligibility with the lender or title company because the lower modeled amount depends on prior title-policy eligibility.

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
Louisiana title insurance is modeled from the reported filed-rate tiers. Confirm refinance/reissue eligibility with the lender or title company.
```

For statewide mortgage tax:

```text
MoneyTree did not apply a statewide percentage-based Louisiana mortgage tax. Parish-specific taxes or transaction fees may still apply.
```

## Roadmap

MoneyTree seeds researched parish profiles for:

| Parish | Confidence | Current localized rules |
| --- | --- | --- |
| Orleans Parish | High | Recording, release, Orleans documentary transaction tax |
| St. Charles Parish | Moderate | Recording |
| Jefferson Parish | Moderate | Recording |
| St. John the Baptist Parish | Moderate | Recording, release |
| St. Tammany Parish | High | Recording, release |
| East Baton Rouge Parish | High | Recording, release |

All Louisiana parish profiles still inherit statewide title, settlement, notary, origination, and escrow/prepaid assumptions unless a parish-specific rule overrides them.

Use `docs/loan-fee-parish-research-template.md` to collect recording base fees, per-page fees, indexing fees, mortgage certificate fees, cancellation/release fees, e-recording surcharges, local documentary taxes, source URLs, last verified dates, and confidence level.

## Parish Recording Rules Added From Deep Research

The following rules are seeded from `docs/deep-research-report.md`:

| Parish | Recording low / expected / high | Release low / expected / high | Notes |
| --- | ---: | ---: | --- |
| Orleans | `$130 / $230 / $330` | `$50 / $50 / $60` | Recording includes reported `$30` building fund; documentary tax remains separate. |
| St. Charles | `$105 / $205 / $305` | Inherits statewide `$55 / $55 / $105` | Direct clerk cancellation detail still pending. |
| Jefferson | `$105 / $205 / $305` | Inherits statewide `$55 / $55 / $105` | Direct clerk cancellation detail still pending. |
| St. John the Baptist | `$105 / $205 / $305` | `$15 / $15 / $40` | High allows room for related cancellation/clear-lien certificate handling. |
| St. Tammany | `$110 / $210 / $310` | `$60 / $60 / $60` | Official clerk fee sheet. |
| East Baton Rouge | `$135 / $235 / $335` | `$85 / $85 / $85` | Official clerk fee schedule. |
