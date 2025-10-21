defmodule MoneyTreeWeb.AuthControllerTest do
  use MoneyTreeWeb.ConnCase

  import MoneyTree.AccountsFixtures

  alias MoneyTree.Accounts
  alias MoneyTree.Repo
  alias MoneyTree.Sessions.Session
  alias MoneyTree.Users.User
  alias MoneyTreeWeb.Auth

  @session_cookie Auth.session_cookie_name()

  describe "POST /api/register" do
    test "creates user, session, and sets secure cookie", %{conn: conn} do
      params = %{
        "email" => "new-user@example.com",
        "password" => "StrongPassw0rd!",
        "encrypted_full_name" => "New User"
      }

      conn = post(conn, ~p"/api/register", params)

      %{"data" => %{"email" => email, "role" => role}} = json_response(conn, 201)
      assert email == "new-user@example.com"
      assert role == "member"

      assert %{secure: true, http_only: true, same_site: "Strict"} =
               conn.resp_cookies[@session_cookie]

      user = Repo.get_by!(User, email: "new-user@example.com")
      refute user.password_hash == params["password"]

      assert Repo.get_by(Session, user_id: user.id)
    end

    test "returns errors for invalid payload", %{conn: conn} do
      conn = post(conn, ~p"/api/register", %{"email" => "invalid", "password" => "short"})

      assert %{"errors" => errors} = json_response(conn, 422)
      assert Map.has_key?(errors, "email")
      assert Map.has_key?(errors, "password")
    end
  end

  describe "POST /api/login" do
    test "authenticates and refreshes cookie", %{conn: conn} do
      user = user_fixture(%{password: "AnotherStrongPass1!"})

      conn =
        post(conn, ~p"/api/login", %{"email" => user.email, "password" => "AnotherStrongPass1!"})

      %{"data" => %{"email" => email}} = json_response(conn, 200)
      assert email == user.email

      assert %{secure: true, http_only: true, same_site: "Strict"} =
               conn.resp_cookies[@session_cookie]
    end

    test "invalidates prior session when logging in twice", %{conn: conn} do
      user = user_fixture(%{password: "TwiceLoginPass1!"})

      first_conn =
        conn
        |> post(~p"/api/login", %{"email" => user.email, "password" => "TwiceLoginPass1!"})

      assert %{"data" => %{"email" => ^user.email}} = json_response(first_conn, 200)

      first_token = first_conn.resp_cookies[@session_cookie].value
      assert {:ok, _user} = Accounts.get_user_by_session_token(first_token)

      second_conn =
        first_conn
        |> recycle()
        |> post(~p"/api/login", %{"email" => user.email, "password" => "TwiceLoginPass1!"})

      assert %{"data" => %{"email" => ^user.email}} = json_response(second_conn, 200)

      second_token = second_conn.resp_cookies[@session_cookie].value
      refute first_token == second_token
      assert {:ok, _user} = Accounts.get_user_by_session_token(second_token)
      assert {:error, :invalid_token} = Accounts.get_user_by_session_token(first_token)
    end

    test "returns unauthorized for bad credentials", %{conn: conn} do
      user = user_fixture(%{password: "CorrectHorseBattery1!"})

      conn =
        post(conn, ~p"/api/login", %{"email" => user.email, "password" => "wrongpassword"})

      assert json_response(conn, 401) == %{"error" => "invalid credentials"}
    end

    test "enforces rate limiting hook", %{conn: conn} do
      Application.put_env(:money_tree, :rate_limiter, MoneyTreeWeb.RateLimiter.DenyAll)

      on_exit(fn ->
        Application.put_env(:money_tree, :rate_limiter, MoneyTreeWeb.RateLimiter.Noop)
      end)

      _user = user_fixture(%{password: "CorrectHorseBattery1!", email: "ratelimit@example.com"})

      conn =
        post(conn, ~p"/api/login", %{
          "email" => "ratelimit@example.com",
          "password" => "CorrectHorseBattery1!"
        })

      assert json_response(conn, 429) == %{"error" => "rate limit exceeded"}
    end
  end

  describe "DELETE /api/logout" do
    test "rejects request without authentication", %{conn: conn} do
      conn = delete(conn, ~p"/api/logout")
      assert conn.status == 401
    end

    test "clears session cookie and removes session", %{conn: conn} do
      user = user_fixture(%{password: "LogoutSuccess12!"})
      %{token: token} = session_fixture(user)

      conn =
        conn
        |> put_req_header("cookie", "#{@session_cookie}=#{token}")
        |> delete(~p"/api/logout")

      assert conn.status == 204
      assert conn.resp_cookies[@session_cookie][:max_age] == 0
      refute Repo.get_by(Session, user_id: user.id)
    end
  end

  describe "role-based access" do
    test "denies owner route to member", %{conn: conn} do
      user = user_fixture(%{password: "MemberPass123!", role: :member})
      %{token: token} = session_fixture(user)

      conn =
        conn
        |> put_req_header("cookie", "#{@session_cookie}=#{token}")
        |> get(~p"/api/owner/dashboard")

      assert conn.status == 403
    end

    test "allows owner route for owner role", %{conn: conn} do
      user = user_fixture(%{password: "OwnerPass123!", role: :owner})
      %{token: token} = session_fixture(user)

      conn =
        conn
        |> put_req_header("cookie", "#{@session_cookie}=#{token}")
        |> get(~p"/api/owner/dashboard")

      assert %{"data" => %{"message" => "owner access granted"}} = json_response(conn, 200)
    end
  end
end

defmodule MoneyTreeWeb.RateLimiter.DenyAll do
  @behaviour MoneyTreeWeb.RateLimiter

  @impl true
  def check(_bucket, _limit, _period), do: {:error, :rate_limited}
end
