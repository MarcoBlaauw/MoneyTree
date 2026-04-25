defmodule MoneyTreeWeb.MortgageControllerTest do
  use MoneyTreeWeb.ConnCase

  import MoneyTree.AccountsFixtures
  import MoneyTree.MortgagesFixtures

  alias MoneyTreeWeb.Auth

  @session_cookie Auth.session_cookie_name()

  describe "mortgage API" do
    test "lists only the current user's mortgages", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      %{token: token} = session_fixture(user)

      mortgage = mortgage_fixture(user, %{property_name: "Main residence"})
      _other = mortgage_fixture(other_user, %{property_name: "Other residence"})

      conn =
        conn
        |> put_req_header("cookie", "#{@session_cookie}=#{token}")
        |> get(~p"/api/mortgages")

      assert %{"data" => [%{"id" => id, "property_name" => "Main residence"}]} =
               json_response(conn, 200)

      assert id == mortgage.id
    end

    test "creates, shows, updates, and deletes a mortgage", %{conn: conn} do
      user = user_fixture()
      %{token: token} = session_fixture(user)

      authed_conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

      create_conn =
        post(authed_conn, ~p"/api/mortgages", %{
          "nickname" => "Home loan",
          "property_name" => "Oak house",
          "loan_type" => "conventional",
          "current_balance" => "390000.25",
          "current_interest_rate" => "0.0599",
          "remaining_term_months" => 338,
          "monthly_payment_total" => "2788.44",
          "has_escrow" => true,
          "escrow_included_in_payment" => true,
          "escrow_profile" => %{
            "property_tax_monthly" => "310.00",
            "homeowners_insurance_monthly" => "118.50",
            "source" => "manual_entry",
            "confidence_score" => "1.0"
          }
        })

      assert %{
               "data" => %{
                 "id" => mortgage_id,
                 "property_name" => "Oak house",
                 "loan_type" => "conventional",
                 "escrow_profile" => %{"property_tax_monthly" => "310.00"}
               }
             } = json_response(create_conn, 201)

      show_conn = get(authed_conn, ~p"/api/mortgages/#{mortgage_id}")

      assert %{"data" => %{"id" => ^mortgage_id, "property_name" => "Oak house"}} =
               json_response(show_conn, 200)

      update_conn =
        put(authed_conn, ~p"/api/mortgages/#{mortgage_id}", %{
          "property_name" => "Oak house updated",
          "monthly_payment_total" => "2810.99",
          "escrow_profile" => %{"other_escrow_monthly" => "21.00", "confidence_score" => "0.91"}
        })

      assert %{
               "data" => %{
                 "id" => ^mortgage_id,
                 "property_name" => "Oak house updated",
                 "monthly_payment_total" => "2810.99",
                 "escrow_profile" => %{
                   "other_escrow_monthly" => "21.00",
                   "confidence_score" => "0.9100"
                 }
               }
             } = json_response(update_conn, 200)

      delete_conn = delete(authed_conn, ~p"/api/mortgages/#{mortgage_id}")
      assert response(delete_conn, 204)

      missing_conn = get(authed_conn, ~p"/api/mortgages/#{mortgage_id}")
      assert json_response(missing_conn, 404) == %{"error" => "mortgage not found"}
    end

    test "returns validation errors on bad create payload", %{conn: conn} do
      user = user_fixture()
      %{token: token} = session_fixture(user)

      conn =
        conn
        |> put_req_header("cookie", "#{@session_cookie}=#{token}")
        |> post(~p"/api/mortgages", %{"property_name" => "Missing required values"})

      assert %{"errors" => errors} = json_response(conn, 422)
      assert Map.has_key?(errors, "current_balance")
      assert Map.has_key?(errors, "current_interest_rate")
    end

    test "rejects show, update, and delete for someone else's mortgage", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      %{token: token} = session_fixture(user)
      mortgage = mortgage_fixture(other_user)

      authed_conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

      assert json_response(get(authed_conn, ~p"/api/mortgages/#{mortgage.id}"), 404) == %{
               "error" => "mortgage not found"
             }

      assert json_response(
               put(authed_conn, ~p"/api/mortgages/#{mortgage.id}", %{"property_name" => "Nope"}),
               404
             ) == %{"error" => "mortgage not found"}

      assert json_response(delete(authed_conn, ~p"/api/mortgages/#{mortgage.id}"), 404) == %{
               "error" => "mortgage not found"
             }
    end
  end
end
