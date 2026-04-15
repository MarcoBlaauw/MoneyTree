defmodule MoneyTree.Plaid.Client do
  @moduledoc """
  Lightweight wrapper around the Plaid HTTP API.
  """

  @type request_option ::
          {:base_url, String.t()}
          | {:client_id, String.t()}
          | {:secret, String.t()}
          | {:adapter, module() | {module(), keyword()} | function()}
          | {:finch, module()}
          | {:timeout, non_neg_integer()}
          | {:telemetry_metadata, map()}
          | {:headers, [{binary(), binary()}]}
          | {:retry, keyword() | map() | false | :none | nil}

  @type t :: %__MODULE__{
          request: Req.Request.t(),
          retry: keyword(),
          telemetry_metadata: map(),
          client_id: String.t() | nil,
          secret: String.t() | nil
        }

  @enforce_keys [:request, :retry, :telemetry_metadata]
  defstruct [:request, :retry, :telemetry_metadata, :client_id, :secret]

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

  @spec new([request_option()]) :: t()
  def new(opts \\ []) do
    config = Application.get_env(:money_tree, MoneyTree.Plaid, [])

    api_host =
      Keyword.get(opts, :base_url, Keyword.get(config, :api_host, default_api_host(config)))

    timeout = Keyword.get(opts, :timeout, Keyword.get(config, :timeout, :timer.seconds(10)))
    finch = Keyword.get(opts, :finch, Keyword.get(config, :finch))
    adapter = Keyword.get(opts, :adapter)

    client_id =
      Keyword.get(opts, :client_id, Keyword.get(config, :client_id))
      |> maybe_trim()

    secret =
      Keyword.get(opts, :secret, Keyword.get(config, :secret))
      |> maybe_trim()

    telemetry_metadata =
      config
      |> Keyword.get(:telemetry_metadata, %{})
      |> Map.new()
      |> Map.merge(Map.new(Keyword.get(opts, :telemetry_metadata, %{})))

    retry = opts |> Keyword.get(:retry, @default_retry) |> normalize_retry()

    headers =
      @default_headers
      |> Kernel.++(Keyword.get(opts, :headers, []))
      |> maybe_put_plaid_headers(client_id, secret)

    request_opts =
      [base_url: api_host, receive_timeout: timeout, headers: headers]
      |> maybe_put_finch(finch)
      |> maybe_put_adapter(adapter)

    %__MODULE__{
      request: Req.new(request_opts),
      retry: retry,
      telemetry_metadata: telemetry_metadata,
      client_id: client_id,
      secret: secret
    }
  end

  @spec create_link_token(map()) :: {:ok, map()} | {:error, map()}
  def create_link_token(params) when is_map(params) do
    new() |> create_link_token(params)
  end

  @spec create_link_token(t(), map()) :: {:ok, map()} | {:error, map()}
  def create_link_token(%__MODULE__{} = client, params) when is_map(params) do
    with :ok <- ensure_configured(client) do
      request(client, :post, "/link/token/create", json: stringify_keys(params))
      |> normalize_response()
    end
  end

  @spec exchange_public_token(String.t()) :: {:ok, map()} | {:error, map()}
  def exchange_public_token(public_token) when is_binary(public_token) do
    new() |> exchange_public_token(public_token)
  end

  @spec exchange_public_token(t(), String.t()) :: {:ok, map()} | {:error, map()}
  def exchange_public_token(%__MODULE__{} = client, public_token) when is_binary(public_token) do
    with :ok <- ensure_configured(client) do
      payload = %{"public_token" => String.trim(public_token)}

      request(client, :post, "/item/public_token/exchange", json: payload)
      |> normalize_response()
    end
  end

  @spec list_accounts(map()) :: {:ok, map()} | {:error, map()}
  def list_accounts(params) when is_map(params) do
    {access_token, params} = pop_access_token(params)
    new() |> list_accounts(access_token, params)
  end

  @spec list_accounts(t(), String.t(), map()) :: {:ok, map()} | {:error, map()}
  def list_accounts(%__MODULE__{} = client, access_token, params)
      when is_binary(access_token) and is_map(params) do
    payload =
      params
      |> stringify_keys()
      |> Map.take(["options"])
      |> Map.put("access_token", String.trim(access_token))

    with :ok <- ensure_configured(client),
         {:ok, body} <-
           request(client, :post, "/accounts/get", json: payload) |> normalize_response() do
      {:ok,
       %{
         "data" => List.wrap(Map.get(body, "accounts", [])),
         "item" => Map.get(body, "item"),
         "next_cursor" => nil
       }}
    end
  end

  def list_accounts(%__MODULE__{}, _access_token, _params) do
    {:error, %{type: :validation, details: %{message: "access_token is required"}}}
  end

  @spec sync_transactions(map()) :: {:ok, map()} | {:error, map()}
  def sync_transactions(params) when is_map(params) do
    {access_token, params} = pop_access_token(params)
    new() |> sync_transactions(access_token, params)
  end

  @spec sync_transactions(t(), String.t(), map()) :: {:ok, map()} | {:error, map()}
  def sync_transactions(%__MODULE__{} = client, access_token, params)
      when is_binary(access_token) and is_map(params) do
    payload =
      params
      |> stringify_keys()
      |> Map.take(["cursor", "count", "options"])
      |> Map.put("access_token", String.trim(access_token))

    with :ok <- ensure_configured(client),
         {:ok, body} <-
           request(client, :post, "/transactions/sync", json: payload) |> normalize_response() do
      transactions =
        List.wrap(Map.get(body, "added", [])) ++
          List.wrap(Map.get(body, "modified", []))

      {:ok,
       %{
         "data" => transactions,
         "next_cursor" => Map.get(body, "next_cursor"),
         "has_more" => Map.get(body, "has_more", false),
         "removed" => List.wrap(Map.get(body, "removed", [])),
         "request_id" => Map.get(body, "request_id")
       }}
    end
  end

  def sync_transactions(%__MODULE__{}, _access_token, _params) do
    {:error, %{type: :validation, details: %{message: "access_token is required"}}}
  end

  defp ensure_configured(%__MODULE__{} = client) do
    if is_binary(client.client_id) and String.trim(client.client_id) != "" and
         is_binary(client.secret) and String.trim(client.secret) != "" do
      :ok
    else
      {:error, %{type: :validation, details: %{message: "plaid is not configured"}}}
    end
  end

  defp request(%__MODULE__{} = client, method, path, opts) do
    metadata =
      client.telemetry_metadata
      |> Map.merge(Map.new(Keyword.get(opts, :telemetry_metadata, %{})))

    merged_opts =
      opts
      |> Keyword.put(:method, method)
      |> Keyword.put(:url, path)

    client.request
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
        if retry?(response.status, retry_opts) and
             attempt < Keyword.get(retry_opts, :max_attempts, 1) do
          backoff(attempt, retry_opts)
          perform_with_retry(request, opts, retry_opts, attempt + 1)
        else
          result
        end

      {:error, %Req.TransportError{} = transport_error} ->
        if Keyword.get(retry_opts, :retry_transport_errors, false) and
             attempt < Keyword.get(retry_opts, :max_attempts, 1) do
          backoff(attempt, retry_opts)
          perform_with_retry(request, opts, retry_opts, attempt + 1)
        else
          {:error, transport_error}
        end

      other ->
        other
    end
  end

  defp normalize_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    {:ok, body}
  end

  defp normalize_response({:ok, %Req.Response{status: status, body: body, headers: headers}}) do
    {:error, translate_error(status, body, headers)}
  end

  defp normalize_response({:error, %Req.TransportError{} = error}) do
    {:error, %{type: :transport, reason: error.reason}}
  end

  defp normalize_response({:error, other}) do
    {:error, %{type: :unexpected, reason: inspect(other)}}
  end

  defp translate_error(status, body, headers) do
    details =
      if is_map(body) do
        %{
          error_type: Map.get(body, "error_type") || Map.get(body, :error_type),
          error_code: Map.get(body, "error_code") || Map.get(body, :error_code),
          message:
            Map.get(body, "error_message") || Map.get(body, :error_message) ||
              Map.get(body, "message") || Map.get(body, :message),
          request_id: Map.get(body, "request_id") || Map.get(body, :request_id)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
      else
        %{}
      end

    %{
      type: :http,
      status: status,
      headers: headers,
      details: details
    }
  end

  defp pop_access_token(params) when is_map(params) do
    access_token =
      params[:access_token] || params["access_token"] || params[:token] || params["token"]

    cleaned =
      params
      |> Map.delete(:access_token)
      |> Map.delete("access_token")
      |> Map.delete(:token)
      |> Map.delete("token")

    {access_token, cleaned}
  end

  defp stringify_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_atom(key) -> Map.put(acc, Atom.to_string(key), value)
      {key, value}, acc when is_binary(key) -> Map.put(acc, key, value)
      {key, value}, acc -> Map.put(acc, to_string(key), value)
    end)
  end

  defp stringify_keys(_other), do: %{}

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

  defp normalize_retry(false), do: nil
  defp normalize_retry(:none), do: nil
  defp normalize_retry(nil), do: nil
  defp normalize_retry(retry) when is_map(retry), do: Map.to_list(retry)
  defp normalize_retry(retry) when is_list(retry), do: retry
  defp normalize_retry(_other), do: @default_retry

  defp maybe_put_finch(opts, nil), do: opts
  defp maybe_put_finch(opts, finch), do: Keyword.put(opts, :finch, finch)

  defp maybe_put_adapter(opts, nil), do: opts
  defp maybe_put_adapter(opts, adapter), do: Keyword.put(opts, :adapter, adapter)

  defp maybe_put_plaid_headers(headers, nil, _secret), do: headers
  defp maybe_put_plaid_headers(headers, _client_id, nil), do: headers

  defp maybe_put_plaid_headers(headers, client_id, secret) do
    [{"plaid-client-id", client_id}, {"plaid-secret", secret} | headers]
  end

  defp default_api_host(config) do
    case Keyword.get(config, :environment, "sandbox") do
      "production" -> "https://production.plaid.com"
      "development" -> "https://development.plaid.com"
      _ -> "https://sandbox.plaid.com"
    end
  end

  defp maybe_trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp maybe_trim(_value), do: nil
end
