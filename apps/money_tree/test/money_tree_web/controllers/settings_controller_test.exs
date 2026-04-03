defmodule MoneyTreeWeb.SettingsControllerTest do
  use MoneyTreeWeb.ConnCase

  import MoneyTree.AccountsFixtures

  alias MoneyTreeWeb.Auth

  @session_cookie Auth.session_cookie_name()
  @test_host "www.example.com"

  describe "GET /api/settings" do
    test "returns settings payload for authenticated user", %{conn: conn} do
      user = user_fixture(%{full_name: "Ada Lovelace"})
      %{session: session, token: token} = session_fixture(user)
      webauthn_credential_fixture(user, %{kind: "passkey", label: "MacBook"})

      conn =
        conn
        |> put_req_header("cookie", "#{@session_cookie}=#{token}")
        |> get(~p"/api/settings")

      assert %{
               "data" => %{
                 "profile" => %{
                   "display_name" => "Ada Lovelace",
                   "email" => email,
                   "full_name" => "Ada Lovelace",
                   "role" => "member"
                 },
                 "security" => security,
                 "notifications" => notifications,
                 "sessions" => sessions
               }
             } = json_response(conn, 200)

      assert email == user.email
      assert security["passkeys_count"] == 1
      assert security["security_keys_count"] == 0
      assert security["magic_link_enabled"] == true
      assert notifications["email_enabled"] == true
      assert notifications["dashboard_enabled"] == true
      assert notifications["upcoming_lead_days"] == 3
      assert Enum.any?(sessions, fn payload -> payload["id"] == session.id end)
    end

    test "uses email prefix as display name when full name missing", %{conn: conn} do
      user = user_fixture(%{full_name: "", email: "prefix.test@example.com"})
      %{token: token} = session_fixture(user)

      conn =
        conn
        |> put_req_header("cookie", "#{@session_cookie}=#{token}")
        |> get(~p"/api/settings")

      assert %{
               "data" => %{
                 "profile" => %{
                   "display_name" => display_name,
                   "email" => "prefix.test@example.com"
                 }
               }
             } = json_response(conn, 200)

      assert display_name == "prefix.test"
    end

    test "rejects unauthenticated access", %{conn: conn} do
      conn = get(conn, ~p"/api/settings")

      assert conn.status == 401
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "updates notification settings", %{conn: conn} do
      user = user_fixture()
      %{token: token} = session_fixture(user)

      conn =
        conn
        |> put_req_header("cookie", "#{@session_cookie}=#{token}")
        |> put(~p"/api/settings/notifications", %{
          "notifications" => %{
            "email_enabled" => false,
            "dashboard_enabled" => false,
            "upcoming_lead_days" => 5,
            "resend_interval_hours" => 12,
            "max_resends" => 1
          }
        })

      assert %{
               "data" => %{
                 "notifications" => %{
                   "email_enabled" => false,
                   "dashboard_enabled" => false,
                   "upcoming_lead_days" => 5,
                   "resend_interval_hours" => 12,
                   "max_resends" => 1
                 }
               }
             } = json_response(conn, 200)
    end

    test "updates profile settings", %{conn: conn} do
      user = user_fixture(%{full_name: "Ada Lovelace"})
      %{token: token} = session_fixture(user)

      conn =
        conn
        |> put_req_header("cookie", "#{@session_cookie}=#{token}")
        |> put(~p"/api/settings/profile", %{
          "profile" => %{
            "email" => "ada+moneytree@example.com",
            "encrypted_full_name" => "Ada Byron"
          }
        })

      assert %{
               "data" => %{
                 "profile" => %{
                   "display_name" => "Ada Byron",
                   "email" => "ada+moneytree@example.com",
                   "full_name" => "Ada Byron"
                 }
               }
             } = json_response(conn, 200)
    end

    test "creates webauthn registration options", %{conn: conn} do
      user = user_fixture(%{full_name: "Ada Lovelace"})
      %{token: token} = session_fixture(user)
      existing = webauthn_credential_fixture(user, %{kind: "passkey"})

      conn =
        conn
        |> put_req_header("cookie", "#{@session_cookie}=#{token}")
        |> post(~p"/api/settings/security/webauthn/registration-options", %{
          "kind" => "security_key"
        })

      assert %{
               "data" => %{
                 "challenge" => %{"purpose" => "registration", "rp_id" => @test_host},
                 "options" => %{
                   "rp" => %{"id" => @test_host, "name" => "MoneyTree"},
                   "authenticatorSelection" => %{"authenticatorAttachment" => "cross-platform"},
                   "excludeCredentials" => exclude_credentials
                 }
               }
             } = json_response(conn, 200)

      assert Enum.any?(exclude_credentials, fn payload ->
               payload["id"] == Base.url_encode64(existing.credential_id, padding: false)
             end)
    end

    test "completes webauthn registration", %{conn: conn} do
      user = user_fixture(%{full_name: "Ada Lovelace"})
      %{token: token} = session_fixture(user)

      options_conn =
        conn
        |> put_req_header("cookie", "#{@session_cookie}=#{token}")
        |> post(~p"/api/settings/security/webauthn/registration-options", %{"kind" => "passkey"})

      assert %{"data" => %{"challenge" => %{"id" => challenge_id}}} =
               json_response(options_conn, 200)

      credential_id = Base.url_encode64("registered-passkey", padding: false)
      client_data_json = Base.url_encode64(Jason.encode!(%{"signCount" => 7}), padding: false)

      register_conn =
        build_conn()
        |> put_req_header("cookie", "#{@session_cookie}=#{token}")
        |> post(~p"/api/settings/security/webauthn/register", %{
          "challenge_id" => challenge_id,
          "id" => credential_id,
          "label" => "Office MacBook",
          "kind" => "passkey",
          "response" => %{
            "attestationObject" => credential_id,
            "clientDataJSON" => client_data_json
          }
        })

      assert %{"data" => %{"credential" => %{"label" => "Office MacBook", "kind" => "passkey"}}} =
               json_response(register_conn, 200)
    end

    test "creates webauthn authentication options", %{conn: conn} do
      user = user_fixture()
      %{token: token} = session_fixture(user)
      credential = webauthn_credential_fixture(user, %{transports: ["usb"]})

      conn =
        conn
        |> put_req_header("cookie", "#{@session_cookie}=#{token}")
        |> post(~p"/api/settings/security/webauthn/authentication-options")

      assert %{
               "data" => %{
                 "challenge" => %{"purpose" => "authentication", "rp_id" => @test_host},
                 "options" => %{"allowCredentials" => [allow_credential], "rpId" => @test_host}
               }
             } = json_response(conn, 200)

      assert allow_credential["id"] == Base.url_encode64(credential.credential_id, padding: false)
      assert allow_credential["transports"] == ["usb"]
    end

    test "revokes a webauthn credential", %{conn: conn} do
      user = user_fixture()
      %{token: token} = session_fixture(user)
      credential = webauthn_credential_fixture(user)

      conn =
        conn
        |> put_req_header("cookie", "#{@session_cookie}=#{token}")
        |> delete(~p"/api/settings/security/webauthn/credentials/#{credential.id}")

      assert response(conn, 204)
    end
  end
end
