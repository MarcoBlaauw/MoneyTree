# Environment variable reference

MoneyTree loads configuration from the process environment at runtime. Use the values in
[`.env.example`](../.env.example) as a starting point, then tailor them to your local or hosted
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

## Encryption & credentials

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `CLOAK_VAULT_KEY` | Yes | — | Base64-encoded key that secures encrypted fields via Cloak. Rotate and store securely. |

## Oban background processing

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `OBAN_DEFAULT_LIMIT` | No | `10` | Concurrent jobs allowed on the default queue. |
| `OBAN_MAILER_LIMIT` | No | `5` | Concurrent jobs allowed on the mailer queue. |
| `OBAN_REPORTING_LIMIT` | No | `5` | Concurrent jobs allowed on the reporting queue. |

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

## Teller integration

Teller integration requires app-level Connect/webhook configuration plus a client certificate/private
key pair for mTLS. End-user account access tokens are not configured globally; they are returned by
Teller during the exchange flow and stored on each institution connection.

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `TELLER_CONNECT_APPLICATION_ID` | Yes (production) | — | Connect application ID embedded in Teller Connect sessions. |
| `TELLER_WEBHOOK_SECRET` | Yes (production) | — | Webhook signing secret used to verify Teller webhook payloads. |
| `TELLER_API_HOST` | No | Teller default | Override the Teller API base URL when instructed by Teller support. |
| `TELLER_CONNECT_HOST` | No | Teller default | Override the Teller Connect base URL for non-standard environments. |
| `TELLER_WEBHOOK_HOST` | No | Teller default | Override the webhook host when using alternative tunnels or sandbox endpoints. |
| `TELLER_CERT_PEM` | Yes (production, unless using files) | — | Inline PEM-encoded client certificate for Teller mTLS. Provide either this and `TELLER_KEY_PEM`, or file-based equivalents. |
| `TELLER_KEY_PEM` | Yes (production, unless using files) | — | Inline PEM-encoded private key that pairs with `TELLER_CERT_PEM`. |
| `TELLER_CERT_FILE` | Yes (production, unless using PEM vars) | — | Filesystem path to the client certificate (PEM) used for Teller mTLS. |
| `TELLER_KEY_FILE` | Yes (production, unless using PEM vars) | — | Filesystem path to the client private key (PEM). |

## Stripe Connect integration

Stripe Connect is optional and only required if you want to launch Stripe OAuth from the
`/app/react/link-bank` flow.

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `STRIPE_CONNECT_CLIENT_ID` | Yes (when Stripe Connect flow enabled) | — | Stripe Connect platform client ID used to start OAuth. |
| `STRIPE_CONNECT_REDIRECT_URI` | Yes (when Stripe Connect flow enabled) | — | OAuth redirect URI configured in Stripe and used by MoneyTree when building the authorization URL. |
| `STRIPE_CONNECT_HOST` | No | `https://connect.stripe.com` | Optional Stripe Connect host override for non-standard environments. |
| `STRIPE_CONNECT_SCOPE` | No | `read_write` | OAuth scope sent when creating Stripe Connect authorization sessions. |

## Plaid integration

Plaid integration is used by the `/app/react/link-bank` flow to create Link tokens, exchange
public tokens, and synchronize accounts and transactions through Phoenix.

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
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
