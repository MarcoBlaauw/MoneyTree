defmodule MoneyTree.Loans.LoanFeeSubsystemTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures
  import MoneyTree.MortgagesFixtures
  import Ecto.Query

  alias Decimal, as: D
  alias MoneyTree.Loans
  alias MoneyTree.Loans.LenderQuoteFeeLine
  alias MoneyTree.Loans.LoanFeeJurisdictionProfile
  alias MoneyTree.Loans.LoanFeeType
  alias MoneyTree.Repo

  describe "loan fee defaults" do
    test "seeds enabled fee types and a Louisiana mortgage refinance profile" do
      assert :ok = Loans.ensure_default_loan_fee_configuration()

      fee_types =
        Loans.list_loan_fee_types(
          loan_type: "mortgage",
          transaction_type: "refinance",
          enabled: true
        )

      assert Enum.any?(fee_types, &(&1.code == "origination_fee"))
      assert Enum.any?(fee_types, &(&1.code == "title_insurance_lender_policy"))
      assert Enum.any?(fee_types, & &1.credit_score_sensitive)

      assert Repo.one(
               from profile in LoanFeeJurisdictionProfile,
                 where:
                   profile.country_code == "US" and profile.state_code == "LA" and
                     is_nil(profile.county_or_parish) and profile.loan_type == "mortgage" and
                     profile.transaction_type == "refinance"
             )

      assert Repo.get_by(LoanFeeJurisdictionProfile,
               country_code: "US",
               state_code: "LA",
               county_or_parish: "Orleans",
               loan_type: "mortgage",
               transaction_type: "refinance"
             )

      for parish <- [
            "St. Charles",
            "Jefferson",
            "St. John the Baptist",
            "St. Tammany",
            "East Baton Rouge"
          ] do
        assert Repo.get_by(LoanFeeJurisdictionProfile,
                 country_code: "US",
                 state_code: "LA",
                 county_or_parish: parish,
                 loan_type: "mortgage",
                 transaction_type: "refinance",
                 confidence_level: "low"
               )
      end
    end
  end

  describe "fee prediction" do
    test "returns low expected high refinance cost ranges and Louisiana profile warnings" do
      user = user_fixture()

      mortgage =
        mortgage_fixture(user, %{
          state_region: "LA",
          current_balance: "400000.00",
          current_interest_rate: "0.07125",
          remaining_term_months: 339,
          monthly_payment_total: "3233.65"
        })

      {:ok, scenario} =
        Loans.create_refinance_scenario(user, mortgage, %{
          name: "Modeled refinance",
          product_type: "fixed",
          new_term_months: 360,
          new_interest_rate: "0.0600",
          new_principal_amount: "400000.00",
          status: "draft"
        })

      assert {:ok, prediction} = Loans.predict_loan_fee_range(scenario)

      assert prediction.profile.state_code == "LA"
      assert D.compare(prediction.true_cost.low, D.new("0")) == :gt
      assert D.compare(prediction.true_cost.expected, prediction.true_cost.low) in [:gt, :eq]

      assert D.compare(prediction.total_closing_cost.high, prediction.total_closing_cost.expected) in [
               :gt,
               :eq
             ]

      assert "Some state or local fee assumptions require verification." in prediction.warnings

      assert "Louisiana recording and local tax assumptions can vary by parish. MoneyTree is using a statewide estimate until the parish is known." in prediction.warnings

      assert "MoneyTree did not apply a statewide percentage-based Louisiana mortgage tax. Parish-specific taxes or transaction fees may still apply." in prediction.warnings

      assert "appraisal_fee" not in prediction.missing_fee_codes
    end

    test "adds Orleans documentary transaction tax when Orleans Parish is known" do
      user = user_fixture()

      mortgage =
        mortgage_fixture(user, %{
          state_region: "LA",
          county_or_parish: "Orleans Parish",
          current_balance: "400000.00"
        })

      {:ok, scenario} =
        Loans.create_refinance_scenario(user, mortgage, %{
          name: "Orleans refinance",
          product_type: "fixed",
          new_term_months: 360,
          new_interest_rate: "0.0600",
          new_principal_amount: "400000.00",
          status: "draft"
        })

      assert {:ok, prediction} = Loans.predict_loan_fee_range(scenario)

      assert prediction.profile.county_or_parish == "Orleans"

      assert Enum.any?(prediction.rows, fn row ->
               row.fee_type.code == "orleans_documentary_transaction_tax" &&
                 D.equal?(row.amount_range.expected, D.new("325.00"))
             end)

      assert "Orleans Parish documentary transaction tax has been included because the property is located in Orleans Parish." in prediction.warnings

      assert Enum.any?(prediction.rows, fn row ->
               row.fee_type.code == "recording_fee" &&
                 D.equal?(row.amount_range.expected, D.new("205.00"))
             end)
    end

    test "uses low-confidence parish shells while inheriting Louisiana statewide rules" do
      assert :ok = Loans.ensure_default_loan_fee_configuration()

      user = user_fixture()

      mortgage =
        mortgage_fixture(user, %{
          state_region: "LA",
          county_or_parish: "St. Tammany Parish",
          current_balance: "400000.00"
        })

      {:ok, scenario} =
        Loans.create_refinance_scenario(user, mortgage, %{
          name: "St. Tammany refinance",
          product_type: "fixed",
          new_term_months: 360,
          new_interest_rate: "0.0600",
          new_principal_amount: "400000.00",
          status: "draft"
        })

      assert {:ok, prediction} = Loans.predict_loan_fee_range(scenario)

      assert prediction.profile.county_or_parish == "St. Tammany"
      assert prediction.profile.confidence_level == "low"

      assert Enum.any?(prediction.rows, fn row ->
               row.fee_type.code == "recording_fee" &&
                 D.equal?(row.amount_range.expected, D.new("205.00"))
             end)

      assert "Modeled fee range has low confidence." in prediction.warnings
      assert "Parish-specific recording fees should be verified." in prediction.warnings
    end

    test "adds editable generic refinance fee items without overwriting existing items" do
      user = user_fixture()

      mortgage =
        mortgage_fixture(user, %{state_region: "Louisiana", current_balance: "300000.00"})

      {:ok, scenario} =
        Loans.create_refinance_scenario(user, mortgage, %{
          name: "Generic costs",
          product_type: "fixed",
          new_term_months: 360,
          new_interest_rate: "0.0625",
          new_principal_amount: "300000.00",
          status: "draft"
        })

      assert {:ok, fee_items} = Loans.create_generic_refinance_fee_items(user, scenario)
      assert Enum.any?(fee_items, &(&1.code == "origination_fee"))
      assert Enum.any?(fee_items, & &1.is_true_cost)
      assert Enum.any?(fee_items, & &1.is_prepaid_or_escrow)

      assert {:error, :fee_items_exist} = Loans.create_generic_refinance_fee_items(user, scenario)
    end
  end

  describe "quote fee classification" do
    test "maps quote fee lines to fee types and flags missing expected fees" do
      user = user_fixture()
      mortgage = mortgage_fixture(user, %{state_region: "LA", current_balance: "400000.00"})

      {:ok, quote} =
        Loans.create_lender_quote(user, mortgage, %{
          lender_name: "Example Lender",
          quote_source: "manual",
          loan_type: "mortgage",
          product_type: "fixed",
          term_months: 360,
          interest_rate: "0.0600",
          lock_available: true,
          raw_payload: %{
            "fee_lines" => [
              %{"label" => "Appraisal fee", "amount" => "650.00"},
              %{"label" => "Mystery review charge", "amount" => "999.00"}
            ]
          },
          status: "active"
        })

      assert {:ok, quote} = Loans.fetch_lender_quote(user, quote.id, preload: [:fee_lines])
      assert [%LenderQuoteFeeLine{}, %LenderQuoteFeeLine{}] = quote.fee_lines

      lines_by_label = Map.new(quote.fee_lines, &{&1.original_label, &1})
      assert lines_by_label["Appraisal fee"].classification == "within_expected_range"
      assert lines_by_label["Mystery review charge"].classification == "unknown_fee_type"

      fee_type_count =
        LoanFeeType
        |> Repo.aggregate(:count, :id)

      assert fee_type_count > 0
    end

    test "adds a manual quote fee line and refreshes classification" do
      user = user_fixture()
      mortgage = mortgage_fixture(user, %{state_region: "LA", current_balance: "400000.00"})

      {:ok, quote} =
        Loans.create_lender_quote(user, mortgage, %{
          lender_name: "Example Lender",
          quote_source: "manual",
          loan_type: "mortgage",
          product_type: "fixed",
          term_months: 360,
          interest_rate: "0.0600",
          lock_available: true,
          status: "active"
        })

      assert {:ok, _line} =
               Loans.create_lender_quote_fee_line(user, quote, %{
                 original_label: "Appraisal fee",
                 amount: "650.00"
               })

      assert {:ok, quote} = Loans.fetch_lender_quote(user, quote.id, preload: [:fee_lines])
      assert [%LenderQuoteFeeLine{} = line] = quote.fee_lines
      assert line.original_label == "Appraisal fee"
      assert line.classification == "within_expected_range"
      assert line.requires_review == false

      assert {:ok, updated} =
               Loans.update_lender_quote_fee_line(user, line, %{
                 original_label: "Mystery review charge",
                 amount: "999.00"
               })

      assert updated.original_label == "Mystery review charge"

      assert {:ok, quote} = Loans.fetch_lender_quote(user, quote.id, preload: [:fee_lines])
      assert [%LenderQuoteFeeLine{} = updated_line] = quote.fee_lines
      assert updated_line.original_label == "Mystery review charge"
      assert updated_line.classification == "unknown_fee_type"
      assert updated_line.requires_review == true

      assert {:ok, _deleted} = Loans.delete_lender_quote_fee_line(user, updated_line.id)
      assert {:ok, quote} = Loans.fetch_lender_quote(user, quote.id, preload: [:fee_lines])
      assert quote.fee_lines == []
    end
  end
end
