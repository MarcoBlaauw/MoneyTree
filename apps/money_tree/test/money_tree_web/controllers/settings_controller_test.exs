defmodule MoneyTreeWeb.SettingsControllerTest do
  use MoneyTreeWeb.ConnCase

  import MoneyTree.AccountsFixtures

  alias MoneyTreeWeb.Auth

  @session_cookie Auth.session_cookie_name()

  describe "GET /api/settings" do
    test "returns settings payload for authenticated user", %{conn: conn} do
      user = user_fixture(%{full_name: "Ada Lovelace"})
      %{session: session, token: token} = session_fixture(user)

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
                 "notifications" => %{
                   "security_alerts" => true,
                   "transfer_alerts" => true
                 },
                 "sessions" => sessions
               }
             } = json_response(conn, 200)

      assert email == user.email
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
                 "profile" => %{"display_name" => display_name, "email" => "prefix.test@example.com"}
               }
             } = json_response(conn, 200)

      assert display_name == "prefix.test"
    end

    test "rejects unauthenticated access", %{conn: conn} do
      conn = get(conn, ~p"/api/settings")

      assert conn.status == 401
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end
  end
end
