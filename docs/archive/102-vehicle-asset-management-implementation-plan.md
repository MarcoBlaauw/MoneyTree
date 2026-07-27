# Vehicle & tangible asset management implementation plan

Tracks: [GitHub issue #81](https://github.com/MarcoBlaauw/MoneyTree/issues/81)

## Status

Completed and archived on 2026-07-27, after
[101](./101-bills-and-subscriptions-rename-implementation-plan.md) (Bills & Subscriptions rename)
and before [103](../103-investment-portfolio-implementation-plan.md).

The completed implementation includes:

- assets have a required direct `user_id`, optional `account_id`, non-destructive account unlinking,
  acquisition cost, and optional loan/mortgage links
- existing asset owners were backfilled from the owning account
- vehicle profiles store VIN and license plate values through Cloak and validate VIN format,
  condition, mileage, and core vehicle metadata
- asset valuations are append-only; context-created assets receive an initial manual snapshot, and
  `Assets.record_valuation/3` updates only the cached latest value
- tenant authorization covers directly owned assets, shared-account assets, vehicle profiles,
  valuations, and linked debt
- the Assets workspace provides vehicle-specific details, manual valuation entry,
  source/date/mileage history, a simple value-over-time visualization, and deterministic 90-day
  freshness labeling
- the Assets workspace and dashboard distinguish gross value, linked debt, and net equity without
  changing the household net-worth calculation reserved for plan 103

The Phase 2 MarketCheck VIN-decode/base-price onboarding flow, persistent request ledger, quota
controls, weekly worker, OpenBao secret mapping, usage UI, and real review/confirmation flow were
validated with the configured provider key. Value history now distinguishes provider estimates from
manual values, shows deterministic value and mileage trends, and presents provider ranges ahead of
point estimates when ranges are available.

The append-only valuation snapshot pattern, provider-neutral adapter behaviour, and Oban refresh-job
scaffolding built here become the template for the investment market-data and portfolio snapshots in
plan 103.

## Purpose and scope

Expand the existing, minimal Assets workspace (a flat list of tangible assets with a single
current valuation) into real household asset management: append-only valuation history, vehicle-
specific identification and condition data, optional links to a funding account *and* to debt
(loan/mortgage), and a provider-neutral vehicle valuation interface with manual entry as the
always-available first-class path.

## Starting repo fit

At the start of this plan, `MoneyTree.Assets` was a working but intentionally thin domain:

- `assets` table / `MoneyTree.Assets.Asset` — one row per asset, one mutable `valuation_amount` +
  `last_valued_on`, `asset_type` as a free-text string (no vehicle-specific fields at all),
  `document_refs` as a plain array of storage keys.
- `belongs_to :account, Account`, and **`account_id` is currently required**
  (`validate_required` in `Asset.changeset/2`). This directly conflicts with the issue's "an asset
  may be linked to a funding account... but its value is not the account balance" — many real
  assets (a paid-off car, a house with no dedicated MoneyTree account, a collectible) have no
  natural funding account. **This needs to become optional as part of this work.**
  - The `accounts` table's `on_delete: :delete_all` for `assets.account_id` (confirmed via
    `information_schema` against the dev DB) means today, deleting the linked account also deletes
    the asset — almost certainly not the desired behavior once the account link becomes optional
    context rather than a required parent. Plan to change this FK to `on_delete: :nilify_all` (same
    fix shape as the `obligations.linked_funding_account_id` bug just fixed) alongside making the
    column nullable.
- `MoneyTreeWeb.AssetsLive.Index` at `/app/assets` — CRUD list, no history, no charts.
- Dashboard (`dashboard_live.ex`) shows an "Assets" card driven by `Assets.dashboard_summary/2`,
  which sums the single `valuation_amount` per currency. There is **no net-equity concept
  anywhere in the codebase today** — `Accounts.net_worth_snapshot/2` only sums financial account
  balances and doesn't touch `assets` at all. Wiring tangible-asset net equity into net worth is
  new integration work, not a small tweak.
- No existing vehicle, valuation-history, or external valuation-provider code exists — this is
  mostly new domain surface, but it can closely follow two patterns already proven in this
  codebase:
  - `MoneyTree.Loans.RateProvider` (`lib/money_tree/loans/rate_provider.ex`) — the existing
    provider behaviour for pluggable market-data adapters (FRED today). Use the same shape:
    `@callback provider_key/0`, `configured?/1`, `fetch_*/1` returning normalized data, with the
    context module (not the adapter) owning persistence and dedup.
  - `MoneyTree.BankSync.ProviderRegistry` — env-configured enable/disable + primary-provider
    selection. Use the same shape for gating the MarketCheck adapter behind a feature flag.
  - `MoneyTree.Loans.Workers.RateImportWorker` + its Oban Cron entry in `config/config.exs` — the
    template for a scheduled valuation-refresh worker.

## Data model

New tables (all `binary_id` primary keys, `utc_datetime_usec` timestamps, matching repo
convention):

### `assets` (alter existing table)
- Add `user_id references(:users, on_delete: :delete_all)` as the required direct owner. Backfill
  existing rows from `accounts.user_id`. This is required for secure ownership when `account_id`
  becomes optional: linked assets remain shareable through account membership, while unlinked
  assets are visible only to their direct owner.
- Make `account_id` nullable; change its FK to `on_delete: :nilify_all`.
- Add `owner_notes` is already covered by `notes`; no change needed there.
- Add `linked_loan_id references(:loans, on_delete: :nilify_all)` (nullable) and
  `linked_mortgage_id references(:mortgages, on_delete: :nilify_all)` (nullable) — two columns
  rather than a polymorphic join table, since a household asset realistically carries at most one
  loan and MoneyTree already models "loan" and "mortgage" as separate tables. This is simpler than
  the issue's suggested `asset_links` table and matches how `Obligation` already does a single
  `linked_funding_account_id` rather than a generic link table.
- Add `acquisition_cost :decimal` (distinct from `valuation_amount`, needed for unrealized
  gain/loss per the acceptance criteria — today only current value is stored, cost basis isn't).
- Keep `valuation_amount`/`last_valued_on` as **derived, cached** columns going forward (updated
  whenever a new `asset_valuations` row is inserted) rather than the source of truth, so existing
  dashboard/summary code that reads them keeps working unchanged while the real history lives in
  the new table.

### `vehicle_profiles` (new, one-to-one with `assets` where `asset_type == "vehicle"`)
- `asset_id references(:assets, on_delete: :delete_all)`, unique index (enforces one profile per
  asset).
- `encrypted_vin` — `MoneyTree.Encrypted.Binary` (Cloak), same pattern as
  `Account.encrypted_account_number`/`encrypted_routing_number`. VIN is a stable, high-value
  identifier for a specific person's vehicle; treat it like an account number.
- `year :integer`, `make :string`, `model :string`, `trim :string`, `body_style :string`.
- `mileage :integer`, `mileage_as_of :date`.
- `condition :string` (validated against a small enum: `excellent | good | fair | poor`).
- `market_region :string` (ZIP or metro code used for valuation lookups).
- `encrypted_license_plate :string` (Cloak, optional), `license_plate_state :string` (optional) —
  explicitly *not* a lookup key anywhere in code, per the issue.

### `asset_valuations` (new, append-only)
- `asset_id references(:assets, on_delete: :delete_all)`.
- `amount :decimal`, `currency :string`.
- `source :string` — `manual | provider`, plus `provider_key :string` (nullable, e.g.
  `"marketcheck"`) when `source == "provider"`.
- `valued_on :date`, `inserted_at` (the snapshot is immutable once written; never `UPDATE`, only
  `INSERT`).
- `confidence :string` (nullable; `low | medium | high`, provider-supplied or manual).
- `manually_overridden :boolean, default: false` — true when a user enters a value while a
  provider is configured, so provider refresh jobs know not to silently replace a deliberate
  manual override (see Acceptance Criteria: "Provider failures never erase or replace the last
  known value").
- `mileage :integer` (nullable — snapshot of mileage at valuation time for vehicles).
- `value_low :decimal`, `value_high :decimal` (nullable — providers like MarketCheck return a
  range, not a point estimate; the UI must be able to show it as a range per the issue).
- `raw_response :map` via `MoneyTree.Encrypted.Map` or plain `:map` — store the provider's raw
  payload for auditability without leaking it into domain logic elsewhere (see Provider Contract
  below). Plain `:map` is fine here since it's valuation data, not credentials — no encryption
  needed, unlike VIN.
- Index on `(asset_id, valued_on desc)` for "latest valuation" queries.

### `valuation_provider_runs` (new, observability)
- `asset_id references(:assets, on_delete: :delete_all)`, `provider_key :string`.
- `status :string` (`ok | error | rate_limited | skipped_cache`), `error_message :text` (nullable).
- `requested_at`, `completed_at`, `duration_ms :integer`.
- Same purpose as `institution_connections.last_sync_error`/`last_sync_error_at`, but per-run
  rather than last-only, since valuation providers are called far less often (nightly/weekly, not
  per-request) and a short history is genuinely useful for debugging rate limits.

No separate `asset_owners` table for v1 — the issue marks this optional ("if one household owner
is sufficient initially"), and MoneyTree's account-sharing model (`account_memberships`) already
lets multiple users see a shared account's assets through the existing `assets.account_id` link
when present. Revisit only if multi-owner assets without a shared funding account become a real
need.

## Provider architecture

New behaviour `MoneyTree.Assets.VehicleValuationProvider`, modeled directly on
`MoneyTree.Loans.RateProvider`:

```elixir
@callback provider_key() :: String.t()
@callback name() :: String.t()
@callback configured?(settings :: map()) :: boolean()
@callback decode_vin(vin :: String.t(), settings :: map()) ::
  {:ok, %{year: integer, make: String.t(), model: String.t(), trim: String.t() | nil}}
  | {:error, term()}
@callback fetch_valuation(vehicle_attrs :: map(), settings :: map()) ::
  {:ok, %{value: Decimal.t(), value_low: Decimal.t() | nil, value_high: Decimal.t() | nil,
          confidence: String.t() | nil, raw: map()}}
  | {:error, :not_configured | :rate_limited | :invalid_response | :timeout
     | {:http_error, pos_integer()} | term()}
```

`MoneyTree.Assets` (the context) owns writing `asset_valuations` and `valuation_provider_runs`
rows; adapters only fetch and normalize, same division of responsibility as the Loans rate
providers.

Provider candidates from the issue, with recommended sequencing:

1. **Manual** (always available, first-class) — a user-entered `asset_valuations` row with
   `source: "manual"`. Ship this first; it's the only path in Phase 1.
2. **MarketCheck** (Cars API / MarketCheck Price) — recommended initial automated provider per the
   issue's own text ("suitable for an initial automated provider"), and it covers VIN decode *and*
   valuation in one vendor, which simplifies Phase 1→2 handoff. Gate behind a feature flag
   (`MoneyTree.Assets.ProviderRegistry`, same shape as `BankSync.ProviderRegistry`) and an
   `MARKETCHECK_API_KEY` env var, following the `docs/architecture/environment-variables.md` documentation
   pattern.
3. **KBB InfoDriver** and **J.D. Power** — document as future/premium adapters behind the same
   behaviour, not implemented until commercial access exists. Do not build placeholder modules for
   these until there's a credential to test against (unlike the Loans rate-provider registry,
   which does carry disabled placeholder adapters — that pattern was worth it there because FRED,
   API Ninjas, and economic-indicators all share one simple normalized-observation shape; KBB and
   J.D. Power's actual response shapes are unknown without an approved account, so a placeholder
   adapter would just be guesswork).

## Phases

**Phase 1 — manual vehicles, VIN capture, manual valuation.**
- [x] Migrations: alter `assets` (direct owner, nullable `account_id`, new columns), create `vehicle_profiles`,
  `asset_valuations`.
- [x] `MoneyTree.Assets.Asset` changeset updates: drop `account_id` from `validate_required`; add
  `asset_type` validation against a fixed list (`vehicle | real_estate | equipment | collectible |
  other`) instead of free text; keep backward compatibility for any existing free-text values.
- [x] New `MoneyTree.Assets.VehicleProfile` schema + changeset (VIN format validation — 17-character
  alphanumeric, no I/O/Q — should be validated even before any provider call).
- [x] `Assets.record_valuation/3` — inserts an `asset_valuations` row, then updates the asset's cached
  `valuation_amount`/`last_valued_on` from the latest snapshot (never overwrites history).
- [x] LiveView: extend `AssetsLive.Index` with an asset-type-aware detail form (vehicle fields appear when
  `asset_type == "vehicle"`), a manual "Record valuation" action, and a per-asset detail view
  (new `AssetsLive.Show` or a detail panel) showing the valuation history table and a simple
  value-over-time chart.
- [x] Dashboard: split "Assets" card into gross asset value and net equity (gross minus any linked
  loan/mortgage current balance), and clearly label which is which — this satisfies "Dashboard
  totals must clearly distinguish gross asset value from net equity" without yet integrating into
  `Accounts.net_worth_snapshot/2`. Full net-worth integration (folding tangible-asset net equity
  into the household net-worth number) is a deliberate, separate decision — flag it as an open
  question below rather than silently changing what net worth means today.

**Phase 2 — MarketCheck adapter + scheduled refresh.**
- [x] `MoneyTree.Assets.VehicleValuationProviders.MarketCheck` implements the provider-neutral
  behavior against the basic VIN-specification and base-price endpoints. Onboarding uses exactly
  those two calls; scheduled refreshes use only one base-price call. HTTP retries are disabled.
- [x] `MoneyTree.Assets.ProviderRegistry` (enabled/disabled + `MARKETCHECK_API_KEY` wiring in
  `config/runtime.exs`, documented in `docs/architecture/environment-variables.md`).
- [x] `valuation_provider_runs` persists every started call, outcome, duration, monthly budget, and
  remaining local allowance. A PostgreSQL advisory lock makes the deployment-wide 450/month default
  and 500/month hard ceiling atomic across concurrent jobs.
- [x] `MoneyTree.Assets.Workers.ValuationRefreshWorker` (Oban), checked daily for new baselines and
  limited to one provider call per vehicle per seven days. The dedicated `market_data` queue has
  concurrency one, and a persistent rolling-window guard enforces MarketCheck's 5 calls/second limit.
  The worker:
  - skips assets whose latest valuation is a recent manual override
  - respects provider rate limits and monthly quota. `429` is recorded without retry, and successful
    and failed calls both start the same seven-day cooldown.
  - on any error, writes a `valuation_provider_runs` row and leaves the asset's last known value
    untouched — this is an explicit acceptance criterion.
- [x] UI: shows monthly MarketCheck usage/remaining budget, configuration state, value history
  source/date/mileage, and existing value-over-time presentation.
- [x] Progressive asset onboarding: choose the type first; vehicles ask only for VIN, mileage, and
  ZIP, show decoded specifications and the estimate for explicit review, then persist the asset,
  encrypted vehicle profile, and provider valuation together. Optional ownership, account/debt,
  location, and document fields are under “More details.” Identical previews are reused for one day
  without spending more quota.
- [x] Rich provider UI: value-over-time chart with provider vs. manual points distinguished,
  depreciation trend,
  mileage history, source/date labeling, and a visible range (not a false point-precision number)
  whenever the provider returns `value_low`/`value_high`.

**Phase 3 — optional KBB / J.D. Power adapters.**
- Only for deployments with commercial credentials; implement against the same behaviour once
  access exists. Not scoped further here since neither vendor's actual API contract can be verified
  without an approved account.

## UI

- Asset inventory: cards/table with type, current value, linked debt (if any), net equity, source,
  and freshness — matches the issue directly.
- Vehicle detail page: value-over-time chart, depreciation trend, mileage history, ownership
  details, valuation assumptions (region, condition, mileage-as-of).
- Never present a provider estimate as exact currency-precision truth: show the range when
  available, and always show source + as-of date next to any valuation.

## Acceptance criteria checklist (from the issue)

- [x] A user can add a vehicle and record a manual value.
- [x] Every valuation creates a historical snapshot; nothing overwrites `asset_valuations` rows.
- [x] Current asset totals and net equity are derived from the latest valid snapshot per asset.
- [x] Provider failures never erase or replace the last known value (verified by a regression test
      that simulates a provider error and asserts the asset's cached valuation and history are
      unchanged).
- [x] Provider-specific payloads (MarketCheck's raw JSON shape) stay inside the adapter + `raw`
      column; no MarketCheck-specific field names appear in `MoneyTree.Assets`'s public API or the
      LiveView beyond the normalized valuation shape.
- [x] Tests cover: ownership authorization (asset access via `account_id` membership when present,
      direct user ownership otherwise), valuation freshness/staleness labeling, linked-debt net
      equity math, provider error handling (timeout, rate limit, invalid response), monthly quota,
      weekly cooldown, and five-calls-per-second reservation.

## Decisions and open questions

1. **Net worth integration — resolved**: Plan 102 will show gross asset value and asset net equity
   without changing `Accounts.net_worth_snapshot/2`. Plan 103 now contains an explicit household
   net-worth integration phase that adds tangible-asset net equity and investment value together,
   with double-count prevention. This is tracked work, not a future reminder for the product owner.
2. **VIN encryption**: confirm treating VIN like an account number (Cloak-encrypted at rest,
   never logged) is the right sensitivity bar — it's a real identifier but less sensitive than an
   account/routing number. This plan encrypts it either way unless told otherwise, since it's cheap
   and the issue explicitly calls it out as "encrypted or otherwise treated as sensitive."
3. **MarketCheck live validation — completed**: the persistent OpenBao `marketcheck` group contains
   the real key, and a user-reviewed VIN decode and baseline price response completed successfully.
4. **MarketCheck webhooks — deferred**: evaluate subscriptions later, after the real account exposes
   the available event types and their signature, delivery/retry, and quota behavior. Webhooks must
   use the same normalized provider boundary and may not bypass monthly request accounting.
