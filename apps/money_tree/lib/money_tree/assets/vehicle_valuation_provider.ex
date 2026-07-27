defmodule MoneyTree.Assets.VehicleValuationProvider do
  @moduledoc """
  Contract for vehicle valuation adapters.

  Adapters fetch and normalize provider data. `MoneyTree.Assets` owns quota
  enforcement, persistence, tenant authorization, and cached-value updates.
  """

  @type settings :: map()
  @type vehicle_attrs :: map()
  @type normalized_valuation :: %{
          required(:value) => Decimal.t(),
          optional(:value_low) => Decimal.t() | nil,
          optional(:value_high) => Decimal.t() | nil,
          optional(:confidence) => String.t() | nil,
          required(:raw) => map()
        }

  @type fetch_error ::
          :missing_api_key
          | :invalid_vehicle
          | :rate_limited
          | :invalid_response
          | :timeout
          | {:http_error, pos_integer()}
          | {:transport_error, term()}
          | term()

  @callback provider_key() :: String.t()
  @callback name() :: String.t()
  @callback configured?(settings()) :: boolean()
  @callback decode_vin(String.t(), settings()) ::
              {:ok,
               %{
                 required(:year) => integer(),
                 required(:make) => String.t(),
                 required(:model) => String.t(),
                 optional(:trim) => String.t() | nil,
                 optional(:body_style) => String.t() | nil
               }}
              | {:error, fetch_error()}
  @callback fetch_valuation(vehicle_attrs(), settings()) ::
              {:ok, normalized_valuation()} | {:error, fetch_error()}
end
