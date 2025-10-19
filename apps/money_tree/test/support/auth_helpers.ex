defmodule MoneyTreeWeb.TestSupport.AuthHelpers do
  @moduledoc """
  Helpers for creating authenticated test connections and sessions.
  """

  import Phoenix.ConnTest
  alias MoneyTree.AccountsFixtures
  alias MoneyTreeWeb.Auth

  @doc """
  Returns a recycled connection configured with the session token stored
  in both the session and session cookie. Useful for mounting LiveViews
  that rely on `MoneyTreeWeb.Plugs.RequireAuthenticatedUser`.
  """
  def authed_conn(conn, token) when is_binary(token) do
    cookie_name = Auth.session_cookie_name()

    conn
    |> recycle()
    |> init_test_session(%{user_token: token})
    |> put_req_cookie(cookie_name, token)
  end

  @doc """
  Registers a session for the given user (creating one when needed) and
  returns updated test assigns including the authenticated connection.
  Accepts optional `:session_attrs` overrides passed directly to the
  session fixture.
  """
  def register_and_log_in_user(%{conn: conn} = context, opts \\ []) do
    user_attrs = Keyword.get(opts, :user_attrs, %{})

    session_attrs =
      opts |> Keyword.get(:session_attrs, %{}) |> Map.new() |> Map.put_new(:context, "test")

    user = AccountsFixtures.user_fixture(user_attrs)
    %{session: session, token: token} = AccountsFixtures.session_fixture(user, session_attrs)

    updated_context =
      context
      |> Map.put(:conn, authed_conn(conn, token))
      |> Map.put(:user, user)
      |> Map.put(:session, session)
      |> Map.put(:session_token, token)

    {:ok, updated_context}
  end
end
