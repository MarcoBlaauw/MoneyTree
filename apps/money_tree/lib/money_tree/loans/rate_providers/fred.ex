defmodule MoneyTree.Loans.RateProviders.Fred do
  @moduledoc """
  FRED market-rate provider for mortgage and benchmark rate observations.
  """

  @behaviour MoneyTree.Loans.RateProvider

  alias Decimal, as: D

  @default_base_url "https://api.stlouisfed.org/fred"
  @default_timeout_ms 15_000

  @series [
    %{
      series_key: "MORTGAGE30US",
      loan_type: "mortgage",
      product_type: "fixed",
      term_months: 360,
      rate_type: "average",
      notes: "30-year fixed-rate mortgage national average"
    },
    %{
      series_key: "MORTGAGE15US",
      loan_type: "mortgage",
      product_type: "fixed",
      term_months: 180,
      rate_type: "average",
      notes: "15-year fixed-rate mortgage national average"
    },
    %{
      series_key: "DPRIME",
      loan_type: "prime",
      product_type: "bank_prime",
      term_months: 1,
      rate_type: "benchmark",
      notes: "Bank prime loan rate"
    },
    %{
      series_key: "FEDFUNDS",
      loan_type: "fed_funds",
      product_type: "effective_federal_funds",
      term_months: 1,
      rate_type: "benchmark",
      notes: "Effective federal funds rate"
    },
    %{
      series_key: "SOFR",
      loan_type: "sofr",
      product_type: "secured_overnight_financing",
      term_months: 1,
      rate_type: "benchmark",
      notes: "Secured overnight financing rate"
    },
    %{
      series_key: "GS10",
      loan_type: "treasury",
      product_type: "10_year_treasury",
      term_months: 120,
      rate_type: "benchmark",
      notes: "10-year Treasury constant maturity"
    },
    %{
      series_key: "GS2",
      loan_type: "treasury",
      product_type: "2_year_treasury",
      term_months: 24,
      rate_type: "benchmark",
      notes: "2-year Treasury constant maturity"
    }
  ]

  @impl true
  def provider_key, do: "fred"

  @impl true
  def name, do: "FRED market benchmarks"

  @impl true
  def attribution do
    %{
      label: "Federal Reserve Economic Data (FRED), Federal Reserve Bank of St. Louis",
      url: "https://fred.stlouisfed.org/"
    }
  end

  @impl true
  def configured?(settings) when is_map(settings) do
    api_key(settings) not in [nil, ""]
  end

  @impl true
  def default_source_attrs(settings) do
    attribution = attribution()

    %{
      provider_key: provider_key(),
      name: name(),
      source_type: "public_benchmark",
      base_url: base_url(settings),
      update_frequency: "daily",
      reliability_score: "0.9500",
      attribution_label: attribution.label,
      attribution_url: attribution.url,
      enabled: true,
      requires_api_key: true,
      config: %{"provider_module" => inspect(__MODULE__)}
    }
  end

  @impl true
  def fetch_rates(settings) when is_map(settings) do
    if configured?(settings) do
      @series
      |> Enum.reduce_while({:ok, []}, fn series, {:ok, rates} ->
        case fetch_series(settings, series) do
          {:ok, series_rates} -> {:cont, {:ok, rates ++ series_rates}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:error, :missing_api_key}
    end
  end

  @impl true
  def normalize_response(series_key, %{"observations" => observations})
      when is_list(observations) do
    case Enum.find(@series, &(&1.series_key == series_key)) do
      nil ->
        {:error, :unknown_series}

      series ->
        rates =
          observations
          |> Enum.flat_map(&normalize_observation(series, &1))

        {:ok, rates}
    end
  end

  def normalize_response(_series_key, _payload), do: {:error, :invalid_response}

  def series, do: @series

  defp fetch_series(settings, series) do
    request =
      Req.new(
        base_url: base_url(settings),
        receive_timeout: timeout_ms(settings),
        params: [
          series_id: series.series_key,
          api_key: api_key(settings),
          file_type: "json",
          sort_order: "desc",
          limit: fetch_limit(settings)
        ]
      )

    case Req.get(request, url: "/series/observations") do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        normalize_response(series.series_key, normalize_body(body))

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

  defp normalize_observation(series, %{"date" => date, "value" => value} = payload) do
    with {:ok, effective_date} <- Date.from_iso8601(date),
         {:ok, rate} <- decimal_rate(value) do
      observed_at = DateTime.new!(effective_date, ~T[00:00:00], "Etc/UTC")

      [
        %{
          provider_key: provider_key(),
          series_key: series.series_key,
          loan_type: series.loan_type,
          product_type: series.product_type,
          term_months: series.term_months,
          rate: rate,
          effective_date: effective_date,
          observed_at: observed_at,
          raw_payload: payload,
          source_url: "https://fred.stlouisfed.org/series/#{series.series_key}",
          geography: "US",
          confidence_score: "0.9500",
          notes: series.notes,
          assumptions: %{
            "rate_type" => series.rate_type,
            "source" => "FRED",
            "not_personalized_offer" => true
          }
        }
      ]
    else
      _error -> []
    end
  end

  defp normalize_observation(_series, _payload), do: []

  defp decimal_rate(value) when is_binary(value) do
    value = String.trim(value)

    if value in ["", "."] do
      {:error, :missing_value}
    else
      value
      |> D.new()
      |> D.div(D.new("100"))
      |> then(&{:ok, &1})
    end
  rescue
    D.Error -> {:error, :invalid_decimal}
  end

  defp decimal_rate(_value), do: {:error, :invalid_decimal}

  defp normalize_body(%{} = body), do: body

  defp normalize_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> decoded
      _error -> %{}
    end
  end

  defp normalize_body(_body), do: %{}

  defp api_key(settings),
    do: present_string(Map.get(settings, :api_key) || Map.get(settings, "api_key"))

  defp base_url(settings),
    do:
      present_string(Map.get(settings, :base_url) || Map.get(settings, "base_url")) ||
        @default_base_url

  defp timeout_ms(settings) do
    Map.get(settings, :timeout_ms) || Map.get(settings, "timeout_ms") || @default_timeout_ms
  end

  defp fetch_limit(settings), do: Map.get(settings, :limit) || Map.get(settings, "limit") || 370

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp present_string(value), do: value
end
