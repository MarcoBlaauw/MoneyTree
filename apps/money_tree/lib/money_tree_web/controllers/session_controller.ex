defmodule MoneyTreeWeb.SessionController do
  use MoneyTreeWeb, :controller

  alias MoneyTree.Accounts
  alias MoneyTree.Audit
  alias MoneyTreeWeb.Auth
  alias MoneyTreeWeb.RateLimiter
  require Logger

  import Phoenix.Component, only: [to_form: 1, to_form: 2]

  plug :redirect_if_authenticated when action in [:new, :create]

  @login_limit 5
  @login_period_seconds 60

  def new(conn, _params) do
    render(conn, :new,
      form: to_form(%{}, as: :session),
      magic_link_form: to_form(%{}, as: :magic_link)
    )
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
        |> render(:new,
          form: to_form(%{"email" => email}, as: :session),
          magic_link_form: to_form(%{"email" => email}, as: :magic_link)
        )

      {:error, :rate_limited} ->
        conn
        |> put_flash(:error, "Too many attempts. Please try again later.")
        |> render(:new,
          form: to_form(%{"email" => email}, as: :session),
          magic_link_form: to_form(%{"email" => email}, as: :magic_link)
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_flash(:error, "Unable to start a new session. Please try again.")
        |> render(:new, form: to_form(changeset), magic_link_form: to_form(%{}, as: :magic_link))
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Email and password are required.")
    |> render(:new,
      form: to_form(%{}, as: :session),
      magic_link_form: to_form(%{}, as: :magic_link)
    )
  end

  def request_magic_link(conn, %{"magic_link" => %{"email" => email}}) do
    :ok =
      Accounts.request_magic_link(email, session_metadata(conn, %{"context" => "web_magic_link"}))

    conn
    |> put_flash(:info, "If that email exists, a sign-in link has been sent.")
    |> render(:new,
      form: to_form(%{"email" => email}, as: :session),
      magic_link_form: to_form(%{"email" => email}, as: :magic_link)
    )
  end

  def request_magic_link(conn, _params) do
    conn
    |> put_flash(:error, "Email is required to send a sign-in link.")
    |> render(:new,
      form: to_form(%{}, as: :session),
      magic_link_form: to_form(%{}, as: :magic_link)
    )
  end

  def request_webauthn_options(conn, %{"webauthn" => %{"email" => email} = params}) do
    case Accounts.get_user_by_email(email) do
      %{} = user ->
        case Accounts.create_webauthn_authentication_options(
               user,
               Map.merge(params, webauthn_request_context(conn))
             ) do
          {:ok, challenge, options} ->
            json(conn, %{data: %{challenge: %{id: challenge.id}, options: options}})

          {:error, _reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "unable to start passkey sign-in"})
        end

      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "no passkey sign-in available for that email"})
    end
  end

  def request_webauthn_options(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "email is required"})
  end

  def consume_webauthn(
        conn,
        %{"webauthn" => %{"email" => email, "challenge_id" => challenge_id} = params}
      ) do
    case Accounts.get_user_by_email(email) do
      %{} = user ->
        case Accounts.authenticate_with_webauthn(user, challenge_id, params) do
          {:ok, user} ->
            {:ok, _session, session_token} =
              Accounts.create_session(user, session_metadata(conn, %{"context" => "web"}))

            Audit.log(:webauthn_login_web, %{user_id: user.id})

            conn
            |> configure_session(renew: true)
            |> put_session(:user_token, session_token)
            |> delete_session(:user_return_to)
            |> put_auth_cookie(session_token)
            |> json(%{data: %{redirect_to: redirect_path(conn)}})

          {:error, :invalid_credentials} ->
            conn
            |> put_status(:unauthorized)
            |> json(%{error: "invalid passkey assertion"})

          {:error, %_{} = error} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: Exception.message(error)})

          {:error, :expired} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "passkey sign-in has expired"})

          {:error, :already_used} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "passkey sign-in has already been used"})

          {:error, :not_found} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "passkey sign-in challenge not found"})
        end

      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "no passkey sign-in available for that email"})
    end
  end

  def consume_webauthn(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "email and challenge are required"})
  end

  def consume_magic_link(conn, %{"token" => token}) do
    case Accounts.consume_magic_link(token) do
      {:ok, user} ->
        {:ok, _session, session_token} =
          Accounts.create_session(user, session_metadata(conn, %{"context" => "web"}))

        Audit.log(:magic_link_login_web, %{user_id: user.id})

        conn
        |> configure_session(renew: true)
        |> put_session(:user_token, session_token)
        |> delete_session(:user_return_to)
        |> put_auth_cookie(session_token)
        |> put_flash(:info, "Signed in successfully.")
        |> redirect(to: redirect_path(conn))

      {:error, :expired} ->
        conn
        |> put_flash(:error, "That sign-in link has expired. Request a new one.")
        |> render(:new,
          form: to_form(%{}, as: :session),
          magic_link_form: to_form(%{}, as: :magic_link)
        )

      {:error, :already_used} ->
        conn
        |> put_flash(:error, "That sign-in link has already been used. Request a new one.")
        |> render(:new,
          form: to_form(%{}, as: :session),
          magic_link_form: to_form(%{}, as: :magic_link)
        )

      {:error, :invalid_token} ->
        conn
        |> put_flash(:error, "That sign-in link is invalid. Request a new one.")
        |> render(:new,
          form: to_form(%{}, as: :session),
          magic_link_form: to_form(%{}, as: :magic_link)
        )
    end
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
    get_session(conn, :user_return_to) || "/app"
  end

  defp webauthn_request_context(conn) do
    origin = request_origin(conn)
    rp_id = URI.parse(origin).host || conn.host

    Logger.debug(
      "WebAuthn request context (session): origin_header=#{inspect(List.first(get_req_header(conn, "origin")))} host=#{inspect(conn.host)} port=#{inspect(conn.port)} computed_origin=#{inspect(origin)} rp_id=#{inspect(rp_id)}"
    )

    %{
      "origin" => origin,
      "rp_id" => rp_id
    }
  end

  defp request_origin(conn) do
    case List.first(get_req_header(conn, "origin")) do
      origin when is_binary(origin) and origin != "" ->
        origin

      _ ->
        scheme = Atom.to_string(conn.scheme)
        port = conn.port
        host = conn.host

        case {scheme, port} do
          {"http", 80} -> "#{scheme}://#{host}"
          {"https", 443} -> "#{scheme}://#{host}"
          _ -> "#{scheme}://#{host}:#{port}"
        end
    end
  end
end
