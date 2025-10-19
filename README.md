# MoneyTree

MoneyTree is a Phoenix-powered financial management API designed to support secure account aggregation, background processing, and observability from the ground up.

## Development Environment

MoneyTree targets Elixir **1.19.0-rc.2** and Erlang/OTP **28.1**. Install them with [mise](https://mise.jdx.dev/) or [asdf](https://asdf-vm.com/) before running any mix tasks.

```bash
# Preferred: installs the exact versions declared in `.tool-versions`
./scripts/install_toolchain.sh

# Alternatively, run the commands manually
mise install erlang@28.1 elixir@1.19.0-rc.2-otp-28
# or
asdf install erlang 28.1
asdf install elixir 1.19.0-rc.2-otp-28
```

After installation, make sure `mix` is available on your `PATH` (`mix --version`). For `mise`, run `eval "$(mise activate bash)"` in your shell session. For `asdf`, source `${HOME}/.asdf/asdf.sh` (and `${HOME}/.asdf/completions/asdf.bash` for completions).

## Initial Setup

1. Copy the example environment file and adjust secrets (including the Cloak vault key) to your needs:
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
4. Install dependencies, set up the database, and run required Oban migrations from the umbrella root:
   ```bash
   mix setup
   ```
5. Start the Phoenix server:
   ```bash
   mix phx.server
   ```

6. Install JavaScript dependencies with [pnpm](https://pnpm.io/) to enable the shared Tailwind preset and upcoming frontends:
   ```bash
   pnpm install
   ```

When you're finished working, stop the database container to free resources:

```bash
docker compose stop db
```

The API will be available on [http://localhost:4000](http://localhost:4000).

### Teller Integration

MoneyTree ships with a Teller integration for account aggregation. Teller separates sandbox and production credentials, so
start by creating a sandbox account at [Teller](https://teller.io) and generating the following values from the Console:

- **API key** – used for direct Teller API calls (`TELLER_API_KEY`).
- **Connect application ID** – embedded in Connect URLs (`TELLER_CONNECT_APPLICATION_ID`).
- **Webhook secret** – verifies Teller webhook signatures (`TELLER_WEBHOOK_SECRET`).

Store the sandbox values in `.env` (see `.env.example` for details) and never commit them to version control. When you promote to
production, rotate the variables and restart your deployment so the new secrets take effect.

#### Webhook tunnel & configuration

Teller delivers account and transaction updates through webhooks. In development, expose the Phoenix endpoint to Teller with a
tunnel such as [`cloudflared tunnel`](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/install-and-setup/tunnel-guide/local/) or [`ngrok`](https://ngrok.com/):

```bash
ngrok http http://localhost:4000
```

Update the Teller webhook URL to point at the tunnel (for example, `https://<random>.ngrok.io/api/teller/webhook`) and set
`TELLER_WEBHOOK_HOST` if you need to override the default host in development. Always keep the tunnel process running while you
test so Teller can deliver responses successfully.

#### Teller Connect in development

MoneyTree exposes Teller Connect through the Phoenix API for local testing. Request a Connect token from
`POST /api/teller/connect_token` (for example, with `curl -X POST http://localhost:4000/api/teller/connect_token -H "Content-Type: application/json" -d '{"products":["accounts","transactions"]}'`)
and pass the returned `connect_token` to the Teller Connect frontend widget. The application ID is injected automatically from
your environment configuration. The `TELLER_CONNECT_HOST` environment variable defaults to the sandbox host; only override it if
Teller support directs you to a different environment.

#### Monitoring Oban syncs

Teller synchronisation work is handled by Oban jobs. Watch the queue with the built-in telemetry endpoints (`GET /api/metrics`)
or by connecting to the database and inspecting `oban_jobs` for the `MoneyTree.Teller.SyncWorker` worker. In development you can
also start `iex -S mix phx.server` and run `Oban.drain_queue(queue: :default)` to execute pending Teller jobs manually. Failed
jobs will retry automatically; persistent failures should be investigated using the Teller runbook (`docs/teller_runbook.md`).

Optional overrides (`TELLER_API_HOST`, `TELLER_CONNECT_HOST`, and `TELLER_WEBHOOK_HOST`) let you point to Teller sandbox URLs if
they differ from the defaults, but most teams can omit them. The `req` HTTP client already targets the shared
`MoneyTree.Finch` pool, so outbound Teller requests reuse the configured Finch connection pool.

In production deployments MoneyTree will fail to boot unless all required Teller variables are set, ensuring the integration is
fully configured before serving traffic.

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
- `pnpm lint` – run all workspace lint tasks (Tailwind validation in the UI package).
- `pnpm --filter ui build` – compile the shared Tailwind preset and verify frontend styles build successfully.
- `pnpm --filter money-tree-assets build` – build Phoenix asset bundles for the MoneyTree app.
- `pnpm audit` – scan the workspace for known vulnerabilities.
- `pnpm --filter @moneytree/contracts... run verify` – confirm API contract definitions are up to date.

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

Run Oban migrations independently (if you are not using the `mix setup` alias):

```bash
mix oban.migrations
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
