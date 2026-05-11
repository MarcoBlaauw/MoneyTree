defmodule MoneyTreeWeb.RefinanceScenarioControllerTest do
  use MoneyTreeWeb.ConnCase

  import MoneyTree.AccountsFixtures
  import MoneyTree.MortgagesFixtures

  alias MoneyTreeWeb.Auth

  @session_cookie Auth.session_cookie_name()

  describe "refinance scenario API" do
    test "creates, lists, updates, analyzes, and deletes a mortgage-backed scenario", %{
      conn: conn
    } do
      user = user_fixture()
      %{token: token} = session_fixture(user)

      mortgage =
        mortgage_fixture(user, %{
          current_balance: "400000.00",
          current_interest_rate: "0.0625",
          remaining_term_months: 360,
          monthly_payment_total: "2462.87"
        })

      authed_conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

      create_conn =
        post(authed_conn, ~p"/api/loans/#{mortgage.id}/refinance_scenarios", %{
          "name" => "Expected refi",
          "product_type" => "fixed",
          "new_term_months" => 360,
          "new_interest_rate" => "0.0550",
          "new_principal_amount" => "406000.00"
        })

      assert %{
               "data" => %{
                 "id" => scenario_id,
                 "mortgage_id" => mortgage_id,
                 "name" => "Expected refi",
                 "new_interest_rate" => "0.0550"
               }
             } = json_response(create_conn, 201)

      assert mortgage_id == mortgage.id

      list_conn = get(authed_conn, ~p"/api/loans/#{mortgage.id}/refinance_scenarios")

      assert %{"data" => [%{"id" => ^scenario_id, "name" => "Expected refi"}]} =
               json_response(list_conn, 200)

      update_conn =
        put(authed_conn, ~p"/api/refinance_scenarios/#{scenario_id}", %{
          "name" => "Updated refi",
          "status" => "active"
        })

      assert %{"data" => %{"id" => ^scenario_id, "name" => "Updated refi", "status" => "active"}} =
               json_response(update_conn, 200)

      fee_conn =
        post(authed_conn, ~p"/api/refinance_scenarios/#{scenario_id}/fee_items", %{
          "category" => "origination",
          "name" => "Origination fee",
          "expected_amount" => "6000.00",
          "is_true_cost" => true,
          "is_prepaid_or_escrow" => false
        })

      assert %{
               "data" => %{
                 "refinance_scenario_id" => ^scenario_id,
                 "category" => "origination",
                 "expected_amount" => "6000.00"
               }
             } = json_response(fee_conn, 201)

      timing_conn =
        post(authed_conn, ~p"/api/refinance_scenarios/#{scenario_id}/fee_items", %{
          "category" => "escrow_deposit",
          "name" => "Initial escrow deposit",
          "expected_amount" => "4200.00",
          "kind" => "timing_cost",
          "is_true_cost" => false,
          "is_prepaid_or_escrow" => true
        })

      assert json_response(timing_conn, 201)["data"]["category"] == "escrow_deposit"

      analyze_conn = post(authed_conn, ~p"/api/refinance_scenarios/#{scenario_id}/analyze", %{})

      assert %{
               "data" => %{
                 "refinance_scenario_id" => ^scenario_id,
                 "new_monthly_payment_expected" => "2305.22",
                 "monthly_savings_expected" => "157.65",
                 "true_refinance_cost_expected" => "6000.00",
                 "cash_to_close_expected" => "10200.00",
                 "break_even_months_expected" => 39
               }
             } = json_response(analyze_conn, 201)

      delete_conn = delete(authed_conn, ~p"/api/refinance_scenarios/#{scenario_id}")
      assert response(delete_conn, 204)

      missing_conn = get(authed_conn, ~p"/api/refinance_scenarios/#{scenario_id}")
      assert json_response(missing_conn, 404) == %{"error" => "refinance scenario not found"}
    end

    test "rejects access to another user's mortgage and scenario", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      %{token: token} = session_fixture(user)
      mortgage = mortgage_fixture(other_user)

      authed_conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

      create_conn =
        post(authed_conn, ~p"/api/loans/#{mortgage.id}/refinance_scenarios", %{
          "name" => "Hidden refi",
          "new_term_months" => 360,
          "new_interest_rate" => "0.0550",
          "new_principal_amount" => "406000.00"
        })

      assert json_response(create_conn, 404) == %{"error" => "loan not found"}

      %{token: other_token} = session_fixture(other_user)

      other_conn =
        conn
        |> recycle()
        |> put_req_header("cookie", "#{@session_cookie}=#{other_token}")

      scenario_conn =
        post(other_conn, ~p"/api/loans/#{mortgage.id}/refinance_scenarios", %{
          "name" => "Other refi",
          "new_term_months" => 360,
          "new_interest_rate" => "0.0550",
          "new_principal_amount" => "406000.00"
        })

      scenario_id = json_response(scenario_conn, 201)["data"]["id"]

      assert json_response(get(authed_conn, ~p"/api/refinance_scenarios/#{scenario_id}"), 404) ==
               %{"error" => "refinance scenario not found"}
    end
  end
end
