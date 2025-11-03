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

  defp connect_src_values(%Plug.Conn{scheme: scheme}) do
    scheme
    |> websocket_sources()
    |> Enum.join(" ")
  end

  defp connect_src_values(_conn), do: websocket_sources(:https) |> Enum.join(" ")

  defp websocket_sources(:http), do: Enum.uniq(["'self'", "ws:", "wss:"])
  defp websocket_sources(:https), do: ["'self'", "wss:"]
  defp websocket_sources(_scheme), do: ["'self'", "wss:"]
end
