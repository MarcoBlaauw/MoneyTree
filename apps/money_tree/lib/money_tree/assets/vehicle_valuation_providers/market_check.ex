defmodule MoneyTree.Assets.VehicleValuationProviders.MarketCheck do
  @moduledoc """
  MarketCheck Price base-tier adapter.

  Vehicle onboarding uses the basic VIN-specification endpoint followed by one
  base-price request. Scheduled refreshes call only the base-price endpoint.
  Comparables endpoints are intentionally excluded to conserve quota.
  """

  @behaviour MoneyTree.Assets.VehicleValuationProvider

  alias Decimal, as: D

  @default_base_url "https://api.marketcheck.com"
  @default_timeout_ms 15_000
  @price_path "/v2/predict/car/us/marketcheck_price"
  @vin_pattern ~r/^[A-HJ-NPR-Z0-9]{17}$/

  @impl true
  def provider_key, do: "marketcheck"

  @impl true
  def name, do: "MarketCheck Price"

  @impl true
  def configured?(settings) when is_map(settings),
    do: present_string(value(settings, :api_key)) not in [nil, ""]

  @impl true
  def decode_vin(vin, settings) when is_binary(vin) and is_map(settings) do
    vin = vin |> String.trim() |> String.upcase()

    with true <- configured?(settings) || {:error, :missing_api_key},
         true <- Regex.match?(@vin_pattern, vin) || {:error, :invalid_vehicle} do
      request(settings, "/v2/decode/car/#{vin}/specs", [], &normalize_decode_response/1)
    end
  end

  @impl true
  def fetch_valuation(vehicle, settings) when is_map(vehicle) and is_map(settings) do
    with true <- configured?(settings) || {:error, :missing_api_key},
         {:ok, params} <- request_params(vehicle, settings) do
      request(settings, @price_path, params, &normalize_response/1)
    end
  end

  @spec normalize_decode_response(map()) ::
          {:ok, map()} | {:error, :invalid_response | :invalid_vehicle}
  def normalize_decode_response(
        %{
          "is_valid" => true,
          "year" => year,
          "make" => make,
          "model" => model
        } = payload
      )
      when is_integer(year) and is_binary(make) and is_binary(model) do
    {:ok,
     %{
       year: year,
       make: make,
       model: model,
       trim: present_string(payload["trim"]),
       body_style: present_string(payload["body_type"])
     }}
  end

  def normalize_decode_response(%{"is_valid" => false}), do: {:error, :invalid_vehicle}
  def normalize_decode_response(_payload), do: {:error, :invalid_response}

  @spec normalize_response(map()) ::
          {:ok, MoneyTree.Assets.VehicleValuationProvider.normalized_valuation()}
          | {:error, :invalid_response}
  def normalize_response(%{"marketcheck_price" => price} = payload) do
    case decimal(price) do
      {:ok, value} ->
        {:ok,
         %{
           value: value,
           value_low: nil,
           value_high: nil,
           confidence: nil,
           raw: payload
         }}

      :error ->
        {:error, :invalid_response}
    end
  end

  def normalize_response(_payload), do: {:error, :invalid_response}

  defp request(settings, path, params, normalizer) do
    request =
      Req.new(
        base_url: value(settings, :base_url) || @default_base_url,
        receive_timeout: value(settings, :timeout_ms) || @default_timeout_ms,
        retry: false,
        headers: [{"accept", "application/json"}],
        params: Keyword.put(params, :api_key, value(settings, :api_key))
      )
      |> maybe_put_plug(settings)

    case Req.get(request, url: path) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        normalizer.(normalize_body(body))

      {:ok, %Req.Response{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, %Req.TransportError{} = error} ->
        {:error, {:transport_error, error.reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_params(vehicle, settings) do
    vin = present_string(value(vehicle, :vin))
    miles = non_negative_integer(value(vehicle, :mileage))
    zip = present_string(value(vehicle, :market_region))
    dealer_type = present_string(value(settings, :dealer_type)) || "independent"

    if vin && miles && zip && dealer_type in ["franchise", "independent"] do
      {:ok,
       [
         vin: vin,
         miles: miles,
         zip: zip,
         dealer_type: dealer_type,
         is_certified: false
       ]}
    else
      {:error, :invalid_vehicle}
    end
  end

  defp maybe_put_plug(request, settings) do
    case value(settings, :plug) do
      nil -> request
      plug -> Req.merge(request, plug: plug)
    end
  end

  defp normalize_body(%{} = body), do: body

  defp normalize_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> decoded
      _error -> %{}
    end
  end

  defp normalize_body(_body), do: %{}

  defp decimal(%D{} = value), do: {:ok, value}

  defp decimal(value) when is_number(value) or is_binary(value) do
    case D.cast(value) do
      {:ok, decimal} ->
        if D.compare(decimal, D.new("0")) == :lt, do: :error, else: {:ok, decimal}

      _other ->
        :error
    end
  end

  defp decimal(_value), do: :error

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> nil
    end
  end

  defp non_negative_integer(_value), do: nil

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_string(value), do: value
end
