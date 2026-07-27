# OpenBao production runbook

This runbook covers the production handoff for MoneyTree's OpenBao secret backend. It is intentionally
status-only and operator-focused; do not paste raw secret values into this document, tickets, logs, or
browser surfaces.

## Current support level

- Local compose-backed OpenBao validation is working.
- The app supports `MONEYTREE_SECRET_BACKEND=openbao` with AppRole auth and KV v2 reads.
- Production/staging still need real OpenBao infrastructure, persistent storage, TLS, network controls,
  policies, AppRole credentials, and a verified boot.

## Production policy

Apply the read-only policy in
[`config/openbao/moneytree-prod-read.hcl`](../../config/openbao/moneytree-prod-read.hcl).

Example:

```bash
bao policy write moneytree-prod-read config/openbao/moneytree-prod-read.hcl
```

The policy grants read access only to:

- `kv/data/moneytree/prod/database`
- `kv/data/moneytree/prod/cloak`
- `kv/data/moneytree/prod/fred`
- `kv/data/moneytree/prod/marketcheck`
- `kv/data/moneytree/prod/phoenix`
- `kv/data/moneytree/prod/plaid`
- `kv/data/moneytree/prod/smtp`

Do not grant MoneyTree list, write, auth-management, or unrelated secret-tree access.

## Secret groups

Use the exact environment variable names that MoneyTree already resolves:

| Group | Path | Keys |
| --- | --- | --- |
| `database` | `kv/moneytree/prod/database` | `DATABASE_URL` or `DATABASE_USERNAME`, `DATABASE_PASSWORD`, `DATABASE_HOST`, `DATABASE_NAME` |
| `cloak` | `kv/moneytree/prod/cloak` | `CLOAK_VAULT_KEY` |
| `fred` | `kv/moneytree/prod/fred` | `FRED_API_KEY` |
| `marketcheck` | `kv/moneytree/prod/marketcheck` | `MARKETCHECK_API_KEY` |
| `phoenix` | `kv/moneytree/prod/phoenix` | `SECRET_KEY_BASE` |
| `plaid` | `kv/moneytree/prod/plaid` | `PLAID_CLIENT_ID`, `PLAID_SECRET`, `PLAID_WEBHOOK_SECRET` |
| `smtp` | `kv/moneytree/prod/smtp` | `MAILER_SMTP_HOST`, `MAILER_SMTP_USERNAME`, `MAILER_SMTP_PASSWORD` |

The `bao kv` CLI omits `/data/` in commands for KV v2 mounts. For example, write production Phoenix
secrets with:

```bash
bao kv put kv/moneytree/prod/phoenix SECRET_KEY_BASE="$SECRET_KEY_BASE"
```

MoneyTree reads the same payload through `OPENBAO_KV_PREFIX=kv/data/moneytree/prod`.

## AppRole setup

Create a dedicated production AppRole:

```bash
bao auth enable approle
bao write auth/approle/role/moneytree-prod \
  token_policies=moneytree-prod-read \
  token_ttl=1h \
  token_max_ttl=4h
bao read -field=role_id auth/approle/role/moneytree-prod/role-id
bao write -f -field=secret_id auth/approle/role/moneytree-prod/secret-id
```

Store the resulting `OPENBAO_ROLE_ID` and `OPENBAO_SECRET_ID` in the deployment environment or platform
secret store. They are bootstrap credentials, not browser configuration.

## Deployment environment

Set these on the production application host:

```bash
MONEYTREE_SECRET_BACKEND=openbao
OPENBAO_ADDR=https://bao.internal:8200
OPENBAO_AUTH_METHOD=approle
OPENBAO_ROLE_ID=...
OPENBAO_SECRET_ID=...
OPENBAO_KV_PREFIX=kv/data/moneytree/prod
OPENBAO_SSL_VERIFY=true
OPENBAO_TIMEOUT_MS=5000
```

`OPENBAO_NAMESPACE` is optional and should stay blank unless the OpenBao deployment uses namespaces.

## Preflight

Before switching a deployment to OpenBao-backed mode, run:

```bash
ENV_FILE=/path/to/production-env ./scripts/check_openbao_backend.sh
```

The script checks live group resolution through MoneyTree's OpenBao code path and prints status only. It
does not print secret values.

## Cutover checklist

1. OpenBao is running with persistent storage, TLS, backups, and restricted network access.
2. `moneytree-prod-read` policy is applied from the checked-in policy file.
3. `moneytree-prod` AppRole exists and has only `moneytree-prod-read`.
4. All required secret groups are loaded under `kv/moneytree/prod/*`.
5. Production environment has only OpenBao metadata/bootstrap variables plus non-secret app config.
6. `./scripts/check_openbao_backend.sh` passes against production-style environment metadata.
7. Deploy with `MONEYTREE_SECRET_BACKEND=openbao`.
8. Verify app boot, owner secret-backend status, database access, email delivery, and enabled bank-provider flows.
9. Remove redundant plaintext production env secrets where practical after successful verification.

## Rollback

If production fails to boot after switching to OpenBao:

1. keep OpenBao logs and MoneyTree startup logs for diagnosis
2. restore the previous env-backed deployment configuration
3. set `MONEYTREE_SECRET_BACKEND=env`
4. restart MoneyTree
5. correct OpenBao paths, policy, AppRole, or network/TLS issues before retrying

Do not leave production in a partial state where some critical secrets come from OpenBao and others are
silently taken from stale plaintext variables unless that fallback has been intentionally approved.

## Rotation

For ordinary integration secrets, write the new value to the same OpenBao path, restart MoneyTree
instances, and verify the affected flow.

For `SECRET_KEY_BASE`, rotation invalidates signed sessions and cookies. Treat it as a planned maintenance
event.

For `CLOAK_VAULT_KEY`, do not rotate casually. Existing encrypted database fields depend on this key.
Plan a dedicated multi-key or re-encryption migration before changing it.

For AppRole `secret_id`, generate a new `secret_id`, update the deployment bootstrap variable, restart
MoneyTree, then revoke the old credential if the OpenBao deployment tracks secret IDs individually.

## Outage behavior

MoneyTree resolves runtime secrets during boot. If OpenBao is unreachable or a required group is missing,
production should fail to start rather than run with incomplete financial/security configuration.

Operationally:

- keep OpenBao on trusted network paths only
- monitor OpenBao availability separately from MoneyTree
- back up OpenBao storage according to the selected storage backend
- test restoration in a non-production environment before relying on it
