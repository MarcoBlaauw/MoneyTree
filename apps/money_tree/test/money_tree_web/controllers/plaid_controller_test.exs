defmodule MoneyTreeWeb.PlaidControllerTest do
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

      response = post(conn, ~p"/api/plaid/link_token", %{})

      assert response.status == 401
    end
  end

  describe "POST /api/plaid/link_token" do
    test "returns a link token payload", %{conn: conn} do
      response = post(conn, ~p"/api/plaid/link_token", %{products: ["auth"]})

      assert %{"data" => data} = json_response(response, 200)
      assert is_binary(data["link_token"])
      assert is_binary(data["expiration"])
      assert data["metadata"] == %{"products" => ["auth"]}
    end
  end
end
