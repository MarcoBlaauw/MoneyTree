defmodule MoneyTreeWeb.SessionControllerTest do
  use MoneyTreeWeb.ConnCase, async: true

  import MoneyTree.AccountsFixtures
  import Swoosh.TestAssertions

  alias MoneyTree.Accounts
  alias MoneyTree.Accounts.MagicLinkToken
  alias MoneyTree.Repo
  alias MoneyTreeWeb.Auth

  @valid_password valid_password()

  describe "GET /login" do
    test "renders the login page", %{conn: conn} do
      conn = get(conn, ~p"/login")
      assert html_response(conn, 200) =~ "Sign in to MoneyTree"
      assert html_response(conn, 200) =~ "Email sign-in link"
      assert html_response(conn, 200) =~ "Passkey or security key"
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

  describe "POST /login/magic" do
    setup do
      flush_emails()
      :ok
    end

    test "sends a magic link for existing users", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> init_test_session(%{})
        |> post(~p"/login/magic", %{"magic_link" => %{"email" => user.email}})

      assert html_response(conn, 200) =~ "If that email exists, a sign-in link has been sent."
      email = assert_received_email()
      assert email.to == [{"", user.email}]
      assert email.subject == "Your MoneyTree sign-in link"
    end

    test "does not disclose whether an email exists", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> post(~p"/login/magic", %{"magic_link" => %{"email" => "missing@example.com"}})

      assert html_response(conn, 200) =~ "If that email exists, a sign-in link has been sent."
      refute_email_sent()
    end
  end

  describe "POST /login/webauthn/options and /login/webauthn" do
    test "creates a session from a valid webauthn assertion", %{conn: conn} do
      user = user_fixture()

      credential =
        webauthn_credential_fixture(user, %{
          credential_id: "credential-123",
          public_key: :erlang.term_to_binary(%{1 => 2})
        })

      options_conn =
        conn
        |> init_test_session(%{})
        |> post(~p"/login/webauthn/options", %{"webauthn" => %{"email" => user.email}})

      assert %{
               "data" => %{
                 "challenge" => %{"id" => challenge_id},
                 "options" => %{"allowCredentials" => [allow_credential]}
               }
             } = json_response(options_conn, 200)

      assert allow_credential["id"] == Base.url_encode64(credential.credential_id, padding: false)

      verify_conn =
        build_conn()
        |> init_test_session(%{})
        |> post(~p"/login/webauthn", %{
          "webauthn" => %{
            "email" => user.email,
            "challenge_id" => challenge_id,
            "id" => Base.url_encode64(credential.credential_id, padding: false),
            "response" => %{
              "authenticatorData" => Base.url_encode64("authdata", padding: false),
              "clientDataJSON" =>
                Base.url_encode64(Jason.encode!(%{"signCount" => 9}), padding: false),
              "signature" => Base.url_encode64("signature", padding: false)
            }
          }
        })

      assert %{"data" => %{"redirect_to" => "/app"}} = json_response(verify_conn, 200)
      assert get_session(verify_conn, :user_token)
    end
  end

  describe "GET /login/magic/:token" do
    setup do
      flush_emails()
      :ok
    end

    test "creates a browser session from a valid magic link", %{conn: conn} do
      user = user_fixture()
      :ok = Accounts.request_magic_link(user.email, %{context: "web_magic_link"})
      token = extract_magic_link_token(user.email)

      conn =
        conn
        |> init_test_session(%{})
        |> get(~p"/login/magic/#{token}")

      assert redirected_to(conn) == ~p"/app"
      assert get_session(conn, :user_token)
    end

    test "rejects a reused magic link", %{conn: conn} do
      user = user_fixture()
      :ok = Accounts.request_magic_link(user.email, %{context: "web_magic_link"})
      token = extract_magic_link_token(user.email)

      _first_conn =
        conn
        |> init_test_session(%{})
        |> get(~p"/login/magic/#{token}")

      second_conn =
        build_conn()
        |> init_test_session(%{})
        |> get(~p"/login/magic/#{token}")

      assert html_response(second_conn, 200) =~ "already been used"
    end

    test "rejects expired magic links", %{conn: conn} do
      user = user_fixture()
      :ok = Accounts.request_magic_link(user.email, %{context: "web_magic_link"})
      token = extract_magic_link_token(user.email)

      magic_link_token = Repo.one!(MagicLinkToken)

      magic_link_token
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
      |> Repo.update!()

      conn =
        conn
        |> init_test_session(%{})
        |> get(~p"/login/magic/#{token}")

      assert html_response(conn, 200) =~ "has expired"
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

      assert redirected_to(conn) == ~p"/app"

      cookie_name = Auth.session_cookie_name()
      assert %{value: signed_token} = conn.resp_cookies[cookie_name]
      token = get_session(conn, :user_token)
      assert signed_token
      assert token
      assert {:ok, _user} = Accounts.get_user_by_session_token(token)
    end

    test "redirects existing authenticated sessions for the same context", %{conn: conn} do
      user = user_fixture()
      cookie_name = Auth.session_cookie_name()

      first_conn =
        conn
        |> init_test_session(%{})
        |> post(~p"/login", %{
          "session" => %{"email" => user.email, "password" => @valid_password}
        })

      assert redirected_to(first_conn) == ~p"/app"

      first_token = get_session(first_conn, :user_token)

      second_conn =
        first_conn
        |> recycle()
        |> init_test_session(%{})
        |> post(~p"/login", %{
          "session" => %{"email" => user.email, "password" => @valid_password}
        })

      assert redirected_to(second_conn) == ~p"/app/dashboard"
      refute Map.has_key?(second_conn.resp_cookies, cookie_name)
      assert {:ok, _user} = Accounts.get_user_by_session_token(first_token)
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

  defp extract_magic_link_token(email) do
    email_message = assert_received_email()
    assert email_message.to == [{"", email}]
    assert email_message.subject == "Your MoneyTree sign-in link"

    Regex.run(~r{/login/magic/([A-Za-z0-9_-]+)}, email_message.text_body, capture: :all_but_first)
    |> List.first()
  end

  defp assert_received_email do
    assert_receive {:email, email}
    email
  end

  defp flush_emails do
    receive do
      {:email, _email} -> flush_emails()
      {:emails, _emails} -> flush_emails()
    after
      0 -> :ok
    end
  end
end
