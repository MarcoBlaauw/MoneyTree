# Loan Center Market Rate Provider Implementation

## Summary

Loan Center market rates extend the existing `loan_rate_sources` and `loan_rate_observations` tables. Imported rates are market context only: they can explain refinance scenarios, trend direction, and alerts, but they must never overwrite user-entered mortgage terms or be presented as personalized lender offers.

## Implementation Status

| Area | Status | Notes |
| --- | --- | --- |
| Existing table extension | Done | `loan_rate_sources` and `loan_rate_observations` are extended with provider attribution, import health, `effective_date`, `published_at`, geography, notes, confidence, source URL, and dedupe support. |
| FRED provider | Done | `MoneyTree.Loans.RateProviders.Fred` imports the v1 mortgage, prime, fed funds, SOFR, and Treasury series through the provider behavior. |
| Runtime configuration | Done | `FRED_API_KEY` and optional `FRED_BASE_URL` are environment-only configuration values; secrets are not stored in provider rows. |
| Import worker and schedule | Done | `MoneyTree.Loans.Workers.RateImportWorker` supports provider-aware FRED imports and Oban Cron runs the FRED import daily. |
| Normalized persistence | Done | Imported observations preserve source payloads, source links, observed/effective/import dates, decimal-fraction rates, and update existing rows on duplicate source/series/effective-date matches. |
| Market snapshot queries | Done | Loan context exposes latest rates, historical rates, mortgage snapshots, refinance context, benchmark direction, and data-quality summaries. |
| Trend windows | Done | 7-day, 30-day, 90-day, and year-over-year deltas are calculated from persisted observations. |
| Data quality | Done | Snapshot quality reports stale data, incomplete trend windows, missing expected benchmark series, and provider import failures while keeping last available observations visible. |
| Loan Center UI | Done | Refinance workspace shows market snapshots, trend details, quality warnings, source attribution, last-updated context, and FRED compliance notice. |
| Manual supplemental import | Done | Manual/supplemental provider metadata and import pipeline support reviewed non-API market-rate rows without turning them into personalized offers. |
| Future provider registry | Done | API Ninjas and FMP/Alpha Vantage-style economic indicators are represented as disabled future-provider placeholders behind the same provider behavior. |
| Persistent snapshot cache | Pending | Deferred until dashboards, alerts, AI summaries, or opportunity scoring need repeated snapshot reuse. |
| Lock-period metadata | Pending | Deferred until provider/manual data includes lock-period semantics. |
| Refinance opportunity score | Pending | Future rule-based score only; imported benchmarks must remain context, not lender offers. |
| Enterprise providers | Pending | ICE Mortgage Technology and Optimal Blue are documented future candidates, not v1 integrations. |

## API Keys

Current active provider:

- `FRED_API_KEY` - required for FRED imports.
- `FRED_BASE_URL` - optional, defaults to `https://api.stlouisfed.org/fred`.

Add these to `.env` for local development and to runtime environment variables in deployed environments. Provider keys are not stored in the database in v1.

Applications using FRED must display this notice prominently:

> This product uses the FRED® API but is not endorsed or certified by the Federal Reserve Bank of St. Louis.

Keep the notice visible in the authenticated app footer and in Loan Center market-rate context. Link to the FRED API Terms of Use and FRED legal notices where practical:

- https://fred.stlouisfed.org/docs/api/terms_of_use.html
- https://fred.stlouisfed.org/legal

Future provider keys should be added only when an active provider adapter exists. API Ninjas, FMP, Alpha Vantage, ICE Mortgage Technology, and Optimal Blue are documented future candidates, not active v1 dependencies.

## Provider Architecture

Providers implement a backend adapter under the Loans domain. Adapters fetch and normalize data only; the `MoneyTree.Loans` context owns persistence, deduplication, source metadata, and import status.

The first active adapter is `MoneyTree.Loans.RateProviders.Fred`.

Provider registry status is available from the Loans context so UI/admin
surfaces can show which providers are active, configured, and future-only
without hard-coding module names.

Initial FRED series:

- `MORTGAGE30US` - 30-year fixed mortgage national average.
- `MORTGAGE15US` - 15-year fixed mortgage national average.
- `DPRIME` - bank prime loan rate.
- `FEDFUNDS` - effective federal funds rate.
- `SOFR` - secured overnight financing rate.
- `GS10` - 10-year Treasury constant maturity.
- `GS2` - 2-year Treasury constant maturity.

Unverified credit-card and auto-loan FRED series are intentionally excluded from v1 mappings.

Manual supplemental imports use the same normalized observation pipeline as API
providers. Reviewed rows can be imported with source attribution, effective
date, loan type, term, rate/APR, points, notes, and source URL without storing
secrets or treating the data as an offer.

## Data Semantics

Rates are stored as decimal fractions. A source value of `6.50%` is stored as `0.065`.

Date fields:

- `effective_date` - date the rate value represents. For FRED, this is the source observation date.
- `published_at` - source publication timestamp when available.
- `observed_at` - retained for compatibility; for FRED it matches `effective_date` at UTC midnight.
- `imported_at` - timestamp when MoneyTree imported the row.

Deduplication uses `rate_source_id + series_key + effective_date`.

Historical observations should be retained indefinitely. Do not prune market-rate observations aggressively; refinance context becomes more useful as the historical window grows.

## Data Quality

Market snapshots include lightweight quality signals:

- latest effective date
- stale status
- provider import failure status
- incomplete trend windows
- missing market observations
- missing expected benchmark series

Stale or incomplete data remains visible but must be labeled. User-facing examples:

- “Market data may be stale.”
- “Not enough history for 90-day trend.”
- “Latest provider import failed; showing last available benchmark.”

## Loan Center Usage

The Refinance workspace can display:

- current user loan rate
- national 30-year and 15-year mortgage averages
- Treasury/Fed baseline indicators
- 7-day, 30-day, 90-day, and year-over-year trend deltas
- source attribution and last updated date
- direct source links when provider/source URLs are available
- structured market explanation
- compact trend details for 7-day, 30-day, 90-day, and year-over-year movement

Preferred wording:

- “National average”
- “Observed market benchmark”
- “Estimated market context”
- “Your actual offer may vary based on credit score, LTV, points, lender fees, loan size, location, and lock period.”

## Future Work

Do not add these in v1 unless explicitly scoped:

- persistent `loan_market_snapshots` cache table
- lock-period metadata such as `lock_period_days`
- refinance opportunity score
- API Ninjas active provider
- FMP or Alpha Vantage active provider
- Bankrate/Mortgage News Daily automated ingestion
- CFPB/HMDA historical enrichment
- ICE Mortgage Technology or Optimal Blue enterprise integrations
