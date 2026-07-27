# Investment portfolio implementation plan

Tracks: [GitHub issue #82](https://github.com/MarcoBlaauw/MoneyTree/issues/82)

## Status

Planned after [101](./archive/101-bills-and-subscriptions-rename-implementation-plan.md) (completed)
and [102](./archive/102-vehicle-asset-management-implementation-plan.md) (completed). Phase 1 is the first executable
slice; automated market data, AI narrative, and advanced analytics remain later phases.

Sequencing: last of the three, after
[101](./archive/101-bills-and-subscriptions-rename-implementation-plan.md) (completed)
and [102](./archive/102-vehicle-asset-management-implementation-plan.md) (completed). This is the largest of the three
by a wide margin — a new domain, an append-only transaction ledger, a deterministic analytics
engine, a market-data provider integration, and an optional AI narrative layer. Treat this document
as a roadmap, not a single PR: Phase 1 is the actual near-term target; later phases are scoped in
outline so the shape of the whole feature is visible up front.

Decisions already made for this plan (confirmed with the product owner before writing it):

- **Household net worth**: integrate tangible-asset net equity and investment value together after
  102 Phase 1 and this plan's manual investment ledger/positions are complete. This is an explicit
  phase in this plan, not an item the product owner must remember to re-request.
- **Market-data provider**: Twelve Data is the target for the first automated integration
  (Phase 3), chosen over Finnhub/Massive/Alpha Vantage for its broad instrument coverage (stocks,
  ETFs, mutual funds, forex, commodities, crypto) in one API and a usable free tier for
  prototyping.
- **Crypto**: deferred. Phase 1's instrument model includes `stock | etf | mutual_fund | bond |
  cash`; crypto is a later addition once the deterministic-analytics assumptions that don't apply
  to it (tax lots the way brokerages report them, corporate actions) are worked out separately.

## Guardrail (repeated from the issue, load-bearing for every phase below)

The AI layer explains deterministic portfolio calculations. It is never the source of prices,
balances, returns, tax lots, or trade decisions. Every phase below keeps calculation logic in
Elixir application code and treats Ollama purely as a narrator over already-computed, already-
persisted numbers.

## Current repo fit

There is no existing investments code — this is a new bounded context — but three things already
in the codebase are direct templates for major pieces of it:

- **`MoneyTree.Loans.RateProvider`** (`lib/money_tree/loans/rate_provider.ex`) is the existing
  provider-neutral market-data behaviour. The new `MoneyTree.Investments.MarketDataProvider`
  should follow the same shape: adapters fetch and normalize only, the context owns persistence,
  dedup (by instrument + date), and source/attribution metadata.
- **`MoneyTree.AI.SuggestionRun`** (`lib/money_tree/ai/suggestion_run.ex`) already has almost
  exactly the shape the issue asks for in `ai_insight_runs`: `provider`, `model`, `feature`,
  `status`, `input_scope :map`, `prompt_version`, `schema_version`, `started_at`/`completed_at`/
  `duration_ms`, `error_code`/`error_message_safe`. **Recommend adding a new `feature` value
  (e.g. `"investment_insight"`) to the existing `ai_suggestion_runs` table instead of creating a
  parallel `ai_insight_runs` table.** Same audit/observability needs, same lifecycle, no reason to
  duplicate the schema. If the investments team ends up needing fields the existing table doesn't
  have (e.g. a `source_snapshot_id` FK into `portfolio_snapshots`), add nullable columns to the
  existing table rather than forking it.
- **`MoneyTree.AI.Config`/`MoneyTree.AI.Providers.Ollama`** — the existing Ollama adapter,
  `enabled?/0` global kill switch, per-user base URL/model settings, and (from the TM-003 security
  fix) `MoneyTree.Net.SsrfGuard`-validated destinations. The investments Ollama integration should
  be a new `feature` on this *same* provider/config plumbing, not a second Ollama client. It also
  means the SSRF protections and the "AI globally disabled by default" toggle are inherited for
  free.
- **`MoneyTree.Accounts.net_worth_snapshot/2`** — today, purely financial-account balances. Adding
  investment accounts to household net worth is new integration work; see the note in
  [102](./archive/102-vehicle-asset-management-implementation-plan.md) about doing this as one pass across
  both tangible assets and investments rather than twice.
- **Oban** currently has three queues (`default`, `mailers`, `reporting`) and a small cron table in
  `config/config.exs`. This work needs a new `market_data` queue and at least one new cron entry
  for scheduled price refresh (see Phase 1/3 below), following the exact pattern
  `MoneyTree.Loans.Workers.RateImportWorker` already uses for FRED.

## Data model

New tables, `binary_id` primary keys, `utc_datetime_usec` timestamps (repo convention):

- **`investment_accounts`** — `user_id`, `name`, `account_type` (`brokerage | retirement_401k |
  ira | hsa | other`), `custodian` (free text, e.g. "Fidelity"), `currency`. Deliberately *not* the
  same table as `accounts` (financial accounts) — an investment account has cost-basis and tax-lot
  semantics a checking/credit account never needs, and forcing them into one table would mean a lot
  of nullable columns either way. Optionally `linked_account_id references(:accounts)` if a
  brokerage's cash sweep is separately tracked as a financial account.
- **`instruments`** — `symbol`, `name`, `instrument_type` (`stock | etf | mutual_fund | bond |
  cash`), `currency`, `exchange` (nullable). Unique on `(symbol, exchange)`. This is shared
  reference data across all users, not per-user.
- **`investment_transactions`** (append-only ledger — the source of truth; positions are
  *derived*, never a mutable balance) — `investment_account_id`, `instrument_id`, `transaction_type`
  (`buy | sell | dividend | interest | fee | split | transfer_in | transfer_out | reinvestment`),
  `quantity :decimal`, `price :decimal`, `amount :decimal`, `fees :decimal`, `trade_date :date`,
  `settle_date :date` (nullable), `currency`, `external_id` (nullable, for future import
  dedup), `notes`.
- **`tax_lots`** — `investment_transaction_id` (the opening buy/transfer-in), `investment_account_id`,
  `instrument_id`, `opened_at :date`, `quantity_remaining :decimal`, `cost_basis_per_unit :decimal`.
  Closed (fully sold) lots are kept, not deleted, for realized-gain history; `quantity_remaining`
  going to `0` marks a lot closed rather than removing the row.
- **`market_prices`** — `instrument_id`, `price_date :date`, `close :decimal`, `source :string`,
  `source_provider_key :string` (nullable), `adjustment_method :string` (`unadjusted |
  split_adjusted | total_return`), `currency`, `fetched_at`. Unique on
  `(instrument_id, price_date, adjustment_method)`.
- **`portfolio_snapshots`** — `user_id`, `snapshot_date :date`, `total_value :decimal`,
  `total_cost_basis :decimal`, `currency`, plus a `holdings :map` (JSON breakdown by
  account/instrument at that date) or a separate `portfolio_snapshot_holdings` child table if
  per-holding querying (not just display) turns out to be needed — start with the `:map` column;
  it's cheaper and this data is written once per day and read whole, not filtered.
- **`benchmarks`** — `symbol` (e.g. `SPY`, `AGG`), `name`. Prices reuse the `market_prices` table
  keyed by the benchmark's own `instruments` row — a benchmark is just an instrument you compare
  against, not a separate price series.
- **`allocation_targets`** — `user_id`, `asset_class :string`, `target_percent :decimal`. One row
  per asset class per user; the drift/rebalancing card computes actual vs. target at render time
  from current holdings, no separate "drift" table needed.
- **`ai_suggestion_runs`** — reuse the existing table (see Current repo fit above) rather than a
  new `ai_insight_runs` table.

## Deterministic analytics (application code, not AI)

All of the following are computed in `MoneyTree.Investments` (or a dedicated
`MoneyTree.Investments.Analytics` submodule once the context file gets large — follow the existing
convention of splitting large contexts, e.g. `MoneyTree.Obligations.Evaluator` living alongside
`MoneyTree.Obligations`):

- Market value and cost basis — derived by replaying `investment_transactions` per instrument per
  account (FIFO by default against `tax_lots`, since that's the common brokerage-reported method;
  don't build a configurable-method engine in Phase 1).
- Total return, annualized return.
- Time-weighted return (TWR) — needed for performance comparison that isn't skewed by deposit
  timing.
- Money-weighted return / XIRR — only where the cash-flow history is complete (i.e., not for
  accounts whose transaction history starts mid-stream without an opening balance); explicitly
  suppress/label this metric as unavailable rather than compute a misleading number, per the
  issue's own requirement.
- Realized/unrealized gain-loss — realized from closed tax-lot portions, unrealized from
  `quantity_remaining * (current_price - cost_basis_per_unit)`.
- Income and dividend yield — summed from `dividend`/`interest` transaction rows.
- Allocation breakdowns (asset class, sector, geography, currency, account) — sector/geography
  require instrument metadata MoneyTree doesn't have from manual entry alone; Phase 1 supports
  asset-class/currency/account allocation only, and sector/geography arrive with Twelve Data
  fundamentals in Phase 3.
- Concentration risk — simple largest-position-as-percent-of-portfolio metric to start; don't
  build a full risk model in Phase 1.
- Volatility, drawdown, beta, Sharpe ratio, benchmark comparison — all require enough historical
  `market_prices` rows to be meaningful; every one of these must have an explicit "insufficient
  history" state rather than a computed-but-misleading number for portfolios with a short track
  record (this will be true for essentially every account on day one).
- Contribution vs. market-performance attribution, rebalancing drift vs. `allocation_targets` —
  both are Phase 2 chart-driven features, not Phase 1 blockers.

Every metric needs a documented "insufficient data" state and a short explanation string alongside
the value — this is both an acceptance criterion and the exact same discipline
`docs/architecture/loan-center-market-rate-provider-implementation-plan.md` already uses for market-rate data
quality (stale/incomplete signals shown, never silently hidden).

## Market-data provider architecture

`MoneyTree.Investments.MarketDataProvider` behaviour:

```elixir
@callback provider_key() :: String.t()
@callback configured?(settings :: map()) :: boolean()
@callback lookup_instrument(symbol :: String.t(), settings :: map()) ::
  {:ok, %{symbol: String.t(), name: String.t(), instrument_type: String.t(), currency: String.t()}}
  | {:error, term()}
@callback latest_price(symbol :: String.t(), settings :: map()) ::
  {:ok, %{price: Decimal.t(), as_of: Date.t(), currency: String.t()}} | {:error, term()}
@callback historical_prices(symbol :: String.t(), from :: Date.t(), to :: Date.t(), settings :: map()) ::
  {:ok, [%{price_date: Date.t(), close: Decimal.t()}]} | {:error, term()}
```

`MoneyTree.Investments.Workers.PriceRefreshWorker` (Oban, new `market_data` queue) fetches
end-of-day prices for every instrument with an open position, scheduled nightly on a cron entry
alongside the existing FRED import job. Store `source`, `fetched_at`, `adjustment_method`, and
`currency` on every `market_prices` row; never silently substitute a stale or unadjusted price for
a fresh one — write a data-quality flag (same shape as the Loan Center market-snapshot quality
signals) instead.

Twelve Data specifics: needs a `TWELVE_DATA_API_KEY` env var (documented in
`docs/architecture/environment-variables.md` alongside `FRED_API_KEY`), rate-limit-aware (free tier is
low-volume — batch symbol lookups where the API supports it rather than one request per holding),
and Oban retry/backoff for `429`s.

## Ollama integration (Phase 4, disabled by default)

New `feature` value on the existing AI provider plumbing, e.g. `"investment_insight"`, following
`MoneyTree.AI`'s existing pattern of building a minimized structured payload (see
`recurring_context_payload/1` in `ai.ex` for the existing precedent of "build a small JSON summary,
never hand the model raw records") rather than a new prompt-building path from scratch.

Concretely: build a `%{metrics: [%{id: "twr_1y", value: "8.2%"}, ...], holdings_summary: [...],
allocation: [...]}`-shaped payload, require the model's response to cite the metric IDs it's
explaining (same "require the model to cite values it was given" guardrail the issue specifies),
and persist `provider`, `model`, `prompt_version`, `duration_ms`, and (new) a `source_snapshot_id`
pointing at the `portfolio_snapshots` row the explanation was generated from, via the existing
`ai_suggestion_runs` table.

Guardrails, all enforced at the context layer (not just prompt instructions):

- Output is always labeled "AI-generated commentary, not financial advice" in the UI, not just in
  the prompt.
- No code path from this feature calls any trade/order/broker API — there is no such API in this
  codebase to call, so this is enforced by omission; flag in code review if that ever changes.
- If Ollama is unavailable or disabled, show the deterministic summary (the metrics/allocation
  data itself) with no narrative text, never an error state that blocks viewing the portfolio.

## Visual design

New `/app/investments` LiveView (`MoneyTree.InvestmentsLive.Index`), added to
`workspace_nav_items/0` in `lib/money_tree_web/components/layouts.ex` next to the existing
`Assets`/`Loan Center` entries. Overview-first, progressive disclosure to detail:

- Header totals: total value, daily change, total gain/loss, contributed capital, income.
- Value-over-time chart (period selector, optional benchmark overlay).
- Allocation donut/treemap with drill-down.
- Gain/loss contribution bars by holding.
- Income history + projected annual income.
- Risk card: drawdown, volatility, concentration, explicit data-confidence warnings.
- Rebalancing card: target vs. actual allocation from `allocation_targets`.
- Holdings table: value, weight, cost basis, return, income, freshness.

## Suggested phases

1. **Manual accounts, instruments, transactions, holdings, EOD pricing.** Everything above through
   `investment_transactions`/`tax_lots`, manual instrument entry (no external lookup yet), manual
   EOD price entry, and positions derived from the ledger. This is the real target for a first PR
   out of this plan.
2. **Household net-worth integration across tangible assets and investments.** Once Plan 102's
   tangible-asset gross/net-equity calculation and this plan's deterministic investment positions
   are complete, update `Accounts.net_worth_snapshot/2` in one coordinated pass. The integration
   must:
   - include tangible-asset value minus linked loan/mortgage balances
   - include investment holdings at the latest valid price
   - avoid double-counting investment-account cash or any linked financial account balance
   - preserve currency-aware breakdowns and show each contribution category separately
   - test missing/stale valuations, linked-debt subtraction, shared-account authorization, and
     double-count prevention
3. **Core charts and deterministic return/allocation analytics.** Value-over-time, allocation
   breakdowns, TWR/XIRR where history supports it, holdings table.
4. **Twelve Data adapter + scheduled price refresh + richer instrument metadata** (sector/
   geography/fundamentals for allocation breakdowns beyond asset class).
5. **Optional Ollama interpretation**, as above.
6. **Advanced tax-lot and risk analytics** (configurable cost-basis method beyond FIFO, beta/
   Sharpe/drawdown once enough price history exists, contribution-vs-market attribution).

## Acceptance criteria checklist (from the issue)

- [ ] A user can enter/import investment activity and the ledger reproduces current positions
      (no separate mutable "current holding" balance that can drift from the transaction history).
- [ ] Charts distinguish contributions/withdrawals from investment performance (a deposit must
      never show up as "return").
- [ ] All displayed prices and insights show source and freshness.
- [ ] AI output stays optional and read-only — cannot modify portfolio data, cannot be the source
      of a persisted metric.
- [ ] Every metric has test coverage for its formula and an explicit insufficient-data state.
- [ ] Household net worth includes tangible-asset net equity and investments without
      double-counting linked debt, investment-account cash, or another linked financial account.

## Open questions for the user

1. **Cost-basis method**: FIFO-only for Phase 1, or does average-cost matter enough (e.g. for
   mutual fund reinvestment-heavy accounts) to build a per-account method setting from the start?
   Recommend FIFO-only first; it's the common default and avoids building configurability before
   there's a real need for it.
2. **`ai_suggestion_runs` reuse vs. a dedicated table**: this plan recommends reusing the existing
   table with a new `feature` value rather than creating `ai_insight_runs`. Flagging in case there's
   a reason (e.g. wanting a hard schema boundary between categorization AI and investment AI) to
   keep them separate.
