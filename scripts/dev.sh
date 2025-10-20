#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

echo "==> Starting Next.js (pnpm --filter next dev)"
(cd "$ROOT_DIR/apps/next" && pnpm run dev) &
NEXT_PID=$!

wait "$PHX_PID" "$NEXT_PID"
