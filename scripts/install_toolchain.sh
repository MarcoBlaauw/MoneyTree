#!/usr/bin/env bash
set -euo pipefail

readonly ERLANG_VERSION="28.1.1"
readonly ELIXIR_VERSION="1.19.2"

if command -v mise >/dev/null 2>&1; then
  echo "Installing Erlang ${ERLANG_VERSION} and Elixir ${ELIXIR_VERSION} with mise..."
  mise install "erlang@${ERLANG_VERSION}" "elixir@${ELIXIR_VERSION}"
elif command -v asdf >/dev/null 2>&1; then
  echo "Installing Erlang ${ERLANG_VERSION} and Elixir ${ELIXIR_VERSION} with asdf..."
  asdf plugin add erlang >/dev/null 2>&1 || true
  asdf plugin add elixir >/dev/null 2>&1 || true
  asdf install erlang "${ERLANG_VERSION}"
  asdf install elixir "${ELIXIR_VERSION}"
else
  cat >&2 <<'ERR'
ERROR: Neither mise nor asdf is installed.
Please install one of these tool version managers and rerun this script.
ERR
  exit 1
fi

if ! command -v mix >/dev/null 2>&1; then
  echo "WARNING: mix is not on the PATH yet."
  echo "If you are using mise, activate it with: eval \"\$(mise activate bash)\"".
  echo "If you are using asdf, add it to your shell: . $HOME/.asdf/asdf.sh"
else
  mix --version
fi
