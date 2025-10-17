# Teller Runbook

This runbook captures the day-two operations required to keep the Teller integration healthy across environments.

## Secret rotation

1. Generate a replacement secret in the Teller Console:
   - API keys: Console → Developers → API Keys → "Create API key".
   - Connect application ID: Console → Connect → duplicate or create a new application.
   - Webhook secret: Console → Webhooks → Signing keys → "Create signing key".
2. Store the new secrets in your secret manager and update the runtime environment variables (`TELLER_API_KEY`,
   `TELLER_CONNECT_APPLICATION_ID`, `TELLER_WEBHOOK_SECRET`).
3. Redeploy or restart each application instance so the updated values are loaded.
4. Deactivate or delete the previous secrets in the Teller Console once the new values are confirmed working.

## Retriggering syncs

Teller synchronisation runs through `MoneyTree.Workers.TellerSync` jobs on the Oban `default` queue.

- **Manual retry:** Use the Oban dashboard or connect to the database and run
  `UPDATE oban_jobs SET state = 'available' WHERE worker = 'MoneyTree.Workers.TellerSync' AND state = 'retryable';`.
- **Drain locally:** In development, start the server with `iex -S mix phx.server` and call
  `Oban.drain_queue(queue: :default, with_scheduled: true, with_safety: false)` to process outstanding jobs immediately.
- **Full rebuild:** If a connection becomes unsynchronised, enqueue a fresh job via `MoneyTree.Teller.Sync.enqueue/1` from
  `iex` with the account ID.

## Troubleshooting webhook failures

1. **Check delivery status:** Review webhook delivery logs in the Teller Console to confirm requests reached MoneyTree.
2. **Inspect application logs:** Look for `MoneyTreeWeb.TellerWebhookController` entries and error stack traces. Failed requests
   should surface as 4xx/5xx responses.
3. **Validate signatures:** Ensure `TELLER_WEBHOOK_SECRET` matches the current signing key. Rotate the secret if verification
   fails repeatedly.
4. **Confirm tunnel availability:** For local development, verify your tunnel (`cloudflared`, `ngrok`, etc.) is running and the
   URL matches the webhook configuration. Restart the tunnel to issue a new URL if necessary.
5. **Replay events:** Use the Teller Console to replay failed deliveries after resolving configuration issues. MoneyTree will
   process the events idempotently.
6. **Escalate:** Persistent 5xx responses or missing data should be escalated to Teller support with timestamps, request IDs,
   and relevant log excerpts.
