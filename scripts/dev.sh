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
export NEXT_BASE_PATH="${NEXT_BASE_PATH:-/app/react}"

load_env_file "$ENV_FILE"

NEXT_DEV_PORT="${NEXT_DEV_PORT:-3100}"
NEXT_DEV_HOST="${NEXT_DEV_HOST:-127.0.0.1}"
export NEXT_PROXY_URL="${NEXT_PROXY_URL:-http://${NEXT_DEV_HOST}:${NEXT_DEV_PORT}}"

cd "$ROOT_DIR"

echo "==> Installing Node workspace dependencies (pnpm install)"
pnpm install

echo "==> Building shared UI styles (@money-tree/ui)"
pnpm --filter @money-tree/ui run build

echo "==> Installing Elixir dependencies (mix deps.get)"
mix deps.get

if ! mix ecto.migrate >/dev/null 2>&1; then
  echo "==> Database migrate failed; attempting full ecto.setup"
  mix ecto.setup
fi

trap 'kill 0' EXIT

echo "==> Starting Phoenix (mix phx.server)"
(cd "$ROOT_DIR" && mix phx.server) &
PHX_PID=$!

echo "==> Starting Next.js (pnpm exec next dev --port ${NEXT_DEV_PORT} --hostname ${NEXT_DEV_HOST})"
(
  cd "$ROOT_DIR/apps/next" &&
    PORT="$NEXT_DEV_PORT" pnpm exec next dev --port "$NEXT_DEV_PORT" --hostname "$NEXT_DEV_HOST"
) &
NEXT_PID=$!

wait "$PHX_PID" "$NEXT_PID"
