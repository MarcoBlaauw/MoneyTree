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
    |> put_resp_header("content-security-policy", build_csp_header(nonce))
  end

  defp generate_nonce do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode64()
  end

  @vendor_script_sources [
    "https://cdn.plaid.com",
    "https://withpersona.com"
  ]

  @vendor_frame_sources [
    "https://cdn.plaid.com",
    "https://link.plaid.com",
    "https://withpersona.com",
    "https://app.withpersona.com"
  ]

  @vendor_connect_sources [
    "https://api.plaid.com",
    "https://cdn.plaid.com",
    "https://withpersona.com",
    "https://api.withpersona.com"
  ]

  defp build_csp_header(nonce) do
    style_src = ["'self'", "'nonce-#{nonce}'"]
    script_src = ["'self'", "'nonce-#{nonce}'" | @vendor_script_sources]
    connect_src = ["'self'" | @vendor_connect_sources]

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
end
