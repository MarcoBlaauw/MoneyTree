defmodule MoneyTreeWeb.LoanAlertRuleControllerTest do
  use MoneyTreeWeb.ConnCase

  import MoneyTree.AccountsFixtures
  import MoneyTree.MortgagesFixtures

  alias MoneyTree.Loans
  alias MoneyTreeWeb.Auth

  @session_cookie Auth.session_cookie_name()

  describe "loan alert rule API" do
    test "creates, lists, updates, evaluates, and deletes alert rules", %{conn: conn} do
      user = user_fixture()
      %{token: token} = session_fixture(user)

      mortgage =
        mortgage_fixture(user, %{
          current_balance: "400000.00",
          current_interest_rate: "0.0625",
          remaining_term_months: 360,
          monthly_payment_total: "2462.87"
        })

      {:ok, _scenario} =
        Loans.create_refinance_scenario(user, mortgage, %{
          name: "Lower rate scenario",
          new_term_months: 360,
          new_interest_rate: "0.0550",
          new_principal_amount: "400000.00"
        })

      authed_conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

      create_conn =
        post(authed_conn, ~p"/api/loans/#{mortgage.id}/alert_rules", %{
          "name" => "Savings above target",
          "kind" => "monthly_savings_above_threshold",
          "threshold_value" => "100.00"
        })

      assert %{
               "data" => %{
                 "id" => rule_id,
                 "name" => "Savings above target",
                 "kind" => "monthly_savings_above_threshold",
                 "threshold_config" => %{"threshold" => "100.00"}
               }
             } = json_response(create_conn, 201)

      assert %{"data" => [%{"id" => ^rule_id}]} =
               authed_conn
               |> get(~p"/api/loans/#{mortgage.id}/alert_rules")
               |> json_response(200)

      assert %{"data" => %{"triggered" => true}} =
               authed_conn
               |> post(~p"/api/loan_alert_rules/#{rule_id}/evaluate", %{})
               |> json_response(200)

      assert %{"data" => %{"evaluated" => 1, "triggered" => 0}} =
               authed_conn
               |> post(~p"/api/loans/#{mortgage.id}/alert_rules/evaluate", %{})
               |> json_response(200)

      assert %{"data" => %{"name" => "Updated alert"}} =
               authed_conn
               |> put(~p"/api/loan_alert_rules/#{rule_id}", %{"name" => "Updated alert"})
               |> json_response(200)

      assert "" = response(delete(authed_conn, ~p"/api/loan_alert_rules/#{rule_id}"), 204)
    end
  end
end
