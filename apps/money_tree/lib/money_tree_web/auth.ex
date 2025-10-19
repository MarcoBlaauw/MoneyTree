defmodule MoneyTreeWeb.Auth do
  @moduledoc """
  Shared helpers for managing authentication cookies in the web layer.
  """

  alias MoneyTree.Accounts

  @session_signing_salt "ueDhFrwe"

  @doc """
  Cookie name used to transport session tokens.
  """
  @spec session_cookie_name() :: String.t()
  def session_cookie_name, do: Accounts.session_cookie_name()

  @doc """
  Signing salt shared between the browser session and LiveView websocket sessions.
  """
  @spec session_signing_salt() :: String.t()
  def session_signing_salt, do: @session_signing_salt

  @doc """
  Session configuration for `Plug.Session` and LiveView connections.
  """
  @spec session_plug_options() :: keyword()
  def session_plug_options do
    [
      store: :cookie,
      key: session_cookie_name(),
      signing_salt: session_signing_salt(),
      same_site: "Strict",
      http_only: true,
      secure: secure_cookies?(),
      max_age: Accounts.session_ttl_seconds()
    ]
  end

  @doc """
  Standard cookie options for authentication tokens.
  """
  @spec cookie_options(Plug.Conn.t(), keyword()) :: keyword()
  def cookie_options(conn, overrides \\ []) do
    base_opts = [
      http_only: true,
      secure: secure_cookies?(),
      same_site: "Strict",
      max_age: Accounts.session_ttl_seconds()
    ]

    base_opts
    |> maybe_add_domain(conn)
    |> Keyword.merge(overrides)
  end

  @doc false
  @spec secure_cookies?() :: boolean()
  def secure_cookies? do
    Application.get_env(:money_tree, :secure_cookies, true)
  end

  defp maybe_add_domain(opts, conn) do
    case Application.get_env(:money_tree, :cookie_domain) do
      nil -> opts
      domain -> Keyword.put_new(opts, :domain, domain || host_from_conn(conn))
    end
  end

  defp host_from_conn(conn) do
    conn.host || "localhost"
  end
end
