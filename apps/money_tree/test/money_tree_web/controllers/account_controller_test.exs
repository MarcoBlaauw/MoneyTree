defmodule MoneyTreeWeb.AccountControllerTest do
  use MoneyTreeWeb.ConnCase

  import MoneyTree.AccountsFixtures

  alias MoneyTreeWeb.Auth

  @session_cookie Auth.session_cookie_name()

  describe "GET /api/accounts" do
    test "lists accessible accounts for the current user", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      %{token: token} = session_fixture(user)

      owned = account_fixture(user, %{name: "Bills Checking"})
      shared = account_fixture(other_user, %{name: "Shared Savings"})
      _foreign = account_fixture(other_user, %{name: "Private Account"})

      membership_fixture(shared, user)

      conn =
        conn
        |> put_req_header("cookie", "#{@session_cookie}=#{token}")
        |> get(~p"/api/accounts")

      assert %{"data" => accounts} = json_response(conn, 200)
      account_ids = Enum.map(accounts, & &1["id"])

      assert owned.id in account_ids
      assert shared.id in account_ids
      refute Enum.any?(accounts, &(&1["name"] == "Private Account"))
    end
  end
end
