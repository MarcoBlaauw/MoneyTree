#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"

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

if ! command -v pnpm >/dev/null 2>&1; then
  cat <<'EOF' >&2
pnpm is not on PATH.
Install it with one of:
  corepack enable pnpm
  npm install -g pnpm
Then re-run this script.
EOF
  exit 1
fi

export MIX_ENV="${MIX_ENV:-dev}"
export NODE_ENV="${NODE_ENV:-development}"

load_env_file "$ENV_FILE"

cd "$ROOT_DIR"

echo "==> Installing Node workspace dependencies (pnpm install)"
pnpm install

echo "==> Building shared UI styles (@money-tree/ui)"
pnpm --filter @money-tree/ui run build

echo "==> Installing Elixir dependencies (mix deps.get)"
mix deps.get

if [[ "${MONEYTREE_SECRET_BACKEND:-env}" == "openbao" || "${SECRET_BACKEND_MODE:-}" == "openbao" ]]; then
  echo "==> Ensuring local OpenBao dev service is provisioned"
  "$ROOT_DIR/scripts/setup_openbao_dev.sh"
  load_env_file "$ENV_FILE"
fi

if ! mix ecto.migrate >/dev/null 2>&1; then
  echo "==> Database migrate failed; attempting full ecto.setup"
  mix ecto.setup
fi

echo "==> Starting Phoenix (mix phx.server)"
cd "$ROOT_DIR" && mix phx.server
