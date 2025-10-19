defmodule MoneyTreeWeb.Plugs.FetchCurrentUser do
  @moduledoc """
  Loads the current user for browser requests based on the session cookie.
  """

  @behaviour Plug

  import Plug.Conn

  alias MoneyTree.Accounts
  alias MoneyTreeWeb.Auth

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_cookies(conn)
    cookie_name = Auth.session_cookie_name()

    case conn.cookies[cookie_name] do
      nil ->
        clear_browser_session(conn)

      token ->
        case Accounts.get_user_by_session_token(token) do
          {:ok, user} ->
            conn
            |> assign(:current_user, user)
            |> put_session(:user_token, token)

          {:error, :expired} ->
            conn
            |> delete_auth_cookie()
            |> clear_browser_session()

          {:error, _reason} ->
            conn
            |> delete_auth_cookie()
            |> clear_browser_session()
        end
    end
  end

  defp clear_browser_session(conn) do
    conn
    |> assign(:current_user, nil)
    |> delete_session(:user_token)
  end

  defp delete_auth_cookie(conn) do
    cookie_name = Auth.session_cookie_name()
    opts = Auth.cookie_options(conn, max_age: 0)
    delete_resp_cookie(conn, cookie_name, opts)
  end
end
