defmodule MoneyTreeWeb.SessionController do
  use MoneyTreeWeb, :controller

  alias MoneyTree.Accounts
  alias MoneyTree.Audit
  alias MoneyTreeWeb.Auth
  alias MoneyTreeWeb.RateLimiter

  import Phoenix.Component, only: [to_form: 1, to_form: 2]

  plug :redirect_if_authenticated when action in [:new, :create]

  @login_limit 5
  @login_period_seconds 60

  def new(conn, _params) do
    render(conn, :new, form: to_form(%{}, as: :session))
  end

  def create(conn, %{"session" => %{"email" => email, "password" => password} = params}) do
    bucket = {:login, normalize_email(email), maybe_client_ip(conn)}

    with :ok <- RateLimiter.check(bucket, @login_limit, @login_period_seconds),
         {:ok, user} <- Accounts.authenticate_user(email, password),
         {:ok, _session, token} <- Accounts.create_session(user, session_metadata(conn, params)) do
      Audit.log(:login_web, %{user_id: user.id})

      conn
      |> configure_session(renew: true)
      |> put_session(:user_token, token)
      |> delete_session(:user_return_to)
      |> put_auth_cookie(token)
      |> put_flash(:info, "Signed in successfully.")
      |> redirect(to: redirect_path(conn))
    else
      {:error, :invalid_credentials} ->
        conn
        |> put_flash(:error, "Invalid email or password.")
        |> render(:new, form: to_form(%{"email" => email}, as: :session))

      {:error, :rate_limited} ->
        conn
        |> put_flash(:error, "Too many attempts. Please try again later.")
        |> render(:new, form: to_form(%{"email" => email}, as: :session))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_flash(:error, "Unable to start a new session. Please try again.")
        |> render(:new, form: to_form(changeset))
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Email and password are required.")
    |> render(:new, form: to_form(%{}, as: :session))
  end

  def delete(conn, _params) do
    cookie_name = Auth.session_cookie_name()
    conn = fetch_cookies(conn)

    conn =
      case conn.cookies[cookie_name] do
        nil ->
          conn

        token ->
          Accounts.delete_session(token)
          Audit.log(:logout_web, %{token: token})
          conn
      end

    conn
    |> configure_session(drop: true)
    |> delete_session(:user_token)
    |> delete_auth_cookie()
    |> put_flash(:info, "Signed out successfully.")
    |> redirect(to: "/login")
  end

  defp redirect_if_authenticated(%{assigns: %{current_user: %{} = _user}} = conn, _opts) do
    conn
    |> redirect(to: "/app/dashboard")
    |> halt()
  end

  defp redirect_if_authenticated(conn, _opts), do: conn

  defp session_metadata(conn, params) do
    %{
      context: Map.get(params, "context", "web"),
      ip_address: maybe_client_ip(conn),
      user_agent: List.first(get_req_header(conn, "user-agent")),
      metadata: %{}
    }
  end

  defp normalize_email(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end

  defp maybe_client_ip(%Plug.Conn{remote_ip: nil}), do: nil

  defp maybe_client_ip(%Plug.Conn{remote_ip: tuple}) do
    tuple |> :inet.ntoa() |> to_string()
  end

  defp put_auth_cookie(conn, token) do
    cookie_name = Auth.session_cookie_name()
    opts = Auth.cookie_options(conn)
    put_resp_cookie(conn, cookie_name, token, opts)
  end

  defp delete_auth_cookie(conn) do
    cookie_name = Auth.session_cookie_name()
    opts = Auth.cookie_options(conn, max_age: 0)
    delete_resp_cookie(conn, cookie_name, opts)
  end

  defp redirect_path(conn) do
    get_session(conn, :user_return_to) || "/app/dashboard"
  end
end
