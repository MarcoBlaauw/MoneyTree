defmodule MoneyTree.Loans.RateProviders.ApiNinjas do
  @moduledoc """
  Placeholder adapter for future API Ninjas interest-rate support.

  The active v1 provider is FRED. This module documents the provider contract
  boundary without making API Ninjas an active dependency or requiring a key.
  """

  @behaviour MoneyTree.Loans.RateProvider

  @impl true
  def provider_key, do: "api-ninjas"

  @impl true
  def name, do: "API Ninjas interest rates"

  @impl true
  def attribution do
    %{
      label: "API Ninjas",
      url: "https://api-ninjas.com/api/interestrate"
    }
  end

  @impl true
  def configured?(settings) when is_map(settings) do
    present_string?(Map.get(settings, :api_key) || Map.get(settings, "api_key"))
  end

  @impl true
  def fetch_rates(_settings), do: {:error, :not_implemented}

  @impl true
  def normalize_response(_series_key, _payload), do: {:error, :not_implemented}

  @impl true
  def default_source_attrs(_settings) do
    attribution = attribution()

    %{
      provider_key: provider_key(),
      name: name(),
      source_type: "aggregator_api",
      update_frequency: "daily_or_weekly",
      reliability_score: "0.6000",
      attribution_label: attribution.label,
      attribution_url: attribution.url,
      enabled: false,
      requires_api_key: true,
      config: %{"provider_module" => inspect(__MODULE__), "status" => "placeholder"}
    }
  end

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
