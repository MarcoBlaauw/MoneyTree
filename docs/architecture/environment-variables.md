# Environment variable reference

MoneyTree loads configuration from the process environment at runtime. Use the values in
[`.env.example`](../../.env.example) as a starting point, then tailor them to your local or hosted
setup. Copy the example file to `.env` and export it in your shell (or configure your terminal to
load it automatically) before starting the application.

```bash
cp .env.example .env
source .env
```

## Core Phoenix runtime

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `PHX_SERVER` | No | `false` (Phoenix only starts in releases by default) | Set to `true` when running `mix phx.server` or a release so the endpoint boots. |
| `PHX_HOST` | Yes (production) | `localhost` | Public hostname used when generating URLs and CSRF tokens. Set to your deployed hostname in production. |
| `PORT` | Yes | `4000` | HTTP port that the Phoenix endpoint listens on. |
| `SECRET_KEY_BASE` | Yes | — | Used to sign/encrypt cookies and session data. Generate with `mix phx.gen.secret` and keep it secret. |

## Database configuration

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `DATABASE_URL` | Yes | `ecto://postgres:postgres@localhost/money_tree_dev` | Connection string for the primary PostgreSQL database. Update the host/user/password for your environment. |
| `POOL_SIZE` | No | `10` | Connection pool size for the Phoenix application. Increase for high-concurrency workloads. |
| `DATABASE_SSL` | No | `true` in production | Whether to encrypt the database connection. Set to `false` only when the database is reachable exclusively over a trusted private network/socket. |
| `DATABASE_SSL_VERIFY` | No | `true` in production | Whether to verify the database server's TLS certificate against the OS trust store (in addition to encrypting the connection). Set to `false` only if the database certificate doesn't chain to a public CA (self-signed, private CA) and you can't supply your own trust bundle. |

## Encryption & credentials

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `MONEYTREE_SECRET_BACKEND` | No | `env` | Runtime secret provider. Use `env` for current deployments. `openbao` selects the OpenBao provider for known secret groups, but production migration/status surfaces are not complete yet. Unsupported values currently fall back to `env`. |
| `CLOAK_VAULT_KEY` | Yes | — | Base64-encoded key that secures encrypted fields via Cloak. Rotate and store securely. |

## OpenBao secret backend

OpenBao support is being rolled out in phases. The current code supports AppRole login and KV reads for
known secret groups. Local development can use the compose-backed OpenBao service by running
`./scripts/setup_openbao_dev.sh`, which starts a persistent, local-only OpenBao service, provisions the
local policy/AppRole, seeds dev secret groups from `.env`, and writes the local `OPENBAO_*` metadata back
to `.env`.
`./scripts/dev.sh` runs this setup automatically when `MONEYTREE_SECRET_BACKEND=openbao`.

Keep `MONEYTREE_SECRET_BACKEND=env` for deployments unless you have provisioned the documented OpenBao
paths and policy.

To migrate supported application secrets out of the local `.env` after seeding them, run:

```bash
MIGRATE_ENV_SECRETS=true ./scripts/setup_openbao_dev.sh
```

The migration verifies each value through OpenBao before removing its plaintext `.env` entry. OpenBao
connection settings, AppRole credentials, and the local unseal/root bootstrap values remain in `.env`;
they are required to reach and unlock the secret store. The compose service stores encrypted OpenBao
data in the `money_tree_openbao_data` volume, so migrated values survive normal container restarts.
Variables outside the supported secret groups remain in the process environment and are not copied to
OpenBao.

The current ownership boundary is:

| OpenBao group | Values moved from `.env` |
| --- | --- |
| `database` | `DATABASE_URL`, or the separate `DATABASE_USERNAME`, `DATABASE_PASSWORD`, `DATABASE_HOST`, and `DATABASE_NAME` values |
| `cloak` | `CLOAK_VAULT_KEY` |
| `fred` | `FRED_API_KEY` |
| `marketcheck` | `MARKETCHECK_API_KEY` |
| `phoenix` | `SECRET_KEY_BASE` |
| `plaid` | `PLAID_CLIENT_ID`, `PLAID_SECRET`, and `PLAID_WEBHOOK_SECRET` when the legacy integration is enabled |
| `smtp` | `MAILER_SMTP_HOST`, `MAILER_SMTP_USERNAME`, and `MAILER_SMTP_PASSWORD` |

Keep operational settings such as public URLs and origins, ports, TLS modes, provider flags, queue
limits, observability endpoints, mail sender identity, and `FRED_BASE_URL` in the process environment.
OpenBao connection/AppRole/bootstrap values must also remain outside OpenBao so the application and
provisioning script can reach and unlock it.

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `SECRET_BACKEND_MODE` | No | — | Compatibility alias for `MONEYTREE_SECRET_BACKEND`. `MONEYTREE_SECRET_BACKEND` takes precedence when both are set. |
| `OPENBAO_ADDR` | Yes (when OpenBao enabled) | — | OpenBao server URL, such as `https://bao.internal:8200`. |
| `OPENBAO_NAMESPACE` | No | — | Optional OpenBao namespace for deployments that use namespaces. |
| `OPENBAO_AUTH_METHOD` | Yes (when OpenBao enabled) | `approle` | Auth method for the MoneyTree machine identity. Current scaffold validates `approle`. |
| `OPENBAO_ROLE_ID` | Yes (AppRole) | — | AppRole role ID for the MoneyTree machine identity. |
| `OPENBAO_SECRET_ID` | Yes (AppRole) | — | AppRole secret ID or wrapped/bootstrap-provided secret ID for the MoneyTree machine identity. |
| `OPENBAO_KV_PREFIX` | Yes (when OpenBao enabled) | — | KV path prefix for this deployment, for example `kv/data/moneytree/prod`. |
| `OPENBAO_SSL_VERIFY` | No | `true` | Whether to verify OpenBao TLS certificates. Keep `true` outside controlled local development. |
| `OPENBAO_TIMEOUT_MS` | No | `5000` | Timeout in milliseconds for future OpenBao HTTP requests. |
| `OPENBAO_DEV_UNSEAL_KEY` | Local compose only | generated | Unlocks the persistent local OpenBao service after a restart. Keep it secret and never reuse it outside local development. |
| `OPENBAO_DEV_ROOT_TOKEN` | Local compose only | generated | Local administrative bootstrap token used by the provisioning script. Keep it secret and never deploy it. |

## Oban background processing

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `OBAN_DEFAULT_LIMIT` | No | `10` | Concurrent jobs allowed on the default queue. |
| `OBAN_MAILER_LIMIT` | No | `5` | Concurrent jobs allowed on the mailer queue. |
| `OBAN_REPORTING_LIMIT` | No | `5` | Concurrent jobs allowed on the reporting queue. |

The `market_data` queue is deliberately fixed at one concurrent job. It is not runtime-configurable
because it protects low-volume external provider quotas.

## MarketCheck vehicle valuations

Vehicle onboarding uses MarketCheck's basic VIN-specification endpoint and base-price endpoint: one
request decodes the VIN and one produces a normalized USD estimate. The user reviews both results
before MoneyTree creates any asset, profile, or valuation rows. Identical successful previews are
cached for one day. Scheduled refreshes use only the base-price endpoint, so a refresh job can
consume at most one MarketCheck call. Comparables calls and provider HTTP retries are disabled.

The Free tier currently documents 500 calls per calendar month, 5 calls per second, and a 100-mile
radius restriction. MoneyTree defaults to a lower 450-call monthly application budget, enforces an
absolute 500-call ceiling in code and the database, persists every started request, restricts the
market-data queue to one concurrent job, and also enforces the five-call rolling one-second window.
Every onboarding and refresh request is counted in the same deployment-wide budget. Successful and
failed refresh requests start the same seven-day per-vehicle cooldown. The daily dispatcher cannot
refresh a vehicle more than weekly.

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `MARKETCHECK_API_KEY` | Yes when enabled | — | Server-side MarketCheck API key. With OpenBao, store it in the `marketcheck` group. |
| `MARKETCHECK_ENABLED` | No | `false` | Explicit cost-control switch. Both this flag and a non-empty key are required before any request is queued. |
| `MARKETCHECK_MONTHLY_REQUEST_LIMIT` | No | `450` | Deployment-wide monthly request budget. Values above 500 are clamped to 500. |
| `MARKETCHECK_REFRESH_INTERVAL_DAYS` | No | `7` | Minimum elapsed time between outgoing requests for the same vehicle, including failed requests. |
| `MARKETCHECK_DEALER_TYPE` | No | `independent` | Explicit required MarketCheck Price model assumption: `independent` or `franchise`. |
| `MARKETCHECK_BASE_URL` | No | `https://api.marketcheck.com` | Optional controlled endpoint override. |

New vehicles require VIN, mileage, and a five-digit market ZIP. MoneyTree validates those inputs
locally before spending quota, then stores them in the encrypted vehicle profile only after the user
confirms the provider preview.
The 100-mile search-radius restriction does not affect this integration because MoneyTree calls the
ZIP-based base price-prediction endpoint rather than an inventory-radius search endpoint.

MarketCheck webhook subscriptions are deferred until their event types, verification mechanism,
delivery/retry behavior, and quota treatment can be validated against an enabled account.

## Observability

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | No | — | OpenTelemetry collector endpoint for exporting traces and metrics. Leave blank to disable external export. |

## Mail delivery

MoneyTree currently uses Swoosh for all email delivery. Development can use a local or custom SMTP server.
Production should use Amazon SES SMTP credentials so invitations, notifications, and future magic-link
authentication emails share one delivery path.

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `MAILER_FROM_NAME` | No | `MoneyTree` | Display name used in the From header. |
| `MAILER_FROM_EMAIL` | No | `no-reply@moneytree.app` | Sender address used for invitations, notifications, and future auth emails. |
| `INVITATION_BASE_URL` | No | app default | Override the base URL used in invitation emails. |
| `MAGIC_LINK_BASE_URL` | No | app default | Override the base URL used in email sign-in links. |
| `WEBAUTHN_RP_ID` | No | endpoint host | Override the WebAuthn relying-party ID if it differs from the Phoenix endpoint host. |
| `WEBAUTHN_RP_NAME` | No | `MoneyTree` | Display name shown during passkey and hardware-security-key registration. |
| `WEBAUTHN_ORIGIN` | No | endpoint origin | Override the WebAuthn origin when the public browser origin differs from the endpoint defaults. |
| `MAILER_SMTP_HOST` | Yes (production) | — | SMTP relay hostname. In production, use the Amazon SES SMTP endpoint for your AWS region. |
| `MAILER_SMTP_PORT` | No | `587` in production | SMTP port. |
| `MAILER_SMTP_USERNAME` | Yes (production) | — | SMTP username. In production, use SES SMTP credentials rather than AWS access keys. |
| `MAILER_SMTP_PASSWORD` | Yes (production) | — | SMTP password. |
| `MAILER_SMTP_TLS` | No | `if_available` in production | TLS mode for Swoosh SMTP adapter: `always`, `never`, or `if_available`. |
| `MAILER_SMTP_SSL` | No | `false` | Whether to use implicit SSL/TLS. |
| `MAILER_SMTP_AUTH` | No | `always` | SMTP auth policy: `always`, `never`, or `if_available`. |
| `MAILER_SMTP_VERIFY` | No | `verify_peer` | SMTP TLS certificate verification mode. Use `none` only for development against a server with a non-standard certificate chain. |

## Bank sync providers

SimpleFIN Bridge and manual imports are the default provider set for new links. Plaid remains
readable for historical data, but is legacy-disabled for new connections unless explicitly
enabled. Teller connections and transactions from before Teller discontinued its API remain
readable for historical data as well, but Teller can no longer be enabled for new links.

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `BANK_SYNC_ENABLED_PROVIDERS` | No | `simplefin,manual` | Comma-separated provider list available for new user connections. Add `plaid` only when that legacy provider is configured. |
| `BANK_SYNC_PRIMARY_PROVIDER` | No | `simplefin` | Provider shown first in the bank-linking UI. |

## SimpleFIN Bridge

SimpleFIN uses a user-created one-time setup token. MoneyTree claims that token server-side and
stores only the resulting Access URL in encrypted connection credentials.

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `SIMPLEFIN_CREATE_URL` | No | `https://bridge.simplefin.org/simplefin/create` | URL users visit to create a SimpleFIN setup token. |
| `SIMPLEFIN_PROTOCOL_VERSION` | No | `2` | Protocol version requested in `/accounts` calls. |
| `SIMPLEFIN_SYNC_INTERVAL_HOURS` | No | `24` | Default automatic sync cadence. |
| `SIMPLEFIN_MAX_REQUESTS_PER_CONNECTION_PER_DAY` | No | `24` | Safety cap for `/accounts` requests per stored Access URL. |
| `SIMPLEFIN_INITIAL_SYNC_DAYS` | No | `90` | Initial lookback window. Keep at or below SimpleFIN Bridge's range limit. |
| `SIMPLEFIN_INCLUDE_PENDING` | No | `false` | Whether to request pending transactions using `pending=1`. |

## Plaid integration

Plaid is a legacy provider for new links and is disabled by default. The variables below are
required only when `BANK_SYNC_ENABLED_PROVIDERS` contains `plaid` or `PLAID_ENABLED=true`.

Plaid integration is used by the `/app/link-bank` flow to create Link tokens, exchange
public tokens, and synchronize accounts and transactions through Phoenix.

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `PLAID_ENABLED` | No | `false` | Compatibility flag for enabling legacy Plaid code paths. Prefer `BANK_SYNC_ENABLED_PROVIDERS`. |
| `PLAID_CLIENT_ID` | Yes (when Plaid flow enabled) | — | Plaid API client identifier for server-side requests. |
| `PLAID_SECRET` | Yes (when Plaid flow enabled) | — | Plaid API secret used by Phoenix for authenticated API calls. |
| `PLAID_ENV` | No | `sandbox` | Plaid environment name (`sandbox`, `development`, `production`) used to select the default API host. |
| `PLAID_PRODUCTS` | No | `transactions` | Comma-separated list of Plaid products requested in Link tokens. |
| `PLAID_COUNTRY_CODES` | No | `US` | Comma-separated country codes sent in Link token requests. |
| `PLAID_CLIENT_NAME` | No | `MoneyTree` | Display name shown in Plaid Link. |
| `PLAID_LANGUAGE` | No | `en` | Language used by Plaid Link. |
| `PLAID_REDIRECT_URI` | No | — | Optional redirect URI for Plaid Link flows that require redirects. |
| `PLAID_WEBHOOK_SECRET` | No | — | Shared webhook secret used by the current webhook signature validation flow. |
| `PLAID_API_HOST` | No | derived from `PLAID_ENV` | Optional explicit Plaid API host override. Use only for controlled non-standard environments. |

## Additional tips

* Store secrets in a credential manager (1Password, Bitwarden, AWS Secrets Manager, etc.) instead of
  committing them to version control.
* Reload your shell or re-run `source .env` after editing variables so Phoenix picks up the new
  values.
* The production release will fail fast if required variables are missing, making misconfiguration
  obvious during deployment.
