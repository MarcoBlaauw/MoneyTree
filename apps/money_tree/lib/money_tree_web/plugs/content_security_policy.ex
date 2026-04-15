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
    next_dev_request? = next_dev_request?(conn)

    conn
    |> assign(assign_key, nonce)
    |> put_private(assign_key, nonce)
    |> put_resp_header("content-security-policy", build_csp_header(conn, nonce))
    |> maybe_put_nonce_header(nonce, next_dev_request?)
  end

  defp generate_nonce do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode64()
  end

  @vendor_script_sources [
    "https://cdn.plaid.com",
    "https://cdn.teller.io",
    "https://withpersona.com"
  ]

  @vendor_frame_sources [
    "https://teller.io",
    "https://cdn.plaid.com",
    "https://link.plaid.com",
    "https://connect.teller.io",
    "https://withpersona.com",
    "https://app.withpersona.com"
  ]

  @vendor_connect_sources [
    "https://api.plaid.com",
    "https://cdn.plaid.com",
    "https://connect.teller.io",
    "https://api.teller.io",
    "https://withpersona.com",
    "https://api.withpersona.com"
  ]

  defp build_csp_header(conn, nonce) do
    {style_src, script_src, connect_src} =
      if next_dev_request?(conn) do
        {
          ["'self'", "'unsafe-inline'"],
          ["'self'", "'unsafe-inline'", "'unsafe-eval'" | @vendor_script_sources],
          ["'self'", "ws://127.0.0.1:3100", "ws://localhost:3100" | @vendor_connect_sources]
        }
      else
        {
          ["'self'", "'nonce-#{nonce}'"],
          ["'self'", "'nonce-#{nonce}'" | @vendor_script_sources],
          ["'self'" | @vendor_connect_sources]
        }
      end

    [
      "default-src 'self'",
      "frame-ancestors 'none'",
      "base-uri 'self'",
      "form-action 'self'",
      "object-src 'none'",
      "img-src 'self' data:",
      "font-src 'self'",
      "style-src #{Enum.join(style_src, " ")}",
      "script-src #{Enum.join(script_src, " ")}",
      "frame-src 'self' #{Enum.join(@vendor_frame_sources, " ")}",
      "connect-src #{Enum.join(connect_src, " ")}"
    ]
    |> Enum.join("; ")
  end

  defp next_dev_request?(conn) do
    Application.get_env(:money_tree, :dev_routes) == true and
      String.starts_with?(conn.request_path || "", "/app/react")
  end

  defp maybe_put_nonce_header(conn, _nonce, true), do: conn
  defp maybe_put_nonce_header(conn, nonce, false), do: put_resp_header(conn, "x-csp-nonce", nonce)
end
