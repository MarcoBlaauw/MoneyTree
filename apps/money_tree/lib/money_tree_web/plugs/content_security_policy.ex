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
    |> put_resp_header("x-csp-nonce", nonce)
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

  defp build_csp_header(nonce) do
    [
      "default-src 'self'",
      "frame-ancestors 'none'",
      "base-uri 'self'",
      "form-action 'self'",
      "object-src 'none'",
      "img-src 'self' data:",
      "font-src 'self'",
      "style-src 'self' 'nonce-#{nonce}'",
      "script-src 'self' 'nonce-#{nonce}' #{Enum.join(@vendor_script_sources, " ")}",
      "frame-src 'self' #{Enum.join(@vendor_frame_sources, " ")}",
      "connect-src 'self' #{Enum.join(@vendor_connect_sources, " ")}"
    ]
    |> Enum.join("; ")
  end
end
