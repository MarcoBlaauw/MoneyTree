defmodule MoneyTreeWeb.ObligationControllerTest do
  use MoneyTreeWeb.ConnCase

  import MoneyTree.AccountsFixtures
  import MoneyTree.ObligationsFixtures

  alias MoneyTreeWeb.Auth

  @session_cookie Auth.session_cookie_name()

  describe "obligation API" do
    test "lists only the current user's obligations", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      %{token: token} = session_fixture(user)

      obligation = obligation_fixture(user, %{creditor_payee: "Travel Card"})
      _other = obligation_fixture(other_user, %{creditor_payee: "Private Loan"})

      conn =
        conn
        |> put_req_header("cookie", "#{@session_cookie}=#{token}")
        |> get(~p"/api/obligations")

      assert %{"data" => [%{"id" => id, "creditor_payee" => "Travel Card"}]} =
               json_response(conn, 200)

      assert id == obligation.id
    end

    test "creates, shows, updates, and deletes an obligation", %{conn: conn} do
      user = user_fixture()
      %{token: token} = session_fixture(user)
      funding_account = account_fixture(user, %{name: "Bills Checking"})

      authed_conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

      create_conn =
        post(authed_conn, ~p"/api/obligations", %{
          "creditor_payee" => "Electric Utility",
          "due_day" => 22,
          "due_rule" => "calendar_day",
          "minimum_due_amount" => "125.50",
          "grace_period_days" => 3,
          "linked_funding_account_id" => funding_account.id,
          "alert_preferences" => %{"upcoming_enabled" => true}
        })

      assert %{
               "data" => %{
                 "id" => obligation_id,
                 "creditor_payee" => "Electric Utility",
                 "due_day" => 22,
                 "due_rule" => "calendar_day",
                 "grace_period_days" => 3,
                 "linked_funding_account_id" => linked_funding_account_id,
                 "linked_funding_account" => %{"name" => "Bills Checking"}
               }
             } = json_response(create_conn, 201)

      assert linked_funding_account_id == funding_account.id

      show_conn = get(authed_conn, ~p"/api/obligations/#{obligation_id}")

      assert %{
               "data" => %{
                 "id" => ^obligation_id,
                 "creditor_payee" => "Electric Utility"
               }
             } = json_response(show_conn, 200)

      update_conn =
        put(authed_conn, ~p"/api/obligations/#{obligation_id}", %{
          "creditor_payee" => "Electric Utility Updated",
          "active" => false,
          "grace_period_days" => 5
        })

      assert %{
               "data" => %{
                 "id" => ^obligation_id,
                 "creditor_payee" => "Electric Utility Updated",
                 "active" => false,
                 "grace_period_days" => 5
               }
             } = json_response(update_conn, 200)

      delete_conn = delete(authed_conn, ~p"/api/obligations/#{obligation_id}")
      assert response(delete_conn, 204)

      missing_conn = get(authed_conn, ~p"/api/obligations/#{obligation_id}")
      assert json_response(missing_conn, 404) == %{"error" => "obligation not found"}
    end

    test "rejects create when funding account is inaccessible", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      %{token: token} = session_fixture(user)
      foreign_account = account_fixture(other_user, %{name: "Other Checking"})

      conn =
        conn
        |> put_req_header("cookie", "#{@session_cookie}=#{token}")
        |> post(~p"/api/obligations", %{
          "creditor_payee" => "Travel Card",
          "due_day" => 15,
          "due_rule" => "calendar_day",
          "minimum_due_amount" => "75.00",
          "grace_period_days" => 2,
          "linked_funding_account_id" => foreign_account.id
        })

      assert json_response(conn, 404) == %{"error" => "funding account not found"}
    end

    test "rejects update and delete for someone else's obligation", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      %{token: token} = session_fixture(user)
      obligation = obligation_fixture(other_user)

      authed_conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

      update_conn =
        put(authed_conn, ~p"/api/obligations/#{obligation.id}", %{
          "creditor_payee" => "Nope"
        })

      assert json_response(update_conn, 404) == %{"error" => "obligation not found"}

      delete_conn = delete(authed_conn, ~p"/api/obligations/#{obligation.id}")
      assert json_response(delete_conn, 404) == %{"error" => "obligation not found"}
    end
  end
end
