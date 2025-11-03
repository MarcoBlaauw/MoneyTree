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
    |> Enum.join(" ")
  end

  defp connect_src_values(_conn), do: "'self'"

  defp websocket_sources(%Plug.Conn{} = conn) do
    ["'self'", websocket_origin(conn)]
  end

  defp websocket_origin(%Plug.Conn{} = conn) do
    scheme = websocket_scheme(conn)
    host = conn.host

    cond do
      is_nil(host) or host == "" -> nil
      true ->
        port = websocket_port(conn)

        if is_nil(port) do
          "#{scheme}://#{host}"
        else
          "#{scheme}://#{host}:#{port}"
        end
    end
  end

  defp websocket_origin(_conn), do: nil

  defp websocket_scheme(%Plug.Conn{scheme: :http}), do: "ws"
  defp websocket_scheme(%Plug.Conn{scheme: :https}), do: "wss"
  defp websocket_scheme(_conn), do: "wss"

  defp websocket_port(%Plug.Conn{scheme: :http, port: 80}), do: nil
  defp websocket_port(%Plug.Conn{scheme: :https, port: 443}), do: nil
  defp websocket_port(%Plug.Conn{port: nil}), do: nil
  defp websocket_port(%Plug.Conn{port: port}), do: port
end
