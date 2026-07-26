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

main() {
  cd "$ROOT_DIR"

  load_env_file "$ENV_FILE"

  if [[ "${MONEYTREE_SECRET_BACKEND:-}" != "openbao" && "${SECRET_BACKEND_MODE:-}" != "openbao" ]]; then
    echo "MONEYTREE_SECRET_BACKEND is not openbao; refusing to run OpenBao preflight." >&2
    exit 1
  fi

  # Keep this as a secret-backend preflight. Do not bind the Phoenix endpoint
  # just because PHX_SERVER=true is present in the loaded environment file.
  if [[ "${START_APP_FOR_SECRET_CHECK:-false}" != "true" ]]; then
    unset PHX_SERVER
  fi

  mix run -e '
summary = MoneyTree.Secrets.Health.summary(live?: true)

unless summary.backend == "openbao" and summary.status == "configured" do
  raise "OpenBao backend is not configured"
end

failing_groups =
  summary.groups
  |> Enum.filter(fn {_group, status} -> status.status in ["error", "missing", "not_configured"] end)
  |> Enum.map(fn {group, status} -> "#{group}:#{status.status}" end)

if failing_groups != [] do
  raise "OpenBao groups failed preflight: #{Enum.join(failing_groups, ", ")}"
end

IO.puts("OpenBao backend preflight passed.")
'
}

main "$@"
