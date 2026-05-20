# SimpleFIN Bridge Migration Implementation Guide

## Purpose

This guide replaces the current Teller/Plaid-first bank-sync direction with a SimpleFIN Bridge-first approach for MoneyTree.

SimpleFIN Bridge is a better fit for the current product direction because it uses a simple user-controlled setup token flow, provides read-only financial data access, avoids embedded vendor widgets, and fits self-hosted/privacy-conscious users better than a Plaid/Teller-style integration.

This document also covers how to disable Teller and Plaid for new connections without deleting existing account or transaction history.

## Source Notes

Primary sources:

- SimpleFIN Protocol: https://www.simplefin.org/protocol.html
- SimpleFIN Bridge developer guide: https://beta-bridge.simplefin.org/info/developers
- Actual Budget SimpleFIN setup notes: https://actualbudget.org/docs/advanced/bank-sync/simplefin/

Facts this guide relies on:

- A SimpleFIN setup token is a Base64-encoded claim URL.
- The app claims the setup token by sending `POST` to the decoded claim URL.
- The claim response is an Access URL with embedded Basic Auth credentials.
- The setup token is one-time use and must not be stored after claim.
- Account and transaction data is fetched from `GET /accounts` relative to the Access URL.
- `GET /accounts` supports `start-date`, `end-date`, `pending`, `account`, `balances-only`, and `version` query parameters.
- Protocol v2 uses `errlist` and `connections`; the older `errors` list is deprecated but should still be tolerated.
- SimpleFIN Bridge is intended for daily updates. The developer guide currently expects 24 requests or fewer per day, with some setup leeway.
- The date range for `/accounts` requests is limited to 90 days at a time.

## Current Repo State To Account For

The repo already contains Teller and Plaid integration surfaces. Do not start by deleting them.

Relevant current surfaces:

- `docs/01-plaid-integration-implementation-plan.md`
- `docs/environment-variables.md`
- `docs/vendor-integrations.md`
- `apps/money_tree/lib/money_tree/institutions/connection.ex`
- `apps/money_tree/lib/money_tree/teller/`
- `apps/money_tree/lib/money_tree/plaid/`
- `apps/money_tree/lib/money_tree_web/controllers/teller_controller.ex`
- `apps/money_tree/lib/money_tree_web/controllers/teller_webhook_controller.ex`
- `apps/money_tree/lib/money_tree_web/controllers/plaid_controller.ex`
- `apps/money_tree/lib/money_tree_web/controllers/plaid_webhook_controller.ex`
- `apps/next/app/link-bank/`

Important current constraint:

- `MoneyTree.Institutions.Connection` currently validates `provider` against only `"teller"` and `"plaid"`. Add `"simplefin"` before attempting to persist SimpleFIN connections.

This guide intentionally supersedes the Plaid-first direction from `docs/01-plaid-integration-implementation-plan.md`, but that older document can remain as historical context until SimpleFIN is stable.

## Decision

Use SimpleFIN Bridge as the primary connected-account provider for MoneyTree v1 bank sync.

Disable Teller and Plaid for new connections behind feature flags. Preserve existing Teller/Plaid-imported accounts and transactions. Leave old provider records readable until a later cleanup or credential-purge feature exists.

Recommended provider order:

1. Manual CSV/XLSX imports
2. SimpleFIN Bridge sync
3. Teller legacy records, disabled for new links
4. Plaid legacy records, disabled for new links

Manual import should remain first-class because every aggregator has institution-specific gaps.

## Goals

1. Add a production-ready SimpleFIN Bridge integration.
2. Make SimpleFIN the default provider shown in the bank-linking UI.
3. Add a small provider registry so provider availability is not hardcoded in controllers or React components.
4. Disable Teller and Plaid for new connections without deleting historical data.
5. Store SimpleFIN Access URLs only in encrypted fields.
6. Redact setup tokens, Access URLs, and Basic Auth credentials from logs/errors.
7. Respect SimpleFIN daily sync expectations and 90-day request-window limits.
8. Add tests for token claiming, parsing, sync, rate limiting, and disabled legacy providers.

## Non-Goals

- Deleting Teller/Plaid code in the first pass.
- Migrating historical Teller/Plaid credentials to SimpleFIN.
- Building a Plaid-style embedded widget for SimpleFIN.
- Bypassing SimpleFIN Bridge request limits.
- Assuming SimpleFIN solves all institution coverage issues.
- Storing one-time setup tokens after they are claimed.

## Architecture Overview

Recommended flow:

```text
Next.js link-bank UI
  -> Phoenix SimpleFIN controller
     -> MoneyTree.SimpleFin.Client
        -> decode setup token
        -> POST decoded claim URL
        -> encrypted Access URL stored on institution_connection
        -> GET /accounts polling sync
           -> MoneyTree account/transaction persistence
```

SimpleFIN does not need a browser SDK. The user should leave MoneyTree, create a setup token in SimpleFIN Bridge, return to MoneyTree, and paste the setup token.

Treat SimpleFIN as scheduled polling, not webhook-driven sync.

## Naming Conventions

Use these names consistently:

- Provider string: `simplefin`
- Elixir namespace: `MoneyTree.SimpleFin`
- File path namespace: `apps/money_tree/lib/money_tree/simple_fin/`
- Controller: `MoneyTreeWeb.SimpleFinController`
- Worker: `MoneyTree.SimpleFin.SyncWorker`
- Synchronizer: `MoneyTree.SimpleFin.Synchronizer`

Use the brand spelling `SimpleFIN` in user-facing copy and documentation.

## Environment Variables

SimpleFIN does not need Plaid-style app secrets or Teller-style mTLS certificates.

Add these variables to `.env.example`, `config/runtime.exs`, and `docs/environment-variables.md`:

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `BANK_SYNC_ENABLED_PROVIDERS` | No | `simplefin,manual` | Comma-separated provider list available for new user connections. |
| `BANK_SYNC_PRIMARY_PROVIDER` | No | `simplefin` | Provider shown first in the bank-linking UI. |
| `SIMPLEFIN_CREATE_URL` | No | `https://bridge.simplefin.org/simplefin/create` | URL users visit to create a SimpleFIN setup token. |
| `SIMPLEFIN_PROTOCOL_VERSION` | No | `2` | Protocol version requested in `/accounts` calls. |
| `SIMPLEFIN_SYNC_INTERVAL_HOURS` | No | `24` | Default automatic sync cadence. |
| `SIMPLEFIN_MAX_REQUESTS_PER_CONNECTION_PER_DAY` | No | `24` | Safety cap for requests per stored Access URL. |
| `SIMPLEFIN_INITIAL_SYNC_DAYS` | No | `90` | Initial lookback window. Keep at or below the Bridge range limit. |
| `SIMPLEFIN_INCLUDE_PENDING` | No | `false` | Whether to request pending transactions using `pending=1`. |
| `TELLER_ENABLED` | No | `false` | Compatibility flag for old code paths. Prefer `BANK_SYNC_ENABLED_PROVIDERS` in new code. |
| `PLAID_ENABLED` | No | `false` | Compatibility flag for old code paths. Prefer `BANK_SYNC_ENABLED_PROVIDERS` in new code. |

Production should fail fast only for enabled providers. If Teller/Plaid are disabled, missing Teller/Plaid secrets must not prevent the app from booting.

## Schema And Persistence Plan

### Provider validation

Update `MoneyTree.Institutions.Connection` so `provider` accepts `simplefin`:

```elixir
validate_inclusion(:provider, ["simplefin", "teller", "plaid"])
```

Only add `"manual"` to this enum if manual import batches are represented through institution connections. If manual imports use dedicated import-batch tables, keep `manual` out of this field.

### Credential storage

Store the claimed SimpleFIN Access URL in `encrypted_credentials`.

Recommended encrypted credential shape:

```json
{
  "access_url": "https://username:password@bridge.simplefin.org/simplefin",
  "claimed_at": "2026-05-19T00:00:00Z",
  "protocol_version": "2"
}
```

Rules:

1. Never store the raw setup token after claim.
2. Never log the setup token.
3. Never log the Access URL.
4. Redact Basic Auth credentials from exceptions and telemetry.
5. Reject non-HTTPS claim URLs and Access URLs.
6. Reject setup tokens that do not decode cleanly from Base64.
7. Reject decoded URLs with unsupported schemes, fragments, or suspicious local/private hosts unless an explicit development override exists.

### Provider metadata

Store SimpleFIN-specific non-secret metadata in `provider_metadata`:

```json
{
  "simplefin": {
    "protocol_versions": ["1", "2"],
    "selected_protocol_version": "2",
    "connections": [
      {
        "conn_id": "CON-...",
        "name": "My Bank",
        "org_id": "INST-...",
        "org_name": "My Bank",
        "org_url": "https://examplebank.com",
        "sfin_url": "https://bridge.simplefin.org/simplefin"
      }
    ],
    "last_balances_only_at": "2026-05-19T00:00:00Z",
    "last_full_sync_at": "2026-05-19T00:00:00Z",
    "request_usage": {
      "utc_date": "2026-05-19",
      "accounts_requests": 1
    }
  }
}
```

Support both v1 and v2 response shapes:

- v2: prefer `errlist` and `connections`.
- v1: tolerate `errors`, missing `connections`, and account objects without `conn_id`.

### External IDs

SimpleFIN transaction IDs are unique within an account, not globally. Build external transaction IDs like this:

```text
simplefin:<institution_connection_id>:<simplefin_account_id>:<simplefin_transaction_id>
```

For account external IDs:

```text
simplefin:<institution_connection_id>:<simplefin_account_id>
```

If `conn_id` is available, store it in metadata, but do not use it as the only uniqueness boundary.

## Backend Implementation Plan

### Phase 0: Mark Teller/Plaid As Legacy

1. Add config flags for enabled providers.
2. Update boot validation so disabled providers do not require secrets.
3. Update docs to say Teller/Plaid are legacy-disabled by default.
4. Keep existing tests passing by explicitly enabling Teller/Plaid in tests that still cover old code paths.

### Phase 1: Add Provider Registry

Create:

- `apps/money_tree/lib/money_tree/bank_sync/provider_registry.ex`

Responsibilities:

1. Read `BANK_SYNC_ENABLED_PROVIDERS`.
2. Normalize provider strings.
3. Expose `enabled?/1`, `primary_provider/0`, and `list_enabled/0`.
4. Return provider labels and capabilities for the frontend.

Example provider capability map:

```elixir
%{
  id: "simplefin",
  label: "SimpleFIN Bridge",
  mode: "setup_token",
  supports_manual_refresh: true,
  supports_webhooks: false,
  supports_pending_transactions: :optional,
  default_sync_interval_hours: 24
}
```

### Phase 2: Add SimpleFIN Client

Create:

- `apps/money_tree/lib/money_tree/simple_fin/client.ex`
- `apps/money_tree/lib/money_tree/simple_fin/redaction.ex`

Required public functions:

```elixir
def decode_setup_token(setup_token)
def claim_setup_token(setup_token)
def get_info(access_url)
def get_accounts(access_url, opts \\ [])
def get_account(access_url, account_id, opts \\ [])
def get_balances(access_url, opts \\ [])
```

Implementation rules:

1. Use `Req` consistently with the rest of the Phoenix app.
2. Decode setup tokens with strict Base64 handling.
3. Validate decoded claim URLs before network calls.
4. `POST` to the decoded claim URL.
5. Treat claim HTTP 403 as high-risk because the token may already have been used or compromised.
6. Validate the returned Access URL before storing it.
7. Use Basic Auth from the Access URL when fetching `/accounts`.
8. Use query params instead of string concatenation when building `/accounts` URLs.
9. Default to `version=2` but parse v1-compatible response fields.
10. Normalize errors into tagged tuples.

Suggested normalized errors:

```elixir
{:error, :invalid_setup_token}
{:error, :insecure_claim_url}
{:error, :claim_forbidden}
{:error, :invalid_access_url}
{:error, :payment_required}
{:error, :access_revoked}
{:error, :quota_exceeded}
{:error, {:simplefin_errors, errors}}
{:error, {:http_error, status}}
{:error, {:transport_error, reason}}
```

### Phase 3: Add Controller Endpoints

Create:

- `apps/money_tree/lib/money_tree_web/controllers/simple_fin_controller.ex`

Recommended routes:

```elixir
scope "/api/simplefin", MoneyTreeWeb do
  pipe_through [:browser, :require_authenticated_user]

  get "/config", SimpleFinController, :config
  post "/claim", SimpleFinController, :claim
  post "/sync", SimpleFinController, :sync
end
```

Controller behavior:

1. `GET /config` returns create URL, enabled state, and UI copy.
2. `POST /claim` accepts the setup token, claims it, stores the encrypted Access URL, performs a `balances-only=1` validation fetch, and returns discovered accounts for mapping/review.
3. `POST /sync` schedules a rate-limited sync for the selected SimpleFIN connection.
4. If SimpleFIN is disabled, all endpoints return a stable disabled response.
5. API responses must never include Access URLs or Basic Auth credentials.

### Phase 4: Add Synchronizer

Create:

- `apps/money_tree/lib/money_tree/simple_fin/synchronizer.ex`
- `apps/money_tree/lib/money_tree/simple_fin/sync_worker.ex`

Sync behavior:

1. Load the encrypted Access URL from the connection.
2. Determine the sync window:
   - initial sync: `now - SIMPLEFIN_INITIAL_SYNC_DAYS`
   - incremental sync: last successful sync minus a small overlap window, such as 2-3 days
3. Fetch `/accounts?version=2&start-date=...&end-date=...`.
4. Store balances and balance timestamps.
5. Upsert accounts using the external account ID strategy above.
6. Upsert transactions using the external transaction ID strategy above.
7. Preserve raw SimpleFIN transaction payload in metadata when useful for debugging.
8. Record `last_synced_at`, `last_sync_error`, and `last_sync_error_at`.
9. Save sanitized SimpleFIN `errlist`/`errors` entries so users can see institution-specific sync problems.
10. Enforce request quota before making calls.

### Phase 5: Rate Limiting And Quota Tracking

Start lightweight:

- Store request counters in `provider_metadata.simplefin.request_usage`.
- Reset by UTC day.
- Check before each `/accounts` call.

Rules:

1. Automatic sync should run once per day by default.
2. Manual refresh should be allowed only when it will not exceed the configured cap.
3. Prefer one all-account `/accounts` request per connection per day.
4. Use account-specific requests only for targeted repair/debug flows.
5. Use `balances-only=1` for lightweight validation when transaction data is not needed.

Long-term option:

- Add a `bank_sync_requests` table with provider, connection ID, endpoint, requested_at, status, and sanitized error. This is useful for provider health dashboards and debugging, but not required for v1.

### Phase 6: Frontend Changes

Update:

- `apps/next/app/link-bank/page.tsx`
- `apps/next/app/link-bank/link-bank-client.tsx`
- related frontend tests

New primary flow:

1. Show SimpleFIN Bridge as the default sync option.
2. Explain that MoneyTree never sees the user's bank credentials.
3. Provide a button/link to open `SIMPLEFIN_CREATE_URL` in a new tab.
4. Provide a paste field for the setup token.
5. Submit the setup token to Phoenix.
6. Show discovered accounts for mapping/review.
7. Let the user confirm which accounts should be imported.
8. Show sync status and clear repair instructions if access is revoked, payment is required, or SimpleFIN returns `errlist` entries.

Suggested UI copy:

> SimpleFIN Bridge lets you connect read-only financial data to MoneyTree using a setup token. Create the token in SimpleFIN, paste it here, and MoneyTree will use it to import balances and transactions.

For Teller/Plaid:

- Hide by default when disabled.
- Optionally show under an "Unavailable legacy providers" or developer-only section when explicitly enabled.
- Do not show broken Teller/Plaid buttons to normal users.

### Phase 7: Disable Teller And Plaid Safely

Do not delete old provider modules yet. Disable new usage first.

Backend requirements:

1. `BANK_SYNC_ENABLED_PROVIDERS` defaults to `simplefin,manual`.
2. Teller/Plaid connect-token or link-token endpoints return a stable disabled response when disabled.
3. Teller/Plaid exchange endpoints reject new credentials when disabled.
4. Existing Teller/Plaid sync workers should not schedule new syncs when disabled.
5. Existing Teller/Plaid webhook endpoints should return no-op success when disabled to avoid vendor retry storms, while logging sanitized debug/info messages.
6. Existing Teller/Plaid data remains visible in MoneyTree.
7. Existing Teller/Plaid credentials remain encrypted until an explicit credential purge flow exists.

Frontend requirements:

1. Hide Teller/Plaid cards unless enabled.
2. Remove Teller/Plaid scripts from the main link-bank bundle when disabled.
3. Update CSP only after confirming no enabled UI path needs those origins.

Docs requirements:

1. Update `docs/vendor-integrations.md` to say Plaid/Teller origins are legacy-only and not needed when disabled.
2. Update `docs/environment-variables.md` so Teller/Plaid variables are required only if those providers are enabled.
3. Add SimpleFIN variables and setup instructions.
4. Add a short migration note to `README.md` if the README currently points users toward Teller or Plaid.

## Security Requirements

SimpleFIN is simpler than Teller/Plaid, but the Access URL is highly sensitive.

Mandatory safeguards:

1. Treat Access URLs as credentials.
2. Store Access URLs only inside encrypted fields.
3. Redact URL `userinfo` before logging.
4. Reject non-HTTPS URLs.
5. Verify TLS certificates.
6. Do not follow redirects from HTTPS to HTTP.
7. Do not display raw provider errors without sanitization.
8. Do not store setup tokens after claim.
9. Show a strong warning when claim returns 403.
10. Add tests proving setup tokens and Access URLs are redacted from logs/errors.

Recommended redaction shape:

```text
https://[redacted]@bridge.simplefin.org/simplefin
```

## Error Handling UX

| Condition | Backend classification | User-facing message |
| --- | --- | --- |
| Invalid Base64 token | `:invalid_setup_token` | `That setup token does not look valid. Please create a new SimpleFIN setup token and try again.` |
| Claim URL is not HTTPS | `:insecure_claim_url` | `MoneyTree rejected this token because it did not point to a secure SimpleFIN endpoint.` |
| Claim returned 403 | `:claim_forbidden` | `SimpleFIN rejected this setup token. It may have expired, already been used, or been exposed. Please disable it in SimpleFIN and create a new one.` |
| `/accounts` returned 402 | `:payment_required` | `SimpleFIN says this connection requires an active subscription before MoneyTree can sync it.` |
| `/accounts` returned 403 | `:access_revoked` | `MoneyTree can no longer access this SimpleFIN connection. Please reconnect it from SimpleFIN.` |
| `errlist`/`errors` present | `{:simplefin_errors, errors}` | Show sanitized provider messages and mark affected connection/account as needing attention. |
| Quota exceeded locally | `:quota_exceeded` | `MoneyTree already refreshed this connection recently. Try again after the next scheduled sync window.` |

## Transaction Mapping Rules

SimpleFIN amounts use positive numbers for money deposited into the account and negative numbers for money leaving the account.

MoneyTree should normalize transactions according to its internal sign convention, but preserve the original amount string in metadata.

| SimpleFIN field | MoneyTree destination |
| --- | --- |
| `id` | part of provider external transaction ID |
| `posted` | posted date/time |
| `transacted_at` | transaction date/time when present |
| `amount` | normalized amount plus raw amount metadata |
| `description` | original/payee/description field |
| `pending` | pending flag |
| `extra` | provider metadata |

Pending transaction rule:

- v1 should default to excluding pending transactions.
- If pending support is added later, pending transactions need a replacement/merge strategy once the posted transaction arrives.

## Account Mapping Rules

| SimpleFIN field | MoneyTree destination |
| --- | --- |
| `id` | part of provider external account ID |
| `name` | display name suggestion |
| `currency` | currency |
| `balance` | current balance |
| `available-balance` | available balance, if MoneyTree supports it |
| `balance-date` | balance timestamp |
| `conn_id` | provider metadata |
| `extra` | provider metadata |

Custom currencies are possible in SimpleFIN. MoneyTree can start by supporting normal ISO 4217 currency codes and gracefully flag unsupported custom currencies.

## Testing Plan

### Unit tests

Add tests for:

1. Base64 setup-token decode.
2. Invalid setup-token rejection.
3. HTTPS-only claim URL validation.
4. Access URL validation and redaction.
5. Claim success.
6. Claim 403 handling.
7. `/accounts` 402 and 403 handling.
8. v2 response parsing with `errlist` and `connections`.
9. v1-style response parsing with `errors` and no `connections`.
10. Account external ID generation.
11. Transaction external ID generation.
12. Amount sign preservation and normalization.
13. Rate-limit guard behavior.

### Controller tests

Add tests for:

1. `GET /api/simplefin/config` when SimpleFIN is enabled.
2. `GET /api/simplefin/config` when SimpleFIN is disabled.
3. `POST /api/simplefin/claim` success.
4. `POST /api/simplefin/claim` invalid token.
5. `POST /api/simplefin/claim` claim forbidden.
6. API responses never include Access URLs.
7. Disabled Teller/Plaid endpoints reject new link/exchange flows.

### Worker/sync tests

Add tests for:

1. Initial 90-day sync window.
2. Incremental sync with overlap.
3. Request quota enforcement.
4. Account upsert idempotency.
5. Transaction upsert idempotency.
6. Sanitized error persistence.
7. No Teller/Plaid worker scheduling when disabled.

### Frontend tests

Add tests for:

1. SimpleFIN shown as primary provider.
2. Setup-token paste flow.
3. Account mapping/review state.
4. Teller/Plaid hidden when disabled.
5. Disabled provider messaging in developer mode, if implemented.

## Rollout Plan

### Milestone 1: Provider flags and docs

- Add provider enable/disable config.
- Default enabled providers to `simplefin,manual`.
- Make Teller/Plaid secrets optional when disabled.
- Add SimpleFIN env docs.
- Keep old provider tests working with explicit test config.

### Milestone 2: SimpleFIN client and parser

- Add `MoneyTree.SimpleFin.Client`.
- Add parser/normalizer helpers.
- Add redaction helpers.
- Add unit tests.

### Milestone 3: Persistence and provider enum

- Add `simplefin` to provider validation.
- Store claimed Access URL in encrypted credentials.
- Store protocol/account metadata in provider metadata.
- Add tests for changesets and persistence.

### Milestone 4: Claim and account discovery flow

- Add controller endpoints.
- Add frontend setup-token flow.
- Add balances-only validation fetch.
- Show account mapping/review UI.

### Milestone 5: Scheduled sync

- Add synchronizer and Oban worker.
- Add quota guard.
- Add initial and incremental sync behavior.
- Add account/transaction upsert tests.

### Milestone 6: Disable Teller/Plaid for new usage

- Hide Teller/Plaid in frontend by default.
- Return disabled responses from new-link/exchange endpoints.
- Stop Teller/Plaid background scheduling when disabled.
- Make Teller/Plaid webhooks no-op successfully when disabled.
- Update CSP docs after confirming no active widget paths remain.

### Milestone 7: Cleanup pass

Only after SimpleFIN is stable:

- Decide whether to remove Plaid scaffold code or keep it as a future optional adapter.
- Decide whether to remove Teller code or keep it as legacy import support.
- Add a credential purge flow for disabled providers.
- Remove obsolete CSP origins when the old providers are fully inactive.

## Codex Implementation Slices

### Slice A: Provider registry and feature flags

Files likely touched:

- `config/runtime.exs`
- `.env.example`
- `docs/environment-variables.md`
- `apps/money_tree/lib/money_tree/bank_sync/provider_registry.ex`
- new tests under `apps/money_tree/test/money_tree/bank_sync/`

Acceptance criteria:

- SimpleFIN and manual are enabled by default.
- Teller/Plaid are disabled by default.
- Disabled providers do not require missing secrets in production boot validation.

### Slice B: SimpleFIN client

Files likely touched:

- `apps/money_tree/lib/money_tree/simple_fin/client.ex`
- `apps/money_tree/lib/money_tree/simple_fin/redaction.ex`
- `apps/money_tree/test/money_tree/simple_fin/client_test.exs`

Acceptance criteria:

- Setup token claim works in mocked tests.
- Bad tokens and insecure URLs are rejected.
- Access URLs are redacted in all error paths.

### Slice C: Persistence changes

Files likely touched:

- `apps/money_tree/lib/money_tree/institutions/connection.ex`
- institution fixtures/factories
- connection changeset tests

Acceptance criteria:

- `provider: "simplefin"` is valid.
- Existing Teller/Plaid records remain valid.
- Unknown providers are still rejected.

### Slice D: SimpleFIN claim controller

Files likely touched:

- `apps/money_tree/lib/money_tree_web/controllers/simple_fin_controller.ex`
- `apps/money_tree/lib/money_tree_web/router.ex`
- controller tests

Acceptance criteria:

- Authenticated users can claim setup tokens.
- Claimed Access URL is encrypted.
- Response contains only safe account metadata.

### Slice E: SimpleFIN synchronizer

Files likely touched:

- `apps/money_tree/lib/money_tree/simple_fin/synchronizer.ex`
- `apps/money_tree/lib/money_tree/simple_fin/sync_worker.ex`
- sync tests

Acceptance criteria:

- Initial sync imports accounts and transactions.
- Re-running sync is idempotent.
- Rate limits are enforced.

### Slice F: Frontend primary provider flow

Files likely touched:

- `apps/next/app/link-bank/page.tsx`
- `apps/next/app/link-bank/link-bank-client.tsx`
- frontend tests

Acceptance criteria:

- SimpleFIN is the default visible provider.
- Teller/Plaid are hidden unless enabled.
- Users can paste a setup token and review discovered accounts.

### Slice G: Legacy provider disablement

Files likely touched:

- Teller/Plaid controllers
- Teller/Plaid sync workers
- `docs/vendor-integrations.md`
- tests for disabled behavior

Acceptance criteria:

- New Teller/Plaid links cannot be created when disabled.
- Existing data remains visible.
- Disabled webhooks return no-op success without scheduling syncs.

## Open Questions

1. Should manual imports be modeled as `provider = "manual"` institution connections, or should they remain entirely separate import batches?
2. Should SimpleFIN account mapping happen immediately after claim, or should MoneyTree import all discovered accounts first and let users hide/archive unwanted accounts later?
3. Should pending transactions stay unsupported for v1, or should there be an opt-in per account?
4. Should we add a dedicated provider request log table now, or start with lightweight request counters in `provider_metadata`?
5. Should existing Teller/Plaid credentials be purged automatically after a retention period, or only by explicit user/admin action?

## Recommendation

Implement SimpleFIN as the primary bank-sync provider now, but do it through a small provider registry so MoneyTree does not become hardcoded to any single aggregator again.

Teller and Plaid should be disabled, not deleted, during the first migration. That keeps historical data safe and gives MoneyTree an escape hatch if SimpleFIN has institution-specific gaps. Once SimpleFIN plus manual imports are stable, do a separate cleanup pass to remove or archive dead provider code.
