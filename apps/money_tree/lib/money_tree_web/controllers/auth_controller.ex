defmodule MoneyTreeWeb.AuthController do
  use MoneyTreeWeb, :controller

  alias MoneyTree.Accounts
  alias MoneyTree.Audit
  alias MoneyTreeWeb.Auth
  alias MoneyTreeWeb.RateLimiter

  @login_limit 5
  @login_period_seconds 60

  def register(conn, params) do
    with {:ok, user} <- Accounts.register_user(params),
         {:ok, _session, token} <- Accounts.create_session(user, session_metadata(conn)) do
      Audit.log(:user_registered, %{user_id: user.id})

      conn
      |> put_auth_cookie(token)
      |> put_status(:created)
      |> json(%{data: serialize_user(user)})
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)})
    end
  end

  def login(conn, %{"email" => email, "password" => password} = params) do
    bucket = {:login, normalize_email(email), maybe_client_ip(conn)}

    with :ok <- RateLimiter.check(bucket, @login_limit, @login_period_seconds),
         {:ok, user} <- Accounts.authenticate_user(email, password),
         {:ok, _session, token} <- Accounts.create_session(user, session_metadata(conn, params)) do
      conn
      |> put_auth_cookie(token)
      |> json(%{data: serialize_user(user)})
    else
      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid credentials"})

      {:error, :rate_limited} ->
        Audit.log(:login_rate_limited, %{email: normalize_email(email)})

        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "rate limit exceeded"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)})
    end
  end

  def login(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "email and password are required"})
  end

  def logout(conn, _params) do
    cookie_name = Auth.session_cookie_name()
    conn = fetch_cookies(conn)

    case conn.cookies[cookie_name] do
      nil ->
        conn
        |> put_status(:no_content)
        |> delete_auth_cookie()
        |> halt()

      token ->
        Accounts.delete_session(token)
        Audit.log(:logout, %{user_id: current_user_id(conn)})

        conn
        |> put_status(:no_content)
        |> delete_auth_cookie()
        |> halt()
    end
  end

  def me(conn, _params) do
    user = conn.assigns.current_user
    json(conn, %{data: serialize_user(user)})
  end

  def owner_dashboard(conn, _params) do
    json(conn, %{data: %{message: "owner access granted"}})
  end

  defp session_metadata(conn, params \\ %{}) do
    %{
      context: Map.get(params, "context", "api"),
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

  defp serialize_user(user) do
    %{
      id: user.id,
      email: user.email,
      role: user.role
    }
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  defp current_user_id(conn) do
    conn.assigns
    |> Map.get(:current_user)
    |> case do
      %{id: id} -> id
      _ -> nil
    end
  end
end
