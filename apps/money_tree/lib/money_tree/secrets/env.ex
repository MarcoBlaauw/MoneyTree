defmodule MoneyTree.Secrets.Env do
  @moduledoc """
  Environment-backed runtime secret provider.

  This is the default provider and preserves the current MoneyTree runtime
  behavior while giving later OpenBao work a stable interface to replace.
  """

  @behaviour MoneyTree.Secrets.Provider

  @groups %{
    database: ~w(DATABASE_URL DATABASE_USERNAME DATABASE_PASSWORD DATABASE_HOST DATABASE_NAME),
    cloak: ~w(CLOAK_VAULT_KEY),
    fred: ~w(FRED_API_KEY),
    marketcheck: ~w(MARKETCHECK_API_KEY),
    phoenix: ~w(SECRET_KEY_BASE),
    plaid: ~w(PLAID_CLIENT_ID PLAID_SECRET PLAID_WEBHOOK_SECRET),
    smtp: ~w(MAILER_SMTP_HOST MAILER_SMTP_USERNAME MAILER_SMTP_PASSWORD)
  }

  @impl true
  def get(key) when is_binary(key) do
    case System.get_env(key) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  @impl true
  def get_group(group) when is_atom(group) do
    group
    |> keys_for_group()
    |> Map.new(fn key -> {key, get(key)} end)
  end

  def groups, do: Map.keys(@groups)

  def keys_for_group(group) when is_atom(group), do: Map.get(@groups, group, [])
end
