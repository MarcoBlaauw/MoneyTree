# Plaid Runbook

This runbook captures day-two operations for the Plaid integration in `MoneyTree`.

## Required runtime values

Configure these environment variables before starting the app:

- `PLAID_CLIENT_ID`
- `PLAID_SECRET`
- `PLAID_ENV` (defaults to `sandbox`)
- `PLAID_PRODUCTS` (defaults to `transactions`)
- `PLAID_COUNTRY_CODES` (defaults to `US`)
- `PLAID_CLIENT_NAME` (defaults to `MoneyTree`)
- `PLAID_LANGUAGE` (defaults to `en`)
- `PLAID_WEBHOOK_SECRET` (required for webhook signature verification)
- optional: `PLAID_REDIRECT_URI`, `PLAID_API_HOST`

Use `./scripts/dev.sh` for local startup so migrations and app services are brought up consistently.

## Secret rotation

1. Generate replacement Plaid API credentials in the Plaid dashboard.
2. Generate and store a new webhook signing secret for `PLAID_WEBHOOK_SECRET`.
3. Update secrets in your secret manager and runtime environment.
4. Redeploy or restart application instances so the new values are loaded.
5. Revoke old credentials after confirming token creation, exchange, and webhook delivery still work.

## Local sandbox setup

1. Set `PLAID_ENV=sandbox`.
2. Set `PLAID_CLIENT_ID`, `PLAID_SECRET`, and `PLAID_WEBHOOK_SECRET` in `.env`.
3. Start with `./scripts/dev.sh`.
4. Open `/app/react/link-bank` and complete a Plaid Link flow.
5. Confirm a `provider: "plaid"` row exists in `institution_connections` with:
   - `encrypted_credentials` containing an access token payload
   - `provider_metadata` containing Plaid exchange metadata
6. Confirm accounts and transactions were imported for the new connection.

## Webhook tunnel and replay

For local webhook testing, expose Phoenix through a tunnel (`ngrok`, `cloudflared`, etc.) and point Plaid webhooks to:

- `POST /api/plaid/webhook`

Current webhook validation expects:

- `plaid-signature` header: lowercase hex HMAC-SHA256 of `"#{timestamp}.#{raw_body}"` using `PLAID_WEBHOOK_SECRET`
- `plaid-timestamp` header: unix timestamp (seconds)
- JSON body with `connection_id`, `event`, and `nonce`

Replay example:

```bash
body='{"connection_id":"<connection-id>","event":"SYNC_UPDATES_AVAILABLE","nonce":"manual-replay-001"}'
timestamp="$(date +%s)"
sig="$(printf '%s' "${timestamp}.${body}" | openssl dgst -sha256 -hmac "$PLAID_WEBHOOK_SECRET" -hex | sed 's/^.* //')"

curl -X POST "https://<your-tunnel-host>/api/plaid/webhook" \
  -H "content-type: application/json" \
  -H "plaid-timestamp: ${timestamp}" \
  -H "plaid-signature: ${sig}" \
  -d "${body}"
```

Expected result:

- `200 {"status":"ok"}` when accepted
- `200 {"status":"ignored",...}` when duplicate, revoked, or unknown
- `400 {"error":"invalid webhook"}` when signature/body is invalid

## Retriggering syncs

Plaid jobs run as `MoneyTree.Plaid.SyncWorker` on Oban `default`.

- Manual retry in DB:
  `UPDATE oban_jobs SET state = 'available' WHERE worker = 'MoneyTree.Plaid.SyncWorker' AND state = 'retryable';`
- Drain queue locally:
  `iex -S mix phx.server` then `Oban.drain_queue(queue: :default, with_scheduled: true, with_safety: false)`
- Enqueue sync explicitly in `iex`:
  `{:ok, c} = MoneyTree.Institutions.get_connection("<connection-id>")`
  `MoneyTree.Synchronization.schedule_initial_sync(c)`
  `MoneyTree.Synchronization.schedule_incremental_sync(c)`

## First places to inspect during incidents

1. Phoenix logs for `MoneyTreeWeb.PlaidController` and `MoneyTreeWeb.PlaidWebhookController`.
2. Oban jobs for `MoneyTree.Plaid.SyncWorker` failures and retries.
3. Connection metadata (`institution_connections.metadata`) for webhook replay and dedupe state under `plaid_webhook`.
4. Plaid client error details (`error_code`, `error_type`, `request_id`) surfaced by the backend.
5. Recent telemetry/audit events: `plaid_sync_started`, `plaid_sync_succeeded`, `plaid_sync_failed`.
