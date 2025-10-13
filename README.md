# MoneyTree

MoneyTree is a Phoenix-powered financial management API designed to support secure account aggregation, background processing, and observability from the ground up.

## Development Environment

MoneyTree targets Elixir **1.14** and Erlang/OTP **25**. Install them via [asdf](https://asdf-vm.com/) (or [mise](https://mise.jdx.dev/)) using the provided `.tool-versions` file:

```bash
asdf install
```

> **Note:** If you use `mise`, run `mise install` instead.

## Initial Setup

1. Copy the example environment file and adjust secrets to your needs:
   ```bash
   cp .env.example .env
   ```
2. Export the variables in your shell (or configure your terminal to load them automatically):
   ```bash
   source .env
   ```
3. Install dependencies, set up the database, and run required Oban migrations:
   ```bash
   cd apps/money_tree
   mix setup
   ```
4. Start the Phoenix server:
   ```bash
   mix phx.server
   ```

The API will be available on [http://localhost:4000](http://localhost:4000).

## Database Tasks

Run these commands from `apps/money_tree` whenever you need to manage the database manually:

```bash
mix ecto.create
mix ecto.migrate
mix run priv/repo/seeds.exs
```

## Running Checks

Run the test suite before opening a pull request:

```bash
cd apps/money_tree
mix test
```

Format the codebase as needed:

```bash
mix format
```

## Background Processing

MoneyTree uses [Oban](https://hex.pm/packages/oban) with three queues (`default`, `mailers`, and `reporting`). Queue concurrency can be tuned with `OBAN_DEFAULT_LIMIT`, `OBAN_MAILER_LIMIT`, and `OBAN_REPORTING_LIMIT` environment variables. In development, Oban runs with lightweight concurrency and without peer discovery; in tests, jobs execute inline for deterministic assertions.

Run Oban migrations independently (if you are not using the `mix setup` alias):

```bash
mix oban.migrations
```

## Telemetry & Observability

Telemetry pollers are supervised alongside an OpenTelemetry exporter. Configure an OTLP endpoint via `OTEL_EXPORTER_OTLP_ENDPOINT` and hook the metrics into your observability stack. `req` is preconfigured to reuse the global Finch pool for outbound HTTP calls.

## Product Vision & Roadmap

The following notes capture the broader product direction for MoneyTree. They remain aspirational but inform the system design decisions above.

### 🔐 Core Account & Data Management

- User accounts with secure authentication (2FA support)
- Multi-user support (family/shared access, read-only roles)
- Currency support with real-time exchange rates
- Bank connection methods:
  - Plaid integration (where available)
  - File import (CSV, OFX, QFX, XLSX)
  - Manual transaction entry
- Categorization system (automatic + manual)

### 📊 Core Finance Features

- Unified transaction view
- Customizable dashboards per institution, account, and global
- Categorization and tag filtering
- Charts & graphs:
  - Spending by category
  - Income vs. expenses
  - Monthly trend lines
- Budgeting and payment calendar
- Subscription tracking
- Recurring expense detection
- Basic trend analysis (rolling averages, YoY/period comparisons)

### 🧾 Security & Privacy

- Encrypted storage for financial data
- Secure session & access controls
- Explicit consent for data connections
- Audit log for user access

### ⚡ Infrastructure

- Phoenix API backend with Oban job workers
- PostgreSQL double-entry ledger
- `cloak_ecto` for encryption of sensitive fields
- Decimal/NUMERIC for money handling
- SvelteKit frontend (basic dashboard)
- Email & notification support

### 🌳 Full Release Must-Haves & Beyond

The remainder of the original vision (advanced insights, asset tracking, tax tooling, smart recommendations, etc.) is preserved from the initial roadmap and will be revisited as implementation proceeds.
