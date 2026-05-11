defmodule MoneyTree.Loans.RefinanceScenariosTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures
  import MoneyTree.MortgagesFixtures

  alias Decimal, as: D
  alias MoneyTree.Loans
  alias MoneyTree.Loans.RefinanceAnalysisResult
  alias MoneyTree.Loans.RefinanceFeeItem
  alias MoneyTree.Loans.RefinanceScenario

  describe "refinance scenarios" do
    test "creates and lists scenarios for a mortgage owned by the user" do
      user = user_fixture()
      mortgage = mortgage_fixture(user)

      assert {:ok, %RefinanceScenario{} = scenario} =
               Loans.create_refinance_scenario(user, mortgage, valid_scenario_attrs())

      assert scenario.user_id == user.id
      assert scenario.mortgage_id == mortgage.id
      assert scenario.name == "30-year refinance"
      assert D.equal?(scenario.new_interest_rate, D.new("0.055000"))

      assert [%RefinanceScenario{id: scenario_id}] =
               Loans.list_refinance_scenarios(user, mortgage)

      assert scenario_id == scenario.id
    end

    test "updates and deletes scenarios through the owning user scope" do
      user = user_fixture()
      other_user = user_fixture()
      mortgage = mortgage_fixture(user)

      {:ok, scenario} =
        Loans.create_refinance_scenario(user, mortgage, valid_scenario_attrs())

      assert {:ok, updated} =
               Loans.update_refinance_scenario(user, scenario, %{
                 name: "15-year refinance",
                 new_term_months: 180,
                 new_interest_rate: "0.0500"
               })

      assert updated.name == "15-year refinance"
      assert updated.new_term_months == 180
      assert D.equal?(updated.new_interest_rate, D.new("0.0500"))

      assert {:error, :not_found} =
               Loans.update_refinance_scenario(other_user, scenario, %{name: "Bad update"})

      assert {:error, :not_found} = Loans.delete_refinance_scenario(other_user, scenario)
      assert {:ok, _deleted} = Loans.delete_refinance_scenario(user, scenario.id)
      assert {:error, :not_found} = Loans.fetch_refinance_scenario(user, scenario.id)
    end

    test "rejects scenarios for another user's mortgage" do
      user = user_fixture()
      other_user = user_fixture()
      mortgage = mortgage_fixture(other_user)

      assert {:error, :not_found} =
               Loans.create_refinance_scenario(user, mortgage, valid_scenario_attrs())
    end

    test "creates fee items and stores an analysis snapshot" do
      user = user_fixture()

      mortgage =
        mortgage_fixture(user, %{
          current_balance: "400000.00",
          current_interest_rate: "0.0625",
          remaining_term_months: 360,
          monthly_payment_total: "2462.87"
        })

      {:ok, scenario} =
        Loans.create_refinance_scenario(user, mortgage, %{
          name: "Expected refi",
          new_term_months: 360,
          new_interest_rate: "0.0550",
          new_principal_amount: "406000.00"
        })

      assert {:ok, %RefinanceFeeItem{} = origination} =
               Loans.create_refinance_fee_item(user, scenario, %{
                 category: "origination",
                 name: "Origination fee",
                 expected_amount: "6000.00",
                 is_true_cost: true,
                 is_prepaid_or_escrow: false
               })

      assert origination.expected_amount == D.new("6000.00")

      assert {:ok, %RefinanceFeeItem{}} =
               Loans.create_refinance_fee_item(user, scenario, %{
                 category: "escrow_deposit",
                 name: "Initial escrow deposit",
                 expected_amount: "4200.00",
                 kind: "timing_cost",
                 is_true_cost: false,
                 is_prepaid_or_escrow: true
               })

      assert {:ok, %RefinanceAnalysisResult{} = result} =
               Loans.analyze_refinance_scenario(user, scenario)

      assert result.current_monthly_payment == D.new("2462.87")
      assert result.new_monthly_payment_expected == D.new("2305.22")
      assert result.monthly_savings_expected == D.new("157.65")
      assert result.true_refinance_cost_expected == D.new("6000.00")
      assert result.cash_to_close_expected == D.new("10200.00")
      assert result.break_even_months_expected == 39
      assert result.full_term_finance_cost_delta_expected == D.new("-50754.00")

      assert result.assumptions["true_refinance_cost_expected"] == "6000.00"
      assert result.assumptions["cash_to_close_timing_cost_expected"] == "4200.00"

      assert [%RefinanceAnalysisResult{id: result_id}] =
               Loans.list_refinance_analysis_results(user, refinance_scenario_id: scenario.id)

      assert result_id == result.id
    end

    test "prevents adding fee items to another user's scenario" do
      user = user_fixture()
      other_user = user_fixture()
      mortgage = mortgage_fixture(other_user)

      {:ok, scenario} =
        Loans.create_refinance_scenario(other_user, mortgage, valid_scenario_attrs())

      assert {:error, :not_found} =
               Loans.create_refinance_fee_item(user, scenario, %{
                 category: "origination",
                 name: "Origination fee",
                 expected_amount: "6000.00"
               })
    end

    test "updates and deletes fee items through the owning scenario scope" do
      user = user_fixture()
      other_user = user_fixture()
      mortgage = mortgage_fixture(user)

      {:ok, scenario} =
        Loans.create_refinance_scenario(user, mortgage, valid_scenario_attrs())

      {:ok, fee_item} =
        Loans.create_refinance_fee_item(user, scenario, %{
          category: "origination",
          name: "Origination fee",
          expected_amount: "6000.00"
        })

      assert {:ok, updated} =
               Loans.update_refinance_fee_item(user, fee_item, %{
                 name: "Updated origination fee",
                 expected_amount: "5500.00"
               })

      assert updated.name == "Updated origination fee"
      assert updated.expected_amount == D.new("5500.00")

      assert {:error, :not_found} =
               Loans.update_refinance_fee_item(other_user, fee_item, %{name: "Bad update"})

      assert {:ok, _deleted} = Loans.delete_refinance_fee_item(user, fee_item.id)
      assert {:error, :not_found} = Loans.fetch_refinance_fee_item(user, fee_item.id)
    end
  end

  defp valid_scenario_attrs do
    %{
      name: "30-year refinance",
      product_type: "fixed",
      new_term_months: 360,
      new_interest_rate: "0.0550",
      new_principal_amount: "406000.00",
      status: "draft"
    }
  end
end
