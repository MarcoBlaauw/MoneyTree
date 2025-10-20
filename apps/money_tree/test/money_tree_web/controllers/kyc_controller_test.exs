defmodule MoneyTreeWeb.KycControllerTest do
  use MoneyTreeWeb.ConnCase

  import MoneyTree.AccountsFixtures

  alias MoneyTreeWeb.Auth

  @session_cookie Auth.session_cookie_name()

  setup %{conn: conn} do
    user = user_fixture()
    %{token: token} = session_fixture(user)

    conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

    {:ok, conn: conn}
  end

  describe "authentication" do
    test "requires session", %{conn: conn} do
      conn = Plug.Conn.delete_req_header(conn, "cookie")

      response = post(conn, ~p"/api/kyc/session", %{})

      assert response.status == 401
    end
  end

  describe "POST /api/kyc/session" do
    test "redacts sensitive applicant fields", %{conn: conn} do
      response =
        post(conn, ~p"/api/kyc/session", %{
          applicant: %{ssn: "123-45-6789", email: "test@example.com"}
        })

      assert %{"data" => data} = json_response(response, 200)
      assert data["applicant"]["ssn"] == "***6789"
      assert data["applicant"]["email"] == "***t@example.com"
      assert is_binary(data["client_token"])
    end
  end
end
