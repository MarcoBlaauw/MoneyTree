defmodule MoneyTreeWeb.Plugs.NextProxy do
  @moduledoc """
  Proxies authenticated browser requests to the Next.js frontend while preserving
  Phoenix controlled cookies and security headers.
  """

  @behaviour Plug

  import Plug.Conn

  alias Finch.Response

  require Logger

  @hop_by_hop_headers ~w(connection keep-alive proxy-authenticate proxy-authorization te trailers transfer-encoding upgrade)
  @filtered_response_headers ["content-security-policy", "set-cookie" | @hop_by_hop_headers]

  @type upstream_opts :: [
          scheme: String.t(),
          host: String.t(),
          port: :inet.port_number(),
          path: String.t()
        ]

  defmodule Client do
    @moduledoc false

    @callback request(
                method :: binary() | atom(),
                url :: binary(),
                headers :: [{String.t(), String.t()}],
                body :: iodata(),
                opts :: keyword()
              ) ::
                {:ok, Response.t()} | {:error, term()}
  end

  defmodule FinchClient do
    @moduledoc false

    @behaviour Client

    @impl Client
    def request(method, url, headers, body, opts) do
      finch_opts = Keyword.take(opts, [:pool_timeout, :receive_timeout])

      with {:ok, normalized_method} <- normalize_method(method) do
        normalized_method
        |> Finch.build(url, headers, body)
        |> Finch.request(MoneyTree.Finch, finch_opts)
      end
    end

    @allowed_methods ~w(get post put patch delete head options trace connect)a
    @allowed_method_lookup Map.new(@allowed_methods, &{Atom.to_string(&1), &1})

    defp normalize_method(method) when is_atom(method) do
      if method in @allowed_methods do
        {:ok, method}
      else
        {:error, {:unsupported_method, method}}
      end
    end

    defp normalize_method(method) when is_binary(method) do
      lowercase = String.downcase(method)

      case Map.fetch(@allowed_method_lookup, lowercase) do
        {:ok, allowed} -> {:ok, allowed}
        :error -> {:error, {:unsupported_method, method}}
      end
    end
  end

  @impl Plug
  def init(opts) do
    config = Application.get_env(:money_tree, __MODULE__, [])

    config
    |> Keyword.merge(opts)
    |> Keyword.put_new(:client, FinchClient)
    |> Keyword.put_new(:client_opts, [])
    |> normalize_upstream()
  end

  @impl Plug
  def call(conn, opts) do
    upstream = Keyword.fetch!(opts, :upstream)
    client = Keyword.fetch!(opts, :client)
    client_opts = Keyword.get(opts, :client_opts, [])

    nonce = csp_nonce(conn)
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    with {:ok, body, conn} <- read_full_body(conn),
         {:ok, %Response{} = response} <-
           client.request(
             conn.method,
             build_upstream_url(conn, upstream),
             build_request_headers(conn, upstream, nonce, csrf_token),
             body,
             client_opts
           ) do
      conn
      |> put_resp_header("x-csrf-token", csrf_token)
      |> maybe_put_nonce_header(nonce)
      |> relay_response(response)
    else
      {:error, reason} ->
        Logger.error("[next_proxy] upstream request failed: #{inspect(reason)}")

        conn
        |> send_resp(:bad_gateway, "Next.js upstream is unavailable")
        |> halt()
    end
  end

  defp read_full_body(conn, acc \\ []) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} -> {:ok, IO.iodata_to_binary(Enum.reverse([body | acc])), conn}
      {:more, chunk, conn} -> read_full_body(conn, [chunk | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp csp_nonce(conn) do
    conn.private[:csp_nonce] || conn.assigns[:csp_nonce]
  end

  defp normalize_upstream(opts) do
    upstream =
      opts
      |> Keyword.fetch!(:upstream)
      |> normalize_upstream_config()

    Keyword.put(opts, :upstream, upstream)
  end

  defp normalize_upstream_config(%URI{} = uri) do
    normalize_upstream_config(
      scheme: uri.scheme || "http",
      host: uri.host || "localhost",
      port: uri.port || 3000,
      path: uri.path || "/"
    )
  end

  defp normalize_upstream_config(upstream) when is_list(upstream) do
    scheme = upstream |> Keyword.get(:scheme, "http") |> String.downcase()
    host = Keyword.fetch!(upstream, :host)
    port = Keyword.get(upstream, :port, 3000)
    path = upstream |> Keyword.get(:path, "/") |> normalize_path()

    [scheme: scheme, host: host, port: port, path: path]
  end

  defp normalize_upstream_config(binary) when is_binary(binary) do
    binary
    |> URI.parse()
    |> normalize_upstream_config()
  end

  defp normalize_upstream_config(other) do
    raise ArgumentError, "Invalid upstream configuration for Next proxy: #{inspect(other)}"
  end

  defp normalize_path(path) do
    path
    |> case do
      nil -> "/"
      "" -> "/"
      ^path -> path
    end
    |> String.trim_trailing("/")
    |> case do
      "" -> "/"
      trimmed -> trimmed
    end
  end

  defp build_upstream_url(conn, upstream) do
    %URI{
      scheme: upstream[:scheme],
      host: upstream[:host],
      port: upstream[:port],
      path: merge_paths(upstream[:path], conn.request_path),
      query: conn.query_string
    }
    |> URI.to_string()
  end

  defp merge_paths("/", request_path), do: request_path

  defp merge_paths(base, request_path) do
    cond do
      request_path == "" -> base
      String.starts_with?(request_path, base) -> request_path
      true -> Path.join(base, String.trim_leading(request_path, "/"))
    end
  end

  defp build_request_headers(conn, upstream, nonce, csrf_token) do
    original_headers = Enum.reject(conn.req_headers, fn {name, _} -> header_dropped?(name) end)

    original_headers
    |> replace_header("host", host_header(upstream))
    |> put_forwarded_headers(conn, upstream)
    |> maybe_put_header("x-csp-nonce", nonce)
    |> maybe_put_header("x-csrf-token", csrf_token)
  end

  defp header_dropped?(header) do
    Enum.member?(@hop_by_hop_headers, String.downcase(header))
  end

  defp replace_header(headers, name, value) do
    name_downcased = String.downcase(name)

    headers
    |> Enum.reject(fn {existing, _} -> String.downcase(existing) == name_downcased end)
    |> Kernel.++([{name_downcased, value}])
  end

  defp host_header(upstream) do
    default_port = if upstream[:scheme] == "https", do: 443, else: 80

    case upstream[:port] do
      ^default_port -> upstream[:host]
      port -> "#{upstream[:host]}:#{port}"
    end
  end

  defp put_forwarded_headers(headers, conn, upstream) do
    client_ip = conn.remote_ip || {127, 0, 0, 1}
    ip_string = client_ip |> :inet.ntoa() |> to_string()

    forwarded_for =
      case get_req_header(conn, "x-forwarded-for") do
        [] -> ip_string
        existing -> Enum.join(existing ++ [ip_string], ", ")
      end

    headers
    |> replace_header("x-forwarded-for", forwarded_for)
    |> replace_header("x-forwarded-host", conn.host)
    |> replace_header("x-forwarded-port", Integer.to_string(conn.port))
    |> replace_header("x-forwarded-proto", Atom.to_string(conn.scheme))
    |> replace_header("x-forwarded-prefix", upstream[:path])
  end

  defp maybe_put_header(headers, _name, nil), do: headers

  defp maybe_put_header(headers, name, value) do
    replace_header(headers, name, value)
  end

  defp maybe_put_nonce_header(conn, nil), do: conn

  defp maybe_put_nonce_header(conn, nonce) do
    put_resp_header(conn, "x-csp-nonce", nonce)
  end

  defp relay_response(conn, %Response{status: status, headers: headers, body: body}) do
    conn
    |> merge_response_headers(headers)
    |> send_resp(status, body)
    |> halt()
  end

  defp merge_response_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      if header_filtered?(name) do
        acc
      else
        put_resp_header(acc, name, value)
      end
    end)
  end

  defp header_filtered?(name) do
    Enum.member?(@filtered_response_headers, String.downcase(name))
  end
end
