defmodule MoneyTree.BankSync.ProviderRegistry do
  @moduledoc """
  Runtime registry for bank-sync providers available for new connections.
  """

  @default_enabled ~w(simplefin manual)
  @default_primary "simplefin"

  @providers %{
    "manual" => %{
      id: "manual",
      label: "Manual import",
      mode: "manual_import",
      supports_manual_refresh: false,
      supports_webhooks: false,
      supports_pending_transactions: false
    },
    "simplefin" => %{
      id: "simplefin",
      label: "SimpleFIN Bridge",
      mode: "setup_token",
      supports_manual_refresh: true,
      supports_webhooks: false,
      supports_pending_transactions: :optional,
      default_sync_interval_hours: 24
    },
    "teller" => %{
      id: "teller",
      label: "Teller",
      mode: "widget",
      supports_manual_refresh: true,
      supports_webhooks: true,
      supports_pending_transactions: true
    },
    "plaid" => %{
      id: "plaid",
      label: "Plaid",
      mode: "widget",
      supports_manual_refresh: true,
      supports_webhooks: true,
      supports_pending_transactions: true
    }
  }

  @spec enabled?(atom() | binary()) :: boolean()
  def enabled?(provider) do
    provider
    |> normalize_provider()
    |> then(&(&1 in enabled_provider_ids()))
  end

  @spec primary_provider() :: binary()
  def primary_provider do
    configured =
      :money_tree
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:primary_provider, @default_primary)
      |> normalize_provider()

    cond do
      configured in enabled_provider_ids() -> configured
      "simplefin" in enabled_provider_ids() -> "simplefin"
      true -> List.first(enabled_provider_ids()) || @default_primary
    end
  end

  @spec list_enabled() :: [map()]
  def list_enabled do
    enabled_provider_ids()
    |> Enum.map(&Map.fetch!(@providers, &1))
  end

  @spec provider(binary() | atom()) :: map() | nil
  def provider(provider), do: Map.get(@providers, normalize_provider(provider))

  @spec all_provider_ids() :: [binary()]
  def all_provider_ids, do: Map.keys(@providers)

  defp enabled_provider_ids do
    configured =
      :money_tree
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:enabled_providers, @default_enabled)

    configured
    |> normalize_provider_list()
    |> Enum.filter(&Map.has_key?(@providers, &1))
  end

  defp normalize_provider_list(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&normalize_provider/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_provider_list(value) when is_list(value) do
    value
    |> Enum.map(&normalize_provider/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_provider_list(_value), do: @default_enabled

  defp normalize_provider(provider) when is_atom(provider) do
    provider
    |> Atom.to_string()
    |> normalize_provider()
  end

  defp normalize_provider(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_provider(_provider), do: ""
end
