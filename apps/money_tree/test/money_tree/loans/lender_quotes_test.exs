defmodule MoneyTree.Loans.LenderQuotesTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures
  import MoneyTree.MortgagesFixtures

  alias Decimal, as: D
  alias MoneyTree.Loans
  alias MoneyTree.Loans.RefinanceScenario
  alias MoneyTree.Loans.LenderQuote

  describe "lender quotes" do
    test "creates lists fetches and updates lender quotes for a mortgage owned by the user" do
      user = user_fixture()
      mortgage = mortgage_fixture(user)

      assert {:ok, %LenderQuote{} = quote} =
               Loans.create_lender_quote(user, mortgage, valid_quote_attrs())

      assert quote.user_id == user.id
      assert quote.mortgage_id == mortgage.id
      assert quote.lender_name == "Example Lender"
      assert quote.quote_source == "manual"
      assert quote.term_months == 360
      assert D.equal?(quote.interest_rate, D.new("0.0550"))

      assert [%LenderQuote{id: quote_id}] = Loans.list_lender_quotes(user, mortgage)
      assert quote_id == quote.id

      assert {:ok, %LenderQuote{id: ^quote_id}} = Loans.fetch_lender_quote(user, quote.id)

      assert {:ok, updated} =
               Loans.update_lender_quote(user, quote, %{
                 lender_name: "Updated Lender",
                 status: "expired"
               })

      assert updated.lender_name == "Updated Lender"
      assert updated.status == "expired"
    end

    test "rejects lender quotes for another user's mortgage" do
      user = user_fixture()
      other_user = user_fixture()
      mortgage = mortgage_fixture(other_user)

      assert {:error, :not_found} =
               Loans.create_lender_quote(user, mortgage, valid_quote_attrs())
    end

    test "prevents fetching and updating another user's lender quote" do
      user = user_fixture()
      other_user = user_fixture()
      mortgage = mortgage_fixture(other_user)

      {:ok, quote} = Loans.create_lender_quote(other_user, mortgage, valid_quote_attrs())

      assert {:error, :not_found} = Loans.fetch_lender_quote(user, quote.id)

      assert {:error, :not_found} =
               Loans.update_lender_quote(user, quote, %{lender_name: "Hidden"})
    end

    test "marks active lender quotes expired after their quote expiration time" do
      user = user_fixture()
      mortgage = mortgage_fixture(user)
      expired_at = ~U[2026-05-01 12:00:00Z]

      {:ok, quote} =
        Loans.create_lender_quote(
          user,
          mortgage,
          valid_quote_attrs()
          |> Map.put(:quote_expires_at, expired_at)
        )

      assert quote.status == "active"

      assert {:ok, 1} =
               Loans.expire_lender_quotes(user, mortgage, now: ~U[2026-05-02 12:00:00Z])

      assert {:ok, expired_quote} = Loans.fetch_lender_quote(user, quote.id)
      assert expired_quote.status == "expired"
    end

    test "converts a lender quote into a draft refinance scenario with seeded fees" do
      user = user_fixture()

      mortgage =
        mortgage_fixture(user, %{
          current_balance: "400000.00",
          current_interest_rate: "0.0625",
          remaining_term_months: 360,
          monthly_payment_total: "2462.87"
        })

      {:ok, quote} = Loans.create_lender_quote(user, mortgage, valid_quote_attrs())

      assert {:ok, %RefinanceScenario{} = scenario} =
               Loans.convert_lender_quote_to_refinance_scenario(user, quote, %{
                 name: "Example quote scenario"
               })

      assert scenario.name == "Example quote scenario"
      assert scenario.scenario_type == "lender_quote"
      assert scenario.rate_source_type == "lender_quote"
      assert scenario.lender_quote_id == quote.id
      assert scenario.mortgage_id == mortgage.id
      assert D.equal?(scenario.new_principal_amount, D.new("400000.00"))
      assert D.equal?(scenario.new_interest_rate, D.new("0.0550"))
      assert scenario.new_term_months == 360
      assert scenario.status == "draft"

      fees_by_name = Map.new(scenario.fee_items, &{&1.name, &1.expected_amount})

      assert D.equal?(fees_by_name["Estimated lender quote costs"], D.new("6500.00"))
      assert D.equal?(fees_by_name["Estimated prepaid and escrow timing costs"], D.new("2500.00"))

      assert {:ok, converted_quote} = Loans.fetch_lender_quote(user, quote.id)
      assert converted_quote.status == "converted"
    end
  end

  defp valid_quote_attrs do
    %{
      lender_name: "Example Lender",
      quote_source: "manual",
      quote_reference: "quote-123",
      loan_type: "mortgage",
      product_type: "fixed",
      term_months: 360,
      interest_rate: "0.0550",
      apr: "0.0560",
      points: "0.2500",
      lender_credit_amount: "1200.00",
      estimated_closing_costs_low: "5500.00",
      estimated_closing_costs_expected: "6500.00",
      estimated_closing_costs_high: "7500.00",
      estimated_cash_to_close_expected: "9000.00",
      estimated_monthly_payment_expected: "2305.22",
      lock_available: true,
      raw_payload: %{"source_note" => "manual quote"},
      status: "active"
    }
  end
end
