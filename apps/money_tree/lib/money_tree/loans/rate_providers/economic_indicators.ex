defmodule MoneyTree.Loans.RateProviders.EconomicIndicators do
  @moduledoc """
  Placeholder adapter for future FMP/Alpha Vantage style economic indicators.

  This keeps future macro data sources behind the same provider contract while
  avoiding an inactive external dependency in v1.
  """

  @behaviour MoneyTree.Loans.RateProvider

  @impl true
  def provider_key, do: "economic-indicators"

  @impl true
  def name, do: "Economic indicator provider"

  @impl true
  def attribution do
    %{
      label: "Future economic indicator provider",
      url: nil
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
      update_frequency: "provider_defined",
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
