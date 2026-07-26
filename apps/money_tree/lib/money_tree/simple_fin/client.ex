defmodule MoneyTree.SimpleFin.Client do
  @moduledoc """
  SimpleFIN Bridge protocol client.
  """

  alias MoneyTree.SimpleFin.Redaction

  @type request_option ::
          {:adapter, module() | {module(), keyword()} | function()}
          | {:finch, module()}
          | {:timeout, non_neg_integer()}
          | {:retry, keyword() | false | nil}

  @type t :: %__MODULE__{request: Req.Request.t(), retry: keyword() | false | nil}

  @enforce_keys [:request, :retry]
  defstruct [:request, :retry]

  @default_retry [
    max_attempts: 3,
    base_delay: 250,
    max_delay: 2_000,
    retry_for: [408, 425, 429, 500, 502, 503, 504],
    retry_transport_errors: true
  ]

  @spec new([request_option()]) :: t()
  def new(opts \\ []) do
    config = Application.get_env(:money_tree, MoneyTree.SimpleFin, [])
    timeout = Keyword.get(opts, :timeout, Keyword.get(config, :timeout, :timer.seconds(10)))
    finch = Keyword.get(opts, :finch, Keyword.get(config, :finch))
    adapter = Keyword.get(opts, :adapter)
    retry = Keyword.get(opts, :retry, @default_retry)

    request =
      [
        receive_timeout: timeout,
        headers: [{"accept", "application/json"}]
      ]
      |> maybe_put(:finch, finch)
      |> maybe_put(:adapter, adapter)
      |> Req.new()

    %__MODULE__{request: request, retry: retry}
  end

  @spec decode_setup_token(binary()) :: {:ok, binary()} | {:error, :invalid_setup_token}
  def decode_setup_token(setup_token) when is_binary(setup_token) do
    setup_token
    |> String.trim()
    |> Base.decode64()
    |> case do
      {:ok, decoded} ->
        if valid_url_string?(decoded), do: {:ok, decoded}, else: {:error, :invalid_setup_token}

      :error ->
        {:error, :invalid_setup_token}
    end
  end

  def decode_setup_token(_setup_token), do: {:error, :invalid_setup_token}

  @spec claim_setup_token(binary()) :: {:ok, binary()} | {:error, term()}
  def claim_setup_token(setup_token), do: new() |> claim_setup_token(setup_token)

  @spec claim_setup_token(t(), binary()) :: {:ok, binary()} | {:error, term()}
  def claim_setup_token(%__MODULE__{} = client, setup_token) do
    with {:ok, claim_url} <- decode_setup_token(setup_token),
         :ok <- validate_claim_url(claim_url),
         {:ok, access_url} <- post_claim_url(client, claim_url),
         :ok <- validate_access_url(access_url) do
      {:ok, access_url}
    end
  end

  @spec get_info(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_info(access_url, opts \\ []), do: new(opts) |> get_info(access_url, opts)

  @spec get_info(t(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_info(%__MODULE__{} = client, access_url, _opts) do
    with {:ok, base_url, auth} <- request_parts(access_url) do
      request(client, :get, endpoint_url(base_url, "/info"), auth, [])
      |> normalize_response()
    end
  end

  @spec get_accounts(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_accounts(access_url, opts \\ []), do: new(opts) |> get_accounts(access_url, opts)

  @spec get_accounts(t(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_accounts(%__MODULE__{} = client, access_url, opts) do
    with {:ok, base_url, auth} <- request_parts(access_url) do
      params =
        opts
        |> Keyword.take([:start_date, :end_date, :pending, :account, :balances_only, :version])
        |> Enum.reduce(%{}, fn
          {:start_date, value}, acc -> put_param(acc, "start-date", value)
          {:end_date, value}, acc -> put_param(acc, "end-date", value)
          {:balances_only, value}, acc -> put_param(acc, "balances-only", truthy_param(value))
          {:pending, value}, acc -> put_param(acc, "pending", truthy_param(value))
          {:account, value}, acc -> put_param(acc, "account", value)
          {:version, value}, acc -> put_param(acc, "version", value)
        end)
        |> Map.put_new("version", protocol_version())

      request(client, :get, endpoint_url(base_url, "/accounts"), auth, params: params)
      |> normalize_accounts_response()
    end
  end

  @spec get_account(binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_account(access_url, account_id, opts \\ []) do
    get_accounts(access_url, Keyword.put(opts, :account, account_id))
  end

  @spec get_balances(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_balances(access_url, opts \\ []) do
    get_accounts(access_url, Keyword.put(opts, :balances_only, true))
  end

  @spec validate_claim_url(binary()) :: :ok | {:error, :insecure_claim_url}
  def validate_claim_url(url), do: validate_external_https_url(url, :insecure_claim_url)

  @spec validate_access_url(binary()) :: :ok | {:error, :invalid_access_url}
  def validate_access_url(url), do: validate_external_https_url(url, :invalid_access_url)

  defp post_claim_url(%__MODULE__{} = client, claim_url) do
    request(client, :post, claim_url, nil, [])
    |> case do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        body = body_to_string(body)

        if valid_url_string?(body),
          do: {:ok, String.trim(body)},
          else: {:error, :invalid_access_url}

      {:ok, %Req.Response{status: 403}} ->
        {:error, :claim_forbidden}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport_error, Redaction.redact(reason)}}

      {:error, reason} ->
        {:error, {:transport_error, Redaction.redact(reason)}}
    end
  end

  defp normalize_accounts_response(response) do
    case normalize_response(response) do
      {:ok, body} ->
        {:ok,
         %{
           "accounts" => List.wrap(Map.get(body, "accounts", [])),
           "connections" => List.wrap(Map.get(body, "connections", [])),
           "errors" => simplefin_errors(body),
           "raw" => body
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    {:ok, normalize_body(body)}
  end

  defp normalize_response({:ok, %Req.Response{status: 402}}), do: {:error, :payment_required}
  defp normalize_response({:ok, %Req.Response{status: 403}}), do: {:error, :access_revoked}
  defp normalize_response({:ok, %Req.Response{status: 429}}), do: {:error, :quota_exceeded}

  defp normalize_response({:ok, %Req.Response{status: status}}),
    do: {:error, {:http_error, status}}

  defp normalize_response({:error, %Req.TransportError{reason: reason}}) do
    {:error, {:transport_error, Redaction.redact(reason)}}
  end

  defp normalize_response({:error, reason}) do
    {:error, {:transport_error, Redaction.redact(reason)}}
  end

  defp request(%__MODULE__{} = client, method, url, auth, opts) do
    opts =
      opts
      |> Keyword.put(:method, method)
      |> Keyword.put(:url, url)
      |> maybe_put_auth(auth)

    perform_with_retry(client.request, opts, client.retry)
  end

  defp perform_with_retry(request, opts, retry_opts, attempt \\ 1)

  defp perform_with_retry(request, opts, retry_opts, _attempt)
       when retry_opts in [nil, false, []] do
    Req.request(request, opts)
  end

  defp perform_with_retry(request, opts, retry_opts, attempt) do
    case Req.request(request, opts) do
      {:ok, %Req.Response{} = response} = result ->
        if response.status in Keyword.get(retry_opts, :retry_for, []) and
             attempt < Keyword.get(retry_opts, :max_attempts, 1) do
          backoff(attempt, retry_opts)
          perform_with_retry(request, opts, retry_opts, attempt + 1)
        else
          result
        end

      {:error, %Req.TransportError{}} = result ->
        if Keyword.get(retry_opts, :retry_transport_errors, false) and
             attempt < Keyword.get(retry_opts, :max_attempts, 1) do
          backoff(attempt, retry_opts)
          perform_with_retry(request, opts, retry_opts, attempt + 1)
        else
          result
        end
    end
  end

  defp backoff(attempt, opts) do
    base = Keyword.get(opts, :base_delay, 250)
    max_delay = Keyword.get(opts, :max_delay, 2_000)
    Process.sleep(min((base * :math.pow(2, attempt - 1)) |> trunc(), max_delay))
  end

  defp request_parts(access_url) do
    with :ok <- validate_access_url(access_url),
         %URI{} = uri <- URI.parse(access_url),
         true <- is_binary(uri.userinfo) and uri.userinfo != "" do
      auth = "Basic " <> Base.encode64(uri.userinfo)
      base_url = %URI{uri | userinfo: nil, query: nil, fragment: nil} |> URI.to_string()
      {:ok, base_url, auth}
    else
      _ -> {:error, :invalid_access_url}
    end
  end

  defp endpoint_url(base_url, path) do
    base_url
    |> URI.parse()
    |> Map.put(:path, join_paths(URI.parse(base_url).path, path))
    |> URI.to_string()
  end

  defp join_paths(nil, path), do: path
  defp join_paths("", path), do: path
  defp join_paths("/", path), do: path
  defp join_paths(base, path), do: String.trim_trailing(base, "/") <> path

  defp validate_external_https_url(url, error) when is_binary(url) do
    trimmed = String.trim(url)
    uri = URI.parse(trimmed)

    cond do
      uri.scheme != "https" -> {:error, error}
      is_nil(uri.host) or uri.host == "" -> {:error, error}
      is_binary(uri.fragment) -> {:error, error}
      not destination_allowed?(trimmed) -> {:error, error}
      true -> :ok
    end
  rescue
    _ -> {:error, error}
  end

  defp validate_external_https_url(_url, error), do: {:error, error}

  # Resolves the host and validates the actual IP address(es) it points at,
  # not just the literal hostname string, so DNS rebinding and encoded-IP
  # tricks against a private/internal target don't bypass this check.
  defp destination_allowed?(url) do
    case MoneyTree.Net.SsrfGuard.validate(url, allow_private: allow_private_hosts?()) do
      :ok -> true
      {:error, _reason} -> false
    end
  end

  defp allow_private_hosts? do
    :money_tree
    |> Application.get_env(MoneyTree.SimpleFin, [])
    |> Keyword.get(:allow_private_hosts, false)
  end

  defp valid_url_string?(value) do
    value = String.trim(value)
    uri = URI.parse(value)
    uri.scheme in ["https", "http"] and is_binary(uri.host)
  rescue
    _ -> false
  end

  defp simplefin_errors(body) when is_map(body) do
    (List.wrap(Map.get(body, "errlist", [])) ++ List.wrap(Map.get(body, "errors", [])))
    |> Enum.map(&Redaction.redact/1)
  end

  defp normalize_body(body) when is_map(body), do: body

  defp normalize_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{"body" => body}
    end
  end

  defp normalize_body(_body), do: %{}

  defp body_to_string(body) when is_binary(body), do: String.trim(body)
  defp body_to_string(body), do: body |> to_string() |> String.trim()

  defp put_param(params, _key, nil), do: params
  defp put_param(params, _key, ""), do: params
  defp put_param(params, key, %Date{} = value), do: Map.put(params, key, date_to_unix(value))

  defp put_param(params, key, %DateTime{} = value),
    do: Map.put(params, key, DateTime.to_unix(value))

  defp put_param(params, key, value), do: Map.put(params, key, to_string(value))

  defp date_to_unix(date) do
    date
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.to_unix()
  end

  defp truthy_param(true), do: "1"
  defp truthy_param("1"), do: "1"
  defp truthy_param(_), do: nil

  defp protocol_version do
    :money_tree
    |> Application.get_env(MoneyTree.SimpleFin, [])
    |> Keyword.get(:protocol_version, "2")
    |> to_string()
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_auth(opts, nil), do: opts

  defp maybe_put_auth(opts, auth),
    do: Keyword.update(opts, :headers, [{"authorization", auth}], &[{"authorization", auth} | &1])
end
