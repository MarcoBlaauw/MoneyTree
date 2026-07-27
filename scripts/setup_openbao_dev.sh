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
  OPENBAO_ROOT_TOKEN="${OPENBAO_DEV_ROOT_TOKEN:-}"
  OPENBAO_UNSEAL_KEY="${OPENBAO_DEV_UNSEAL_KEY:-}"
  OPENBAO_ROLE_NAME="${OPENBAO_ROLE_NAME:-moneytree-dev}"
  OPENBAO_POLICY_NAME="${OPENBAO_POLICY_NAME:-moneytree-dev-read}"
  OPENBAO_KV_PREFIX="${OPENBAO_KV_PREFIX:-kv/data/moneytree/dev}"
  OPENBAO_CLI_KV_PREFIX="${OPENBAO_CLI_KV_PREFIX:-kv/moneytree/dev}"
}

bao_unauthenticated() {
  docker compose exec -T \
    -e "BAO_ADDR=$OPENBAO_INTERNAL_ADDR" \
    openbao bao "$@"
}

bao() {
  if [[ -z "$OPENBAO_ROOT_TOKEN" ]]; then
    echo "OPENBAO_DEV_ROOT_TOKEN is unavailable for local OpenBao administration." >&2
    return 1
  fi

  docker compose exec -T \
    -e "BAO_ADDR=$OPENBAO_INTERNAL_ADDR" \
    -e "BAO_TOKEN=$OPENBAO_ROOT_TOKEN" \
    openbao bao "$@"
}

wait_for_openbao() {
  local attempt status

  for attempt in $(seq 1 30); do
    if bao_unauthenticated status >/dev/null 2>&1; then
      return 0
    else
      status=$?

      # `bao status` exits 2 while a persistent server is sealed. That still
      # means the API is ready for initialization or unsealing.
      if [[ "$status" -eq 2 ]]; then
        return 0
      fi
    fi

    sleep 1
  done

  echo "OpenBao did not become ready on $OPENBAO_ADDR." >&2
  return 1
}

upsert_env_var() {
  local key="$1"
  local value="$2"
  local tmp

  touch "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  tmp="$(mktemp)"

  awk -v key="$key" 'index($0, key "=") != 1 { print }' "$ENV_FILE" > "$tmp"
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}

initialize_openbao() {
  local status_json init_json

  status_json="$(bao_unauthenticated status -format=json 2>/dev/null || true)"

  if printf '%s' "$status_json" | jq -e '.initialized == false' >/dev/null; then
    init_json="$(
      bao_unauthenticated operator init \
        -key-shares=1 \
        -key-threshold=1 \
        -format=json
    )"

    OPENBAO_UNSEAL_KEY="$(printf '%s' "$init_json" | jq -er '.unseal_keys_b64[0]')"
    OPENBAO_ROOT_TOKEN="$(printf '%s' "$init_json" | jq -er '.root_token')"

    upsert_env_var OPENBAO_DEV_UNSEAL_KEY "$OPENBAO_UNSEAL_KEY"
    upsert_env_var OPENBAO_DEV_ROOT_TOKEN "$OPENBAO_ROOT_TOKEN"
    export OPENBAO_UNSEAL_KEY OPENBAO_ROOT_TOKEN
    return 0
  fi

  if ! printf '%s' "$status_json" | jq -e '.initialized == true' >/dev/null; then
    echo "Unable to determine whether the local OpenBao service is initialized." >&2
    return 1
  fi
}

unseal_openbao() {
  local status_json

  status_json="$(bao_unauthenticated status -format=json 2>/dev/null || true)"

  if printf '%s' "$status_json" | jq -e '.sealed == false' >/dev/null; then
    return 0
  fi

  if [[ -z "$OPENBAO_UNSEAL_KEY" ]]; then
    echo "OPENBAO_DEV_UNSEAL_KEY is required to unlock the persistent local OpenBao service." >&2
    return 1
  fi

  bao_unauthenticated operator unseal "$OPENBAO_UNSEAL_KEY" >/dev/null
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

path "kv/data/moneytree/dev/marketcheck" {
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
  local key value has_values=false

  for key in "$@"; do
    value="${!key-}"

    if [[ -n "$value" ]]; then
      args+=("$key=$value")
      has_values=true
    fi
  done

  if bao kv get "$path" >/dev/null 2>&1; then
    if [[ "$has_values" == "true" ]]; then
      bao kv patch "$path" "${args[@]}" >/dev/null
    fi

    return 0
  fi

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
  put_group marketcheck MARKETCHECK_API_KEY
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

verify_secret_value() {
  local path="$1"
  local key="$2"
  local expected="$3"
  local actual

  actual="$(bao kv get -field="$key" "$path" 2>/dev/null)" || return 1
  [[ "$actual" == "$expected" ]]
}

remove_migrated_env_secrets() {
  local tmp key value group path
  local -a mappings=(
    "DATABASE_URL:database"
    "DATABASE_USERNAME:database"
    "DATABASE_PASSWORD:database"
    "DATABASE_HOST:database"
    "DATABASE_NAME:database"
    "CLOAK_VAULT_KEY:cloak"
    "FRED_API_KEY:fred"
    "MARKETCHECK_API_KEY:marketcheck"
    "SECRET_KEY_BASE:phoenix"
    "PLAID_CLIENT_ID:plaid"
    "PLAID_SECRET:plaid"
    "PLAID_WEBHOOK_SECRET:plaid"
    "MAILER_SMTP_HOST:smtp"
    "MAILER_SMTP_USERNAME:smtp"
    "MAILER_SMTP_PASSWORD:smtp"
  )
  local -a migrated_keys=()

  for mapping in "${mappings[@]}"; do
    key="${mapping%%:*}"
    group="${mapping#*:}"
    value="${!key-}"

    [[ -z "$value" ]] && continue

    path="$OPENBAO_CLI_KV_PREFIX/$group"

    if ! verify_secret_value "$path" "$key" "$value"; then
      echo "Refusing to remove $key from $ENV_FILE because OpenBao verification failed." >&2
      return 1
    fi

    migrated_keys+=("$key")
  done

  if [[ "${#migrated_keys[@]}" -eq 0 ]]; then
    echo "No plaintext application secrets required removal from $ENV_FILE."
    return 0
  fi

  tmp="$(mktemp)"
  chmod 600 "$tmp"

  awk -v keys="$(IFS=,; printf '%s' "${migrated_keys[*]}")" '
    BEGIN {
      count = split(keys, items, ",")
      for (i = 1; i <= count; i++) {
        remove[items[i]] = 1
      }
    }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      sub(/^export[[:space:]]+/, "", line)
      key = line
      sub(/[[:space:]]*=.*/, "", key)

      if (!(key in remove)) {
        print $0
      }
    }
  ' "$ENV_FILE" > "$tmp"

  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "Removed ${#migrated_keys[@]} verified application secrets from $ENV_FILE."
}

main() {
  cd "$ROOT_DIR"

  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required to initialize the persistent local OpenBao service." >&2
    exit 1
  fi

  load_env_file "$ENV_FILE"
  apply_defaults

  docker compose up -d openbao >/dev/null
  wait_for_openbao
  initialize_openbao
  unseal_openbao
  enable_secret_mount
  enable_approle
  write_policy
  write_approle
  seed_secret_groups
  write_local_env_metadata

  if [[ "${MIGRATE_ENV_SECRETS:-false}" == "true" ]]; then
    "$ROOT_DIR/scripts/check_openbao_backend.sh"
    remove_migrated_env_secrets
  fi

  echo "Persistent local OpenBao is running on $OPENBAO_ADDR."
  echo "MoneyTree dev AppRole metadata was written to $ENV_FILE."
  echo "Secret groups were seeded under $OPENBAO_KV_PREFIX."
}

main "$@"
