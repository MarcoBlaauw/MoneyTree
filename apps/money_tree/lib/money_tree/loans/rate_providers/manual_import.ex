defmodule MoneyTree.Loans.RateProviders.ManualImport do
  @moduledoc """
  Supplemental market-rate source for manually curated benchmark imports.

  This provider does not fetch remote data. It exists so Bankrate/MND style
  survey values, local credit union promotions, or reviewed JSON/CSV rows can
  move through the same source metadata and observation persistence pipeline as
  external API providers.
  """

  @behaviour MoneyTree.Loans.RateProvider

  @impl true
  def provider_key, do: "manual-supplemental"

  @impl true
  def name, do: "Manual supplemental market rates"

  @impl true
  def attribution do
    %{
      label: "Manual supplemental market-rate import",
      url: nil
    }
  end

  @impl true
  def configured?(_settings), do: true

  @impl true
  def fetch_rates(_settings), do: {:error, :manual_import_only}

  @impl true
  def normalize_response(_series_key, %{"observations" => observations})
      when is_list(observations) do
    {:ok, observations}
  end

  def normalize_response(_series_key, _payload), do: {:error, :invalid_response}

  @impl true
  def default_source_attrs(_settings) do
    attribution = attribution()

    %{
      provider_key: provider_key(),
      name: name(),
      source_type: "csv_import",
      update_frequency: "on_demand",
      reliability_score: "0.7000",
      attribution_label: attribution.label,
      attribution_url: attribution.url,
      enabled: true,
      requires_api_key: false,
      config: %{"provider_module" => inspect(__MODULE__)}
    }
  end
end
