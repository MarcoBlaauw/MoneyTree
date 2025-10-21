defmodule MoneyTreeWeb.SessionControllerTest do
  use MoneyTreeWeb.ConnCase, async: true

  import MoneyTree.AccountsFixtures

  alias MoneyTree.Accounts
  alias MoneyTreeWeb.Auth

  @valid_password valid_password()

  describe "GET /login" do
    test "renders the login page", %{conn: conn} do
      conn = get(conn, ~p"/login")
      assert html_response(conn, 200) =~ "Sign in to MoneyTree"
    end

    test "redirects when already authenticated", %{conn: conn} do
      user = user_fixture()
      %{token: token} = session_fixture(user, %{context: "test"})

      conn =
        conn
        |> init_test_session(%{})
        |> put_req_cookie(Auth.session_cookie_name(), token)
        |> get(~p"/login")

      assert redirected_to(conn) == ~p"/app/dashboard"
    end
  end

  describe "POST /login" do
    test "creates a session with valid credentials", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> init_test_session(%{})
        |> post(~p"/login", %{
          "session" => %{"email" => user.email, "password" => @valid_password}
        })

      assert redirected_to(conn) == ~p"/app/dashboard"

      cookie_name = Auth.session_cookie_name()
      assert %{value: token} = conn.resp_cookies[cookie_name]
      assert token == get_session(conn, :user_token)
      assert {:ok, _user} = Accounts.get_user_by_session_token(token)
    end

    test "replaces existing session for the same context", %{conn: conn} do
      user = user_fixture()
      cookie_name = Auth.session_cookie_name()

      first_conn =
        conn
        |> init_test_session(%{})
        |> post(~p"/login", %{
          "session" => %{"email" => user.email, "password" => @valid_password}
        })

      assert redirected_to(first_conn) == ~p"/app/dashboard"

      first_token = first_conn.resp_cookies[cookie_name].value
      assert {:ok, _user} = Accounts.get_user_by_session_token(first_token)

      second_conn =
        first_conn
        |> recycle()
        |> init_test_session(%{})
        |> post(~p"/login", %{
          "session" => %{"email" => user.email, "password" => @valid_password}
        })

      assert redirected_to(second_conn) == ~p"/app/dashboard"

      second_token = second_conn.resp_cookies[cookie_name].value
      refute first_token == second_token
      assert {:ok, _user} = Accounts.get_user_by_session_token(second_token)
      assert {:error, :invalid_token} = Accounts.get_user_by_session_token(first_token)
    end

    test "renders errors for invalid credentials", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> init_test_session(%{})
        |> post(~p"/login", %{"session" => %{"email" => user.email, "password" => "wrong"}})

      assert html_response(conn, 200) =~ "Invalid email or password."
    end
  end

  describe "DELETE /logout" do
    test "clears the session and cookie", %{conn: conn} do
      user = user_fixture()
      %{token: token} = session_fixture(user, %{context: "test"})
      cookie_name = Auth.session_cookie_name()

      conn =
        conn
        |> init_test_session(%{user_token: token})
        |> put_req_cookie(cookie_name, token)
        |> delete(~p"/logout")

      assert redirected_to(conn) == ~p"/login"
      assert conn.resp_cookies[cookie_name].max_age == 0
      refute get_session(conn, :user_token)
      assert {:error, :invalid_token} = Accounts.get_user_by_session_token(token)
    end
  end
end
