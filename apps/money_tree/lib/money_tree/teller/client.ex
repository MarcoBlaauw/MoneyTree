defmodule MoneyTree.Teller.Client do
  @moduledoc """
  Lightweight wrapper around the Teller HTTP API.

  The client centralises request construction, consistent error handling, and
  instrumentation so the rest of the application can depend on a small,
  uniform surface area. Functions return `{:ok, result}` or `{:error, reason}`
  tuples, and automatically emit telemetry spans using the configured Req
  middleware.
  """

  @type request_option ::
          {:base_url, String.t()}
          | {:connect_base_url, String.t()}
          | {:adapter, module() | {module(), keyword()}}
          | {:finch, module()}
          | {:timeout, non_neg_integer()}
          | {:telemetry_metadata, map()}
          | {:headers, [{binary(), binary()}]}
          | {:retry, keyword() | map() | false | :none | nil}

  @type retry_option ::
          {:max_attempts, pos_integer()}
          | {:base_delay, non_neg_integer()}
          | {:max_delay, non_neg_integer()}
          | {:retry_for, [integer()]}
          | {:retry_transport_errors, boolean()}

  @type t :: %__MODULE__{
          api_request: Req.Request.t(),
          connect_request: Req.Request.t(),
          retry: keyword(),
          telemetry_metadata: map()
        }

  @enforce_keys [:api_request, :connect_request, :retry, :telemetry_metadata]
  defstruct [:api_request, :connect_request, :retry, :telemetry_metadata]

  @default_headers [
    {"accept", "application/json"},
    {"content-type", "application/json"}
  ]

  @default_retry [
    max_attempts: 3,
    base_delay: 250,
    max_delay: 2_000,
    retry_for: [408, 425, 429, 500, 502, 503, 504],
    retry_transport_errors: true
  ]

  @telemetry_event [:money_tree, :teller, :request]
  @telemetry_span_event [:money_tree, :teller, :request, :span]

  @doc """
  Builds a new Teller client using application configuration.

  Options allow overriding base URLs, headers, adapter, retry policy, and
  telemetry metadata (useful for tests).
  """
  @spec new([request_option()]) :: t()
  def new(opts \\ []) do
    config = Application.fetch_env!(:money_tree, MoneyTree.Teller)

    api_key = Keyword.fetch!(config, :api_key)
    api_host = Keyword.get(opts, :base_url, Keyword.fetch!(config, :api_host))
    connect_host =
      Keyword.get(opts, :connect_base_url, Keyword.get(config, :connect_host, api_host))

    timeout = Keyword.get(opts, :timeout, Keyword.get(config, :timeout, :timer.seconds(10)))
    finch = Keyword.get(opts, :finch, Keyword.get(config, :finch))
    adapter = Keyword.get(opts, :adapter)
    retry = opts |> Keyword.get(:retry, @default_retry) |> normalize_retry()

    telemetry_metadata =
      config
      |> Keyword.get(:telemetry_metadata, %{})
      |> Map.new()
      |> Map.merge(Map.new(Keyword.get(opts, :telemetry_metadata, %{})))

    base_headers =
      @default_headers ++
        [
          {"authorization", "Basic " <> Base.encode64("#{api_key}:")}
        ] ++ Keyword.get(opts, :headers, [])

    common_opts =
      [
        finch: finch,
        receive_timeout: timeout,
        connect_options: [timeout: timeout],
        headers: base_headers,
        telemetry_event: @telemetry_event,
        telemetry_span_event: @telemetry_span_event,
        telemetry_metadata: telemetry_metadata
      ]
      |> maybe_put_adapter(adapter)

    %__MODULE__{
      api_request: Req.new(Keyword.put(common_opts, :base_url, api_host)),
      connect_request: Req.new(Keyword.put(common_opts, :base_url, connect_host)),
      retry: retry,
      telemetry_metadata: telemetry_metadata
    }
  end

  @doc """
  Creates a connect token by posting to the Teller Connect API.
  """
  @spec create_connect_token(map()) :: {:ok, map()} | {:error, map()}
  def create_connect_token(params) when is_map(params) do
    new() |> create_connect_token(params)
  end

  @doc false
  @spec create_connect_token(t(), map()) :: {:ok, map()} | {:error, map()}
  def create_connect_token(%__MODULE__{} = client, params) when is_map(params) do
    payload =
      params
      |> stringify_keys()
      |> maybe_put_application_id(connect_application_id())

    request(client, client.connect_request, :post, "/connect_tokens", json: payload)
    |> normalize_response()
  end

  @doc """
  Exchanges a Teller public token for permanent access credentials.
  """
  @spec exchange_public_token(binary()) :: {:ok, map()} | {:error, map()}
  def exchange_public_token(public_token) when is_binary(public_token) do
    new() |> exchange_public_token(public_token)
  end

  @doc false
  @spec exchange_public_token(t(), binary()) :: {:ok, map()} | {:error, map()}
  def exchange_public_token(%__MODULE__{} = client, public_token) when is_binary(public_token) do
    payload = %{"public_token" => public_token}

    request(client, client.api_request, :post, "/oauth/token", json: payload)
    |> normalize_response()
  end

  @doc """
  Lists Teller accounts associated with the provided Teller user id.
  """
  @spec list_accounts(map()) :: {:ok, list()} | {:error, map()}
  def list_accounts(params) when is_map(params) do
    new() |> list_accounts(params)
  end

  @doc false
  @spec list_accounts(t(), map()) :: {:ok, list()} | {:error, map()}
  def list_accounts(%__MODULE__{} = client, params) when is_map(params) do
    query =
      params
      |> stringify_keys()
      |> Map.take(["teller_user_id", "enrollment_id", "cursor"])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.into(%{})

    request(client, client.api_request, :get, "/accounts", params: query)
    |> normalize_response()
  end

  @doc """
  Lists transactions for the given account id. Optional parameters (e.g. date
  ranges) can be supplied in the params map.
  """
  @spec list_transactions(binary(), map()) :: {:ok, list()} | {:error, map()}
  def list_transactions(account_id, params \\ %{}) when is_binary(account_id) and is_map(params) do
    new() |> list_transactions(account_id, params)
  end

  @doc false
  @spec list_transactions(t(), binary(), map()) :: {:ok, list()} | {:error, map()}
  def list_transactions(%__MODULE__{} = client, account_id, params)
      when is_binary(account_id) and is_map(params) do
    query =
      params
      |> stringify_keys()
      |> Map.take(["cursor", "from", "to", "count"])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.into(%{})

    request(client, client.api_request, :get, "/accounts/#{account_id}/transactions", params: query)
    |> normalize_response()
  end

  @doc """
  Fetches account details by identifier.
  """
  @spec get_account(binary()) :: {:ok, map()} | {:error, map()}
  def get_account(account_id) when is_binary(account_id) do
    new() |> get_account(account_id)
  end

  @doc false
  @spec get_account(t(), binary()) :: {:ok, map()} | {:error, map()}
  def get_account(%__MODULE__{} = client, account_id) when is_binary(account_id) do
    request(client, client.api_request, :get, "/accounts/#{account_id}")
    |> normalize_response()
  end

  defp request(client, request, method, path, opts \\ []) do
    metadata =
      client.telemetry_metadata
      |> Map.merge(Map.new(Keyword.get(opts, :telemetry_metadata, %{})))

    merged_opts =
      opts
      |> Keyword.put(:method, method)
      |> Keyword.put(:url, path)
      |> Keyword.put(:telemetry_metadata, metadata)

    request
    |> Req.Request.put_private(:money_tree_metadata, metadata)
    |> perform_with_retry(merged_opts, client.retry)
  end

  defp perform_with_retry(request, opts, retry_opts, attempt \\ 1)
  defp perform_with_retry(request, opts, retry_opts, _attempt) when retry_opts in [nil, []] do
    Req.request(request, opts)
  end

  defp perform_with_retry(request, opts, retry_opts, attempt) do
    case Req.request(request, opts) do
      {:ok, %Req.Response{} = response} = result ->
        if retry?(response.status, retry_opts) and attempt < Keyword.get(retry_opts, :max_attempts, 1) do
          backoff(attempt, retry_opts)
          perform_with_retry(request, opts, retry_opts, attempt + 1)
        else
          result
        end

      {:error, %Req.TransportError{} = error} = transport_error ->
        if Keyword.get(retry_opts, :retry_transport_errors, false) and
             attempt < Keyword.get(retry_opts, :max_attempts, 1) do
          backoff(attempt, retry_opts)
          perform_with_retry(request, opts, retry_opts, attempt + 1)
        else
          transport_error
        end

      other ->
        other
    end
  end

  defp retry?(status, retry_opts) do
    retry_for = Keyword.get(retry_opts, :retry_for, [])
    Enum.member?(retry_for, status)
  end

  defp backoff(attempt, retry_opts) do
    base_delay = Keyword.get(retry_opts, :base_delay, 200)
    max_delay = Keyword.get(retry_opts, :max_delay, 2_000)

    delay =
      base_delay
      |> Kernel.*(:math.pow(2, attempt - 1))
      |> trunc()
      |> min(max_delay)

    Process.sleep(delay)
  end

  defp normalize_response({:ok, %Req.Response{status: status, body: body}}) when status in 200..299 do
    {:ok, body}
  end

  defp normalize_response({:ok, %Req.Response{status: status, body: body, headers: headers}}) do
    {:error, translate_error(status, body, headers)}
  end

  defp normalize_response({:error, %Req.TransportError{} = error}) do
    {:error,
     %{
       type: :transport,
       reason: error.reason
     }}
  end

  defp normalize_response({:error, other}) do
    {:error,
     %{
       type: :unexpected,
       reason: inspect(other)
     }}
  end

  defp translate_error(status, body, headers) do
    error_details =
      cond do
        is_map(body) ->
          %{
            code: Map.get(body, "code") || Map.get(body, :code),
            message: Map.get(body, "message") || Map.get(body, :message),
            error: Map.get(body, "error") || Map.get(body, :error)
          }

        is_binary(body) and String.trim(body) != "" ->
          %{message: String.trim(body)}

        true ->
          %{}
      end

    %{
      type: :http,
      status: status,
      headers: headers,
      details: error_details |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
    }
  end

  defp stringify_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_atom(key) -> Map.put(acc, Atom.to_string(key), value)
      {key, value}, acc when is_binary(key) -> Map.put(acc, key, value)
      {key, value}, acc -> Map.put(acc, to_string(key), value)
    end)
  end

  defp stringify_keys(_other), do: %{}

  defp normalize_retry(false), do: nil
  defp normalize_retry(:none), do: nil
  defp normalize_retry(nil), do: nil
  defp normalize_retry(retry) when is_map(retry), do: Map.to_list(retry)
  defp normalize_retry(retry) when is_list(retry), do: retry
  defp normalize_retry(_other), do: @default_retry

  defp maybe_put_application_id(params, nil), do: params
  defp maybe_put_application_id(params, application_id), do: Map.put_new(params, "application_id", application_id)

  defp connect_application_id do
    Application.get_env(:money_tree, MoneyTree.Teller, [])
    |> Keyword.get(:connect_application_id)
  end

  defp maybe_put_adapter(opts, nil), do: opts

  defp maybe_put_adapter(opts, adapter), do: Keyword.put(opts, :adapter, adapter)
end
