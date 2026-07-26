defmodule MoneyTree.Secrets.OpenBao do
  @moduledoc """
  OpenBao-backed secret provider scaffold.

  This module currently validates connection/auth metadata and provides the
  provider boundary for the next integration slice. It intentionally does not
  perform OpenBao reads yet.
  """

  @behaviour MoneyTree.Secrets.Provider

  alias MoneyTree.Secrets.Env

  @required_keys ~w(OPENBAO_ADDR OPENBAO_AUTH_METHOD OPENBAO_KV_PREFIX)
  @approle_required_keys ~w(OPENBAO_ROLE_ID OPENBAO_SECRET_ID)
  @supported_auth_methods ~w(approle)
  @telemetry_event [:money_tree, :secrets, :openbao, :request]
  @group_paths %{
    database: "database",
    cloak: "cloak",
    fred: "fred",
    phoenix: "phoenix",
    plaid: "plaid",
    smtp: "smtp"
  }

  @type config :: %{
          addr: String.t(),
          namespace: String.t() | nil,
          auth_method: String.t(),
          role_id: String.t() | nil,
          secret_id: String.t() | nil,
          kv_prefix: String.t(),
          ssl_verify: boolean(),
          timeout_ms: pos_integer()
        }

  @impl true
  def get(key) when is_binary(key) do
    get(key, [])
  end

  def get(key, opts) when is_binary(key) and is_list(opts) do
    with {:ok, group} <- group_for_key(key),
         secrets when is_map(secrets) <- get_group(group, opts) do
      Map.get(secrets, key)
    else
      {:error, :unknown_key} -> nil
    end
  end

  @impl true
  def get_group(group) when is_atom(group) do
    get_group(group, [])
  end

  def get_group(group, opts) when is_atom(group) and is_list(opts) do
    config = config!()

    with {:ok, path} <- path_for_group(group, config),
         {:ok, token} <- authenticate(config, opts),
         {:ok, payload} <- read_path(config, path, token, Keyword.put(opts, :secret_group, group)),
         {:ok, secrets} <- normalize_secret_payload(payload) do
      secrets
    else
      {:error, :unknown_group} ->
        %{}

      {:error, reason} ->
        raise RuntimeError,
              "failed to read OpenBao secret group #{inspect(group)}: #{format_error(reason)}"
    end
  end

  @spec config() :: {:ok, config()} | {:error, [String.t()]}
  def config do
    env = env_snapshot()

    errors =
      []
      |> require_keys(env, @required_keys)
      |> validate_auth_method(env)
      |> validate_approle_keys(env)
      |> validate_addr(env)
      |> validate_timeout(env)
      |> validate_ssl_verify(env)

    if errors == [] do
      {:ok,
       %{
         addr: normalize_addr(env["OPENBAO_ADDR"]),
         namespace: blank_to_nil(env["OPENBAO_NAMESPACE"]),
         auth_method: env["OPENBAO_AUTH_METHOD"],
         role_id: blank_to_nil(env["OPENBAO_ROLE_ID"]),
         secret_id: blank_to_nil(env["OPENBAO_SECRET_ID"]),
         kv_prefix: normalize_kv_prefix(env["OPENBAO_KV_PREFIX"]),
         ssl_verify: parse_bool(env["OPENBAO_SSL_VERIFY"], true),
         timeout_ms: parse_integer(env["OPENBAO_TIMEOUT_MS"], 5_000)
       }}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  @spec config!() :: config()
  def config! do
    case config() do
      {:ok, config} ->
        config

      {:error, errors} ->
        raise RuntimeError,
              "invalid OpenBao secret backend configuration: #{Enum.join(errors, "; ")}"
    end
  end

  @spec path_for_group(atom(), config()) :: {:ok, String.t()} | {:error, :unknown_group}
  def path_for_group(group, config) when is_atom(group) and is_map(config) do
    case Map.fetch(@group_paths, group) do
      {:ok, suffix} -> {:ok, join_path(config.kv_prefix, suffix)}
      :error -> {:error, :unknown_group}
    end
  end

  @spec normalize_secret_payload(map()) :: {:ok, map()} | {:error, :invalid_payload}
  def normalize_secret_payload(payload) when is_map(payload) do
    data =
      cond do
        is_map(payload["data"]) and is_map(payload["data"]["data"]) ->
          payload["data"]["data"]

        is_map(payload["data"]) ->
          payload["data"]

        true ->
          nil
      end

    if is_map(data) do
      {:ok, normalize_secret_map(data)}
    else
      {:error, :invalid_payload}
    end
  end

  def normalize_secret_payload(_payload), do: {:error, :invalid_payload}

  @spec authenticate(config(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def authenticate(%{auth_method: "approle"} = config, opts \\ []) when is_map(config) do
    body = %{
      role_id: config.role_id,
      secret_id: config.secret_id
    }

    time_request(:auth, opts, fn ->
      case post_json(config, "/v1/auth/approle/login", body, opts) do
        {:ok, status, %{"auth" => %{"client_token" => token}}}
        when status in 200..299 and is_binary(token) and token != "" ->
          {:ok, token}

        {:ok, status, _body} ->
          {:error, {:http_error, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @spec read_path(config(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_path(config, path, token, opts \\ [])
      when is_map(config) and is_binary(path) and is_binary(token) do
    time_request(:read, opts, fn ->
      case get_json(config, "/v1/#{path}", token, opts) do
        {:ok, status, body} when status in 200..299 and is_map(body) ->
          {:ok, body}

        {:ok, 404, _body} ->
          {:error, :not_found}

        {:ok, status, _body} ->
          {:error, {:http_error, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp env_snapshot do
    (@required_keys ++
       @approle_required_keys ++
       ~w(OPENBAO_NAMESPACE OPENBAO_SSL_VERIFY OPENBAO_TIMEOUT_MS))
    |> Enum.uniq()
    |> Map.new(fn key -> {key, Env.get(key)} end)
  end

  defp group_for_key(key) do
    Env.groups()
    |> Enum.find(fn group -> key in Env.keys_for_group(group) end)
    |> case do
      nil -> {:error, :unknown_key}
      group -> {:ok, group}
    end
  end

  defp require_keys(errors, env, keys) do
    Enum.reduce(keys, errors, fn key, acc ->
      if blank?(env[key]), do: ["#{key} is required" | acc], else: acc
    end)
  end

  defp validate_auth_method(errors, env) do
    method = env["OPENBAO_AUTH_METHOD"]

    cond do
      blank?(method) ->
        errors

      method in @supported_auth_methods ->
        errors

      true ->
        [
          "OPENBAO_AUTH_METHOD must be one of #{Enum.join(@supported_auth_methods, ", ")}"
          | errors
        ]
    end
  end

  defp validate_approle_keys(errors, env) do
    if env["OPENBAO_AUTH_METHOD"] == "approle" do
      require_keys(errors, env, @approle_required_keys)
    else
      errors
    end
  end

  defp validate_addr(errors, env) do
    case URI.new(env["OPENBAO_ADDR"] || "") do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) ->
        errors

      _ ->
        ["OPENBAO_ADDR must be an http or https URL" | errors]
    end
  end

  defp validate_timeout(errors, env) do
    case parse_integer_result(env["OPENBAO_TIMEOUT_MS"], 5_000) do
      {:ok, value} when value > 0 ->
        errors

      _ ->
        ["OPENBAO_TIMEOUT_MS must be a positive integer" | errors]
    end
  end

  defp validate_ssl_verify(errors, env) do
    case parse_bool_result(env["OPENBAO_SSL_VERIFY"], true) do
      {:ok, _value} -> errors
      :error -> ["OPENBAO_SSL_VERIFY must be true or false" | errors]
    end
  end

  defp normalize_addr(addr), do: String.trim_trailing(addr, "/")

  defp normalize_kv_prefix(prefix) do
    prefix
    |> String.trim()
    |> String.trim_leading("/")
    |> String.trim_trailing("/")
  end

  defp join_path(prefix, suffix) do
    [prefix, suffix]
    |> Enum.map(&String.trim(&1, "/"))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("/")
  end

  defp normalize_secret_map(data) do
    data
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp post_json(config, path, body, opts) do
    if Keyword.has_key?(opts, :plug) do
      case Req.post(request(config, opts), url: path, json: body) do
        {:ok, %Req.Response{status: status, body: response_body}} -> {:ok, status, response_body}
        {:error, %Req.TransportError{reason: :timeout}} -> {:error, :timeout}
        {:error, %Req.TransportError{} = error} -> {:error, {:transport_error, error.reason}}
        {:error, reason} -> {:error, reason}
      end
    else
      httpc_request(:post, config, path, nil, Jason.encode!(body))
    end
  end

  defp get_json(config, path, token, opts) do
    if Keyword.has_key?(opts, :plug) do
      case Req.get(request(config, opts, token), url: path) do
        {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, body}
        {:error, %Req.TransportError{reason: :timeout}} -> {:error, :timeout}
        {:error, %Req.TransportError{} = error} -> {:error, {:transport_error, error.reason}}
        {:error, reason} -> {:error, reason}
      end
    else
      httpc_request(:get, config, path, token, nil)
    end
  end

  defp httpc_request(method, config, path, token, body) do
    case ensure_httpc_started() do
      :ok -> do_httpc_request(method, config, path, token, body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_httpc_started do
    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl) do
      :ok
    else
      {:error, reason} -> {:error, {:transport_error, reason}}
    end
  end

  defp do_httpc_request(method, config, path, token, body) do
    url = String.to_charlist(config.addr <> path)
    headers = httpc_headers(config, token)
    http_options = [timeout: config.timeout_ms, connect_timeout: config.timeout_ms]
    options = [body_format: :binary]

    request =
      case method do
        :post ->
          {url, [{~c"content-type", ~c"application/json"} | headers], ~c"application/json", body}

        :get ->
          {url, headers}
      end

    case :httpc.request(method, request, http_options, options) do
      {:ok, {{_version, status, _reason_phrase}, _headers, response_body}} ->
        decode_httpc_body(status, response_body)

      {:error, {:failed_connect, _details}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp decode_httpc_body(status, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, status, decoded}
      {:error, _error} -> {:ok, status, %{}}
    end
  end

  defp httpc_headers(config, token) do
    []
    |> maybe_put_header("x-vault-namespace", config.namespace)
    |> maybe_put_header("x-vault-token", token)
    |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  defp request(config, opts, token \\ nil) do
    headers =
      []
      |> maybe_put_header("x-vault-namespace", config.namespace)
      |> maybe_put_header("x-vault-token", token)

    [
      base_url: config.addr,
      receive_timeout: config.timeout_ms,
      headers: headers
    ]
    |> Keyword.merge(Keyword.take(opts, [:plug]))
    |> Req.new()
  end

  defp maybe_put_header(headers, _key, nil), do: headers
  defp maybe_put_header(headers, _key, ""), do: headers
  defp maybe_put_header(headers, key, value), do: [{key, value} | headers]

  defp time_request(operation, opts, fun) when is_function(fun, 0) do
    start_time = System.monotonic_time()
    result = fun.()
    duration = System.monotonic_time() - start_time

    emit_request_telemetry(operation, result, duration, opts)

    result
  end

  defp emit_request_telemetry(operation, result, duration, opts) do
    metadata =
      %{
        backend: :openbao,
        operation: operation,
        status: telemetry_status(result)
      }
      |> maybe_put_metadata(:secret_group, Keyword.get(opts, :secret_group))
      |> maybe_put_metadata(:error, telemetry_error(result))

    if telemetry_started?() do
      :telemetry.execute(@telemetry_event, %{duration: duration}, metadata)
    end
  end

  defp telemetry_status({:ok, _value}), do: :ok
  defp telemetry_status({:error, _reason}), do: :error

  defp telemetry_error({:error, reason}), do: format_error(reason)
  defp telemetry_error(_result), do: nil

  defp maybe_put_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  defp telemetry_started? do
    :telemetry in Enum.map(Application.started_applications(), &elem(&1, 0))
  end

  defp format_error(:invalid_payload), do: "invalid payload"
  defp format_error(:not_found), do: "path not found"
  defp format_error(:timeout), do: "request timed out"
  defp format_error({:http_error, status}), do: "http #{status}"
  defp format_error({:transport_error, reason}), do: "transport error #{inspect(reason)}"
  defp format_error(reason), do: inspect(reason)

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
  defp blank_to_nil(value), do: if(blank?(value), do: nil, else: value)

  defp parse_integer(value, default) do
    {:ok, parsed} = parse_integer_result(value, default)
    parsed
  end

  defp parse_integer_result(nil, default), do: {:ok, default}

  defp parse_integer_result(value, _default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> {:ok, integer}
      _ -> :error
    end
  end

  defp parse_bool(value, default) do
    {:ok, parsed} = parse_bool_result(value, default)
    parsed
  end

  defp parse_bool_result(nil, default), do: {:ok, default}

  defp parse_bool_result(value, _default) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      value when value in ["true", "1", "yes", "on"] -> {:ok, true}
      value when value in ["false", "0", "no", "off"] -> {:ok, false}
      _ -> :error
    end
  end
end
