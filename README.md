# MoneyTree

MoneyTree is a Phoenix-powered financial management API designed to support secure account aggregation, background processing, and observability from the ground up.

## Development Environment

MoneyTree targets Elixir **1.20.2** and Erlang/OTP **29.0.3**. Install them with [mise](https://mise.jdx.dev/) or [asdf](https://asdf-vm.com/) before running any mix tasks.

```bash
# Preferred: installs the exact versions declared in `.tool-versions`
./scripts/install_toolchain.sh

# Alternatively, run the commands manually
mise install erlang@29.0.3 elixir@1.20.2-otp-29
# or
asdf install erlang 29.0.3
asdf install elixir 1.20.2-otp-29
```

After installation, make sure `mix` is available on your `PATH` (`mix --version`). For `mise`, run `eval "$(mise activate bash)"` in your shell session. For `asdf`, source `${HOME}/.asdf/asdf.sh` (and `${HOME}/.asdf/completions/asdf.bash` for completions).

### JavaScript toolchain

The repository also contains shared UI/Tailwind packages managed with **pnpm 11**. Install the Node.js and pnpm toolchain before running any JavaScript tasks:

```bash
# Install Node.js v24.18.0 (latest LTS). Examples:
mise install node@24.18.0
# or
asdf install nodejs 24.18.0

# Enable pnpm via Corepack once Node.js is installed
corepack enable
corepack prepare pnpm@11.17.0 --activate
```

Verify both runtimes are ready:

```bash
node --version
pnpm --version
```

## Initial Setup

1. Copy the example environment file and adjust secrets (including the Cloak vault key) to your needs
   (see [`docs/environment-variables.md`](docs/environment-variables.md) for a full reference of
   supported settings):
   ```bash
   cp .env.example .env
   ```
2. Export the variables in your shell (or configure your terminal to load them automatically):
   ```bash
   source .env
   ```
   These variables include the `DATABASE_URL` expected by the Phoenix app and match the credentials defined in `docker-compose.yml`.

3. Start the PostgreSQL database container:
   ```bash
   docker compose up -d db
   ```
4. Install dependencies, set up the database, and run the local app stack through the repo startup script:
   ```bash
   ./scripts/dev.sh
   ```

   When `MONEYTREE_SECRET_BACKEND=openbao`, this script also provisions the local compose-backed
   OpenBao service before running migrations and starting Phoenix.

5. To provision only the local OpenBao dev service without starting the app:
   ```bash
   ./scripts/setup_openbao_dev.sh
   ```

When you're finished working, stop the database and OpenBao containers to free resources:

```bash
docker compose stop db openbao
```

The API will be available on [http://localhost:4000](http://localhost:4000).

### Email Delivery

MoneyTree uses Swoosh for invitations, notifications, and future authentication emails. In development,
you can either keep the default local mailbox preview or point the app at your own SMTP server with the
`MAILER_SMTP_*` variables from [.env.example](./.env.example). In production, use Amazon SES SMTP
credentials and set:

- `MAILER_SMTP_HOST`
- `MAILER_SMTP_PORT`
- `MAILER_SMTP_USERNAME`
- `MAILER_SMTP_PASSWORD`
- `MAILER_FROM_EMAIL`

Development mailbox preview remains available at `/dev/mailbox` when dev routes are enabled.

### Bank Sync Integrations

MoneyTree now uses SimpleFIN Bridge as the default connected-account provider. Users create a
one-time SimpleFIN setup token outside MoneyTree, paste it into `/app/link-bank`, and
MoneyTree stores only the claimed Access URL in encrypted connection credentials.

Manual imports remain supported. Plaid is legacy-disabled for new links unless
`BANK_SYNC_ENABLED_PROVIDERS` explicitly includes it.

## Database Tasks

Run these commands from the umbrella root whenever you need to manage the database manually:

```bash
mix ecto.create
mix ecto.migrate
mix run priv/repo/seeds.exs
```

## Running Checks

Quality checks should be run from the umbrella root and mirror the CI workflow:

- `pnpm install --frozen-lockfile` – install workspace dependencies using the exact lockfile versions.
- `mix deps.get` – install or update Elixir dependencies.
- `mix compile --warnings-as-errors` – ensure the codebase compiles cleanly.
- `mix lint` – runs `mix format --check-formatted` and `mix credo --strict` via the MoneyTree app.
- `mix test` – execute the test suite (uses the SQL sandbox).
- `mix dialyzer --halt-exit-status` – static analysis; the first run will build and cache the PLT.
- `pnpm --filter ui build` – compile the shared Tailwind preset and verify frontend styles build successfully.
- `pnpm --filter money-tree-assets build` – build Phoenix asset bundles for the MoneyTree app.

Format sources as you work with `mix format`.

### LiveView test workflow

LiveView suites rely on a consistent authentication flow so CSP metadata and
session-locked events can be asserted reliably. Use the helpers under
`apps/money_tree/test/support/auth_helpers.ex` to prepare a connection with a
valid session in `setup` callbacks:

```elixir
setup context do
  {:ok, context} =
    register_and_log_in_user(context,
      user_attrs: %{full_name: "Example User"},
      session_attrs: %{context: "browser", user_agent: "Mozilla"}
    )

  {:ok, context}
end
```

Each helper call recycles the connection, persists the session token in the
cookie, and exposes the resulting `:conn`, `:user`, and `:session_token`
assigns. With authentication handled centrally the LiveView tests simply mount
the view with `live(conn, path)` and assert CSP meta tags (for example,
`<meta name="csp-nonce" ...>`), masked balances, and the behaviour of
session-locked events.

## Background Processing

MoneyTree uses [Oban](https://hex.pm/packages/oban) with three queues (`default`, `mailers`, and `reporting`). Queue concurrency can be tuned with `OBAN_DEFAULT_LIMIT`, `OBAN_MAILER_LIMIT`, and `OBAN_REPORTING_LIMIT` environment variables. In development, Oban runs with lightweight concurrency and without peer discovery; in tests, jobs execute inline for deterministic assertions.

Run the Oban migrations (if you are not using the `mix setup` alias) with the standard Ecto pipeline:

```bash
mix do --app money_tree ecto.migrate
```

## Telemetry & Observability

Telemetry pollers are supervised alongside an OpenTelemetry exporter. Configure an OTLP endpoint via `OTEL_EXPORTER_OTLP_ENDPOINT` and hook the metrics into your observability stack. `req` is preconfigured to reuse the global Finch pool for outbound HTTP calls.

### Operational Endpoints

- `GET /api/healthz` returns database and Oban queue health (HTTP 503 on degraded status).
- `GET /api/metrics` exposes lightweight queue metrics and database latency readings for scraping.

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
