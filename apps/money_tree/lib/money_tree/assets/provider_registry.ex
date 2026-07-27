defmodule MoneyTree.Assets.ProviderRegistry do
  @moduledoc """
  Runtime registry and cost controls for external asset-valuation providers.
  """

  alias MoneyTree.Assets.VehicleValuationProviders.MarketCheck

  @hard_monthly_limit 500
  @default_monthly_limit 450
  @default_refresh_interval_days 7
  @providers %{"marketcheck" => MarketCheck}

  @spec enabled?(atom() | binary()) :: boolean()
  def enabled?(provider) do
    provider = normalize_provider(provider)
    provider in enabled_provider_ids()
  end

  @spec configured?(atom() | binary()) :: boolean()
  def configured?(provider) do
    provider = normalize_provider(provider)

    with true <- enabled?(provider),
         module when not is_nil(module) <- provider_module(provider) do
      module.configured?(settings(provider))
    else
      _other -> false
    end
  end

  @spec provider_module(atom() | binary()) :: module() | nil
  def provider_module(provider), do: Map.get(@providers, normalize_provider(provider))

  @spec settings(atom() | binary()) :: map()
  def settings("marketcheck") do
    :money_tree
    |> Application.get_env(MarketCheck, [])
    |> Map.new()
  end

  def settings(provider) when is_atom(provider), do: settings(normalize_provider(provider))
  def settings(_provider), do: %{}

  @spec monthly_request_limit() :: pos_integer()
  def monthly_request_limit do
    configured =
      :money_tree
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:monthly_request_limit, @default_monthly_limit)

    configured
    |> normalize_positive_integer(@default_monthly_limit)
    |> min(@hard_monthly_limit)
  end

  @spec refresh_interval_days() :: pos_integer()
  def refresh_interval_days do
    :money_tree
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:refresh_interval_days, @default_refresh_interval_days)
    |> normalize_positive_integer(@default_refresh_interval_days)
  end

  @spec hard_monthly_limit() :: 500
  def hard_monthly_limit, do: @hard_monthly_limit

  defp enabled_provider_ids do
    :money_tree
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enabled_providers, [])
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

  defp normalize_provider_list(_value), do: []

  defp normalize_provider(provider) when is_atom(provider),
    do: provider |> Atom.to_string() |> normalize_provider()

  defp normalize_provider(provider) when is_binary(provider),
    do: provider |> String.trim() |> String.downcase()

  defp normalize_provider(_provider), do: ""

  defp normalize_positive_integer(value, _fallback) when is_integer(value) and value > 0,
    do: value

  defp normalize_positive_integer(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> fallback
    end
  end

  defp normalize_positive_integer(_value, fallback), do: fallback
end
