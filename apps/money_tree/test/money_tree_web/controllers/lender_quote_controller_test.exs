defmodule MoneyTreeWeb.LenderQuoteControllerTest do
  use MoneyTreeWeb.ConnCase

  import MoneyTree.AccountsFixtures
  import MoneyTree.MortgagesFixtures

  alias MoneyTreeWeb.Auth

  @session_cookie Auth.session_cookie_name()

  describe "lender quote API" do
    test "creates lists fetches and updates lender quotes", %{conn: conn} do
      user = user_fixture()
      %{token: token} = session_fixture(user)
      mortgage = mortgage_fixture(user)

      authed_conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

      create_conn =
        post(authed_conn, ~p"/api/loans/#{mortgage.id}/lender_quotes", valid_quote_payload())

      assert %{
               "data" => %{
                 "id" => quote_id,
                 "mortgage_id" => mortgage_id,
                 "lender_name" => "Example Lender",
                 "quote_source" => "manual",
                 "term_months" => 360,
                 "interest_rate" => "0.0550",
                 "estimated_monthly_payment_expected" => "2305.22",
                 "lock_available" => true,
                 "status" => "active"
               }
             } = json_response(create_conn, 201)

      assert mortgage_id == mortgage.id

      list_conn = get(authed_conn, ~p"/api/loans/#{mortgage.id}/lender_quotes")

      assert %{"data" => [%{"id" => ^quote_id, "lender_name" => "Example Lender"}]} =
               json_response(list_conn, 200)

      show_conn = get(authed_conn, ~p"/api/lender_quotes/#{quote_id}")

      assert %{
               "data" => %{"id" => ^quote_id, "raw_payload" => %{"source_note" => "manual quote"}}
             } =
               json_response(show_conn, 200)

      update_conn =
        put(authed_conn, ~p"/api/lender_quotes/#{quote_id}", %{
          "lender_name" => "Updated Lender",
          "status" => "expired"
        })

      assert %{
               "data" => %{
                 "id" => ^quote_id,
                 "lender_name" => "Updated Lender",
                 "status" => "expired"
               }
             } = json_response(update_conn, 200)

      convert_conn =
        post(authed_conn, ~p"/api/lender_quotes/#{quote_id}/convert", %{
          "name" => "Converted quote scenario"
        })

      assert %{
               "data" => %{
                 "lender_quote_id" => ^quote_id,
                 "name" => "Converted quote scenario",
                 "scenario_type" => "lender_quote",
                 "new_interest_rate" => "0.055000",
                 "new_principal_amount" => _principal,
                 "fee_items" => fee_items,
                 "status" => "draft"
               }
             } = json_response(convert_conn, 201)

      assert Enum.any?(fee_items, &(&1["name"] == "Estimated lender quote costs"))
    end

    test "rejects access to another user's lender quote", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      %{token: token} = session_fixture(user)
      mortgage = mortgage_fixture(other_user)

      authed_conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

      assert json_response(
               post(
                 authed_conn,
                 ~p"/api/loans/#{mortgage.id}/lender_quotes",
                 valid_quote_payload()
               ),
               404
             ) == %{"error" => "loan not found"}

      %{token: other_token} = session_fixture(other_user)

      other_conn =
        conn
        |> recycle()
        |> put_req_header("cookie", "#{@session_cookie}=#{other_token}")

      quote_id =
        other_conn
        |> post(~p"/api/loans/#{mortgage.id}/lender_quotes", valid_quote_payload())
        |> json_response(201)
        |> get_in(["data", "id"])

      assert json_response(get(authed_conn, ~p"/api/lender_quotes/#{quote_id}"), 404) ==
               %{"error" => "lender quote not found"}

      assert json_response(
               put(authed_conn, ~p"/api/lender_quotes/#{quote_id}", %{
                 "lender_name" => "Hidden"
               }),
               404
             ) == %{"error" => "lender quote not found"}

      assert json_response(
               post(authed_conn, ~p"/api/lender_quotes/#{quote_id}/convert", %{}),
               404
             ) == %{"error" => "lender quote not found"}
    end
  end

  defp valid_quote_payload do
    %{
      "lender_name" => "Example Lender",
      "quote_source" => "manual",
      "quote_reference" => "quote-123",
      "loan_type" => "mortgage",
      "product_type" => "fixed",
      "term_months" => 360,
      "interest_rate" => "0.0550",
      "apr" => "0.0560",
      "points" => "0.2500",
      "lender_credit_amount" => "1200.00",
      "estimated_closing_costs_low" => "5500.00",
      "estimated_closing_costs_expected" => "6500.00",
      "estimated_closing_costs_high" => "7500.00",
      "estimated_cash_to_close_expected" => "9000.00",
      "estimated_monthly_payment_expected" => "2305.22",
      "lock_available" => true,
      "raw_payload" => %{"source_note" => "manual quote"},
      "status" => "active"
    }
  end
end
