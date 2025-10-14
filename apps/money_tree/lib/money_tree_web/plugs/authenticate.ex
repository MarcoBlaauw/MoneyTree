defmodule MoneyTreeWeb.Plugs.Authenticate do
  @moduledoc """
  Loads the current user from the session cookie and enforces role-based access.
  """

  import Plug.Conn

  require Logger

  alias MoneyTree.Accounts
  alias MoneyTree.Audit
  alias MoneyTreeWeb.Auth

  @behaviour Plug

  @impl true
  def init(opts) do
    roles =
      opts
      |> Keyword.get(:roles, MoneyTree.Users.User.roles())
      |> List.wrap()
      |> MapSet.new()

    %{roles: roles}
  end

  @impl true
  def call(conn, %{roles: roles}) do
    conn = fetch_cookies(conn)
    cookie_name = Auth.session_cookie_name()

    case conn.cookies[cookie_name] do
      nil ->
        Logger.metadata(user_id: nil, user_role: nil)
        Audit.log(:auth_missing_session, telemetry_metadata(conn))
        unauthorized(conn)

      token ->
        case Accounts.get_user_by_session_token(token) do
          {:ok, user} ->
            if MapSet.member?(roles, user.role) do
              Logger.metadata(user_id: user.id, user_role: user.role)
              assign(conn, :current_user, user)
            else
              Audit.log(:auth_forbidden, telemetry_metadata(conn, user))
              Logger.metadata(user_id: user.id, user_role: user.role)
              forbidden(conn)
            end

          {:error, :expired} ->
            Audit.log(:auth_session_expired, telemetry_metadata(conn))

            conn
            |> delete_auth_cookie()
            |> set_anonymous_metadata()
            |> unauthorized()

          {:error, _reason} ->
            Audit.log(:auth_invalid_session, telemetry_metadata(conn))

            conn
            |> delete_auth_cookie()
            |> set_anonymous_metadata()
            |> unauthorized()
        end
    end
  end

  defp unauthorized(conn) do
    send_error(conn, :unauthorized, "unauthorized")
  end

  defp forbidden(conn) do
    send_error(conn, :forbidden, "forbidden")
  end

  defp send_error(conn, status, message) do
    body = Jason.encode!(%{error: message})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end

  defp delete_auth_cookie(conn) do
    cookie_name = Auth.session_cookie_name()
    opts = Auth.cookie_options(conn, max_age: 0)
    delete_resp_cookie(conn, cookie_name, opts)
  end

  defp set_anonymous_metadata(conn) do
    Logger.metadata(user_id: nil, user_role: nil)
    conn
  end

  defp telemetry_metadata(conn, user \\ nil) do
    base = %{
      path: conn.request_path,
      method: conn.method,
      remote_ip: remote_ip(conn)
    }

    case user do
      nil -> base
      %{id: id, role: role} -> Map.merge(base, %{user_id: id, role: role})
    end
  end

  defp remote_ip(%Plug.Conn{remote_ip: nil}), do: nil

  defp remote_ip(%Plug.Conn{remote_ip: tuple}) do
    tuple
    |> :inet.ntoa()
    |> to_string()
  end
end
