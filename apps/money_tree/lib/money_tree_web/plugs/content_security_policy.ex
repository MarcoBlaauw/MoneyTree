defmodule MoneyTreeWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  Assigns a per-request CSP nonce and enforces the Content-Security-Policy header.
  """

  @behaviour Plug

  import Plug.Conn

  @assign_key :csp_nonce

  @impl true
  def init(opts), do: Keyword.put_new(opts, :assign_key, @assign_key)

  @impl true
  def call(conn, opts) do
    nonce = generate_nonce()
    assign_key = Keyword.fetch!(opts, :assign_key)

    conn
    |> assign(assign_key, nonce)
    |> put_private(assign_key, nonce)
    |> put_resp_header("content-security-policy", build_csp_header(conn, nonce))
  end

  defp generate_nonce do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode64()
  end

  defp build_csp_header(conn, nonce) do
    [
      "default-src 'self'",
      "frame-ancestors 'none'",
      "base-uri 'self'",
      "form-action 'self'",
      "object-src 'none'",
      "img-src 'self' data:",
      "font-src 'self'",
      "style-src 'self' 'nonce-#{nonce}'",
      "script-src 'self' 'nonce-#{nonce}'",
      "connect-src #{connect_src_values(conn)}"
    ]
    |> Enum.join("; ")
  end

  defp connect_src_values(%Plug.Conn{} = conn) do
    conn
    |> websocket_sources()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  defp connect_src_values(_conn), do: "'self'"

  defp websocket_sources(%Plug.Conn{} = conn) do
    {host, forwarded_host_port} = forwarded_host_parts(conn)
    effective_host = host || conn.host

    cond do
      is_nil(effective_host) or effective_host == "" -> ["'self'"]
      true ->
        forwarded = forwarded_websocket_origins(conn, effective_host, forwarded_host_port)
        fallback = fallback_websocket_origins(conn, effective_host, forwarded)

        ["'self'" | forwarded ++ fallback]
    end
  end

  defp forwarded_host_parts(%Plug.Conn{} = conn) do
    conn
    |> Plug.Conn.get_req_header("x-forwarded-host")
    |> List.first()
    |> case do
      nil -> {nil, nil}
      host ->
        host
        |> String.split(",", trim: true)
        |> List.first()
        |> String.trim()
        |> parse_host()
    end
  end

  defp forwarded_host_parts(_conn), do: {nil, nil}

  defp forwarded_websocket_origins(%Plug.Conn{} = conn, host, forwarded_host_port) do
    protocols = forwarded_protocols(conn)
    port = forwarded_port(conn, forwarded_host_port)

    protocols
    |> Enum.map(fn protocol ->
      scheme = websocket_scheme(protocol)
      port_for_scheme = normalize_port(protocol, port)

      build_origin(host, scheme, port_for_scheme)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp forwarded_websocket_origins(_conn, _host, _forwarded_host_port), do: []

  defp fallback_websocket_origins(%Plug.Conn{} = conn, host, forwarded) do
    protocol = conn.scheme
    default_origin = build_origin(host, websocket_scheme(protocol), websocket_port(protocol, conn.port))

    origins =
      case forwarded do
        [] ->
          [default_origin | counterpart_origin(host, protocol)]

        _ ->
          [default_origin]
      end

    Enum.reject(origins, &is_nil/1)
  end

  defp fallback_websocket_origins(_conn, _host, _forwarded), do: []

  defp counterpart_origin(host, :http) do
    [build_origin(host, "wss", nil)]
  end

  defp counterpart_origin(host, :https) do
    [build_origin(host, "ws", nil)]
  end

  defp counterpart_origin(_host, _protocol), do: []

  defp build_origin(_host, _scheme, nil) when is_nil(_host) or _host == "", do: nil
  defp build_origin(_host, nil, _port), do: nil

  defp build_origin(host, scheme, nil), do: "#{scheme}://#{host}"
  defp build_origin(host, scheme, port), do: "#{scheme}://#{host}:#{port}"

  defp websocket_scheme(:http), do: "ws"
  defp websocket_scheme(:https), do: "wss"
  defp websocket_scheme("http"), do: "ws"
  defp websocket_scheme("https"), do: "wss"
  defp websocket_scheme(_), do: nil

  defp websocket_port(:http, 80), do: nil
  defp websocket_port(:https, 443), do: nil
  defp websocket_port(_scheme, nil), do: nil
  defp websocket_port(_scheme, port), do: port

  defp forwarded_protocols(%Plug.Conn{} = conn) do
    conn
    |> Plug.Conn.get_req_header("x-forwarded-proto")
    |> List.first()
    |> case do
      nil -> []
      header ->
        header
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.downcase/1)
        |> Enum.map(&parse_forwarded_protocol/1)
        |> Enum.reject(&is_nil/1)
    end
  end

  defp forwarded_protocols(_conn), do: []

  defp parse_forwarded_protocol("http"), do: :http
  defp parse_forwarded_protocol("https"), do: :https
  defp parse_forwarded_protocol(_), do: nil

  defp forwarded_port(%Plug.Conn{} = conn, forwarded_host_port) do
    port_from_header =
      conn
      |> Plug.Conn.get_req_header("x-forwarded-port")
      |> List.first()
      |> case do
        nil -> nil
        header ->
          header
          |> String.split(",", trim: true)
          |> List.first()
          |> String.trim()
          |> parse_port()
      end

    port_from_header || forwarded_host_port
  end

  defp forwarded_port(_conn, forwarded_host_port), do: forwarded_host_port

  defp parse_host(host) do
    case URI.parse("http://" <> host) do
      %URI{host: parsed_host, port: parsed_port} when not is_nil(parsed_host) ->
        {parsed_host, parsed_port}

      _ ->
        {host, nil}
    end
  end

  defp parse_port(port) do
    case Integer.parse(port) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp default_port(:http), do: 80
  defp default_port(:https), do: 443
  defp default_port(_), do: nil

  defp normalize_port(_protocol, nil), do: nil

  defp normalize_port(protocol, port) do
    case default_port(protocol) do
      ^port -> nil
      _ -> port
    end
  end
end
