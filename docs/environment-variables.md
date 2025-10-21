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

## Teller integration

Teller credentials are mandatory in production environments. Use sandbox values for development and
never commit secrets to the repository.

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `TELLER_API_KEY` | Yes (production) | — | Teller API key for direct API requests. Obtain from the Teller Console. |
| `TELLER_CONNECT_APPLICATION_ID` | Yes (production) | — | Connect application ID embedded in Teller Connect sessions. |
| `TELLER_WEBHOOK_SECRET` | Yes (production) | — | Webhook signing secret used to verify Teller webhook payloads. |
| `TELLER_API_HOST` | No | Teller default | Override the Teller API base URL when instructed by Teller support. |
| `TELLER_CONNECT_HOST` | No | Teller default | Override the Teller Connect base URL for non-standard environments. |
| `TELLER_WEBHOOK_HOST` | No | Teller default | Override the webhook host when using alternative tunnels or sandbox endpoints. |
| `TELLER_CERT_PEM` | No | — | Inline PEM-encoded client certificate for mutual TLS. Provide either this or `TELLER_CERT_FILE`. |
| `TELLER_KEY_PEM` | No | — | Inline PEM-encoded private key that pairs with `TELLER_CERT_PEM`. |
| `TELLER_CERT_FILE` | No | — | Filesystem path to the client certificate (PEM) used for mutual TLS. |
| `TELLER_KEY_FILE` | No | — | Filesystem path to the client private key (PEM). |

## Additional tips

* Store secrets in a credential manager (1Password, Bitwarden, AWS Secrets Manager, etc.) instead of
  committing them to version control.
* Reload your shell or re-run `source .env` after editing variables so Phoenix picks up the new
  values.
* The production release will fail fast if required variables are missing, making misconfiguration
  obvious during deployment.
