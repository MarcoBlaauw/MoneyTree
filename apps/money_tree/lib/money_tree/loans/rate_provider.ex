defmodule MoneyTree.Loans.RateProvider do
  @moduledoc """
  Behaviour for external market-rate provider adapters.

  Providers fetch and normalize data only. The Loans context owns persistence
  so all imports share deduplication, source metadata, and audit behavior.
  """

  alias MoneyTree.Loans.RateSource

  @type settings :: map()
  @type normalized_rate :: map()
  @type fetch_result ::
          {:ok, [normalized_rate()]}
          | {:error,
             :missing_api_key
             | :rate_limited
             | :invalid_response
             | :timeout
             | {:http_error, pos_integer()}
             | {:transport_error, term()}
             | term()}

  @callback provider_key() :: String.t()
  @callback name() :: String.t()
  @callback attribution() :: map()
  @callback configured?(settings()) :: boolean()
  @callback fetch_rates(settings()) :: fetch_result()
  @callback normalize_response(String.t(), map()) :: {:ok, [normalized_rate()]} | {:error, term()}
  @callback default_source_attrs(settings()) :: map()

  @optional_callbacks default_source_attrs: 1

  @spec source_attrs(module(), settings()) :: map()
  def source_attrs(provider, settings) do
    if function_exported?(provider, :default_source_attrs, 1) do
      provider.default_source_attrs(settings)
    else
      attribution = provider.attribution()

      %{
        provider_key: provider.provider_key(),
        name: provider.name(),
        source_type: "public_benchmark",
        enabled: true,
        requires_api_key: true,
        attribution_label: Map.get(attribution, :label),
        attribution_url: Map.get(attribution, :url)
      }
    end
  end

  @spec settings_from_source(RateSource.t(), keyword()) :: map()
  def settings_from_source(%RateSource{} = source, app_config) do
    source_config =
      source.config
      |> case do
        config when is_map(config) -> config
        _value -> %{}
      end

    app_config
    |> Map.new()
    |> Map.merge(source_config)
    |> Map.put_new(:base_url, source.base_url)
    |> reject_nil_values()
  end

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
