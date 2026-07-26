#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"

load_env_file() {
  local file="$1"
  local line key value

  if [[ ! -f "$file" ]]; then
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"

    [[ -z "$line" ]] && continue
    [[ "${line:0:1}" == "#" ]] && continue
    [[ "$line" != *=* ]] && continue

    key="${line%%=*}"
    value="${line#*=}"

    if [[ -n "$key" ]]; then
      export "$key=$value"
    fi
  done < "$file"
}

apply_defaults() {
  OPENBAO_ADDR="${OPENBAO_ADDR:-http://localhost:8200}"
  OPENBAO_INTERNAL_ADDR="${OPENBAO_INTERNAL_ADDR:-http://127.0.0.1:8200}"
  OPENBAO_ROOT_TOKEN="${OPENBAO_DEV_ROOT_TOKEN:-moneytree-dev-root-token}"
  OPENBAO_ROLE_NAME="${OPENBAO_ROLE_NAME:-moneytree-dev}"
  OPENBAO_POLICY_NAME="${OPENBAO_POLICY_NAME:-moneytree-dev-read}"
  OPENBAO_KV_PREFIX="${OPENBAO_KV_PREFIX:-kv/data/moneytree/dev}"
  OPENBAO_CLI_KV_PREFIX="${OPENBAO_CLI_KV_PREFIX:-kv/moneytree/dev}"
}

bao() {
  docker compose exec -T \
    -e "BAO_ADDR=$OPENBAO_INTERNAL_ADDR" \
    -e "BAO_TOKEN=$OPENBAO_ROOT_TOKEN" \
    openbao bao "$@"
}

wait_for_openbao() {
  local attempt

  for attempt in $(seq 1 30); do
    if bao status >/dev/null 2>&1; then
      return 0
    fi

    sleep 1
  done

  echo "OpenBao did not become ready on $OPENBAO_ADDR." >&2
  return 1
}

enable_secret_mount() {
  if bao secrets list -format=json | grep -q '"kv/"'; then
    return 0
  fi

  bao secrets enable -path=kv kv-v2 >/dev/null
}

enable_approle() {
  if bao auth list -format=json | grep -q '"approle/"'; then
    return 0
  fi

  bao auth enable approle >/dev/null
}

write_policy() {
  bao policy write "$OPENBAO_POLICY_NAME" - >/dev/null <<EOF
path "kv/data/moneytree/dev/database" {
  capabilities = ["read"]
}

path "kv/data/moneytree/dev/cloak" {
  capabilities = ["read"]
}

path "kv/data/moneytree/dev/fred" {
  capabilities = ["read"]
}

path "kv/data/moneytree/dev/phoenix" {
  capabilities = ["read"]
}

path "kv/data/moneytree/dev/plaid" {
  capabilities = ["read"]
}

path "kv/data/moneytree/dev/smtp" {
  capabilities = ["read"]
}
EOF
}

write_approle() {
  bao write "auth/approle/role/$OPENBAO_ROLE_NAME" \
    "token_policies=$OPENBAO_POLICY_NAME" \
    token_ttl=1h \
    token_max_ttl=4h >/dev/null
}

put_group() {
  local group="$1"
  shift

  local path="$OPENBAO_CLI_KV_PREFIX/$group"
  local args=("_moneytree_group=$group")
  local key value

  for key in "$@"; do
    value="${!key-}"

    if [[ -n "$value" ]]; then
      args+=("$key=$value")
    fi
  done

  bao kv put "$path" "${args[@]}" >/dev/null
}

seed_secret_groups() {
  export DATABASE_URL="${DATABASE_URL:-ecto://postgres:postgres@localhost/money_tree_dev}"

  put_group database \
    DATABASE_URL \
    DATABASE_USERNAME \
    DATABASE_PASSWORD \
    DATABASE_HOST \
    DATABASE_NAME

  put_group cloak CLOAK_VAULT_KEY
  put_group fred FRED_API_KEY
  put_group phoenix SECRET_KEY_BASE

  put_group plaid \
    PLAID_CLIENT_ID \
    PLAID_SECRET \
    PLAID_WEBHOOK_SECRET

  put_group smtp \
    MAILER_SMTP_HOST \
    MAILER_SMTP_USERNAME \
    MAILER_SMTP_PASSWORD
}

upsert_env_var() {
  local key="$1"
  local value="$2"
  local tmp

  touch "$ENV_FILE"
  tmp="$(mktemp)"

  awk -v key="$key" 'index($0, key "=") != 1 { print }' "$ENV_FILE" > "$tmp"
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$ENV_FILE"
}

write_local_env_metadata() {
  local role_id secret_id

  role_id="$(bao read -field=role_id "auth/approle/role/$OPENBAO_ROLE_NAME/role-id")"
  secret_id="$(bao write -f -field=secret_id "auth/approle/role/$OPENBAO_ROLE_NAME/secret-id")"

  upsert_env_var MONEYTREE_SECRET_BACKEND openbao
  upsert_env_var OPENBAO_ADDR "$OPENBAO_ADDR"
  upsert_env_var OPENBAO_NAMESPACE ""
  upsert_env_var OPENBAO_AUTH_METHOD approle
  upsert_env_var OPENBAO_ROLE_ID "$role_id"
  upsert_env_var OPENBAO_SECRET_ID "$secret_id"
  upsert_env_var OPENBAO_KV_PREFIX "$OPENBAO_KV_PREFIX"
  upsert_env_var OPENBAO_SSL_VERIFY false
  upsert_env_var OPENBAO_TIMEOUT_MS 5000
}

main() {
  cd "$ROOT_DIR"

  load_env_file "$ENV_FILE"
  apply_defaults

  docker compose up -d openbao >/dev/null
  wait_for_openbao
  enable_secret_mount
  enable_approle
  write_policy
  write_approle
  seed_secret_groups
  write_local_env_metadata

  echo "OpenBao dev service is running on $OPENBAO_ADDR."
  echo "MoneyTree dev AppRole metadata was written to $ENV_FILE."
  echo "Secret groups were seeded under $OPENBAO_KV_PREFIX."
}

main "$@"
