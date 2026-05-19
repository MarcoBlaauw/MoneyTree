defmodule MoneyTree.Loans.GenericLoansTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures

  alias Decimal, as: D
  alias MoneyTree.Loans
  alias MoneyTree.Loans.Loan
  alias MoneyTree.Loans.RefinanceAnalysisResult
  alias MoneyTree.Loans.RefinanceScenario

  describe "generic loans" do
    test "creates and lists non-mortgage loans" do
      user = user_fixture()

      assert {:ok, %Loan{} = loan} =
               Loans.create_loan(user, %{
                 loan_type: "auto",
                 name: "Car loan",
                 lender_name: "Example Credit Union",
                 current_balance: "18500.00",
                 current_interest_rate: "0.0799",
                 remaining_term_months: 48,
                 monthly_payment_total: "452.13",
                 collateral_description: "2023 hatchback"
               })

      assert loan.user_id == user.id
      assert loan.loan_type == "auto"
      assert D.equal?(loan.current_interest_rate, D.new("0.0799"))

      assert [%Loan{id: loan_id}] = Loans.list_loans(user)
      assert loan_id == loan.id
    end

    test "generic auto loan refinance preview uses refinance calculator without mortgage fields" do
      user = user_fixture()

      {:ok, loan} =
        Loans.create_loan(user, %{
          loan_type: "auto",
          name: "Car loan",
          current_balance: "18500.00",
          current_interest_rate: "0.0799",
          remaining_term_months: 48,
          monthly_payment_total: "452.13"
        })

      assert {:ok, analysis} =
               Loans.generic_loan_refinance_preview(loan, %{
                 new_term_months: 48,
                 new_interest_rate: "0.0599",
                 new_principal_amount: "18500.00"
               })

      assert D.compare(analysis.payment_range.expected, loan.monthly_payment_total) == :lt
      assert D.compare(analysis.monthly_savings_range.expected, D.new("0")) == :gt
      assert is_list(analysis.warnings)
    end

    test "creates and lists persisted refinance scenarios for a generic loan" do
      user = user_fixture()

      {:ok, loan} =
        Loans.create_loan(user, %{
          loan_type: "auto",
          name: "Car loan",
          current_balance: "18500.00",
          current_interest_rate: "0.0799",
          remaining_term_months: 48,
          monthly_payment_total: "452.13"
        })

      assert {:ok, %RefinanceScenario{} = scenario} =
               Loans.create_loan_refinance_scenario(user, loan, %{
                 name: "Credit union refi",
                 product_type: "fixed",
                 new_term_months: 48,
                 new_interest_rate: "0.0599",
                 new_principal_amount: "18500.00"
               })

      assert scenario.user_id == user.id
      assert scenario.loan_id == loan.id
      assert is_nil(scenario.mortgage_id)

      assert [%RefinanceScenario{id: scenario_id}] =
               Loans.list_loan_refinance_scenarios(user, loan)

      assert scenario_id == scenario.id
    end

    test "saves deterministic analysis snapshots for generic loan scenarios" do
      user = user_fixture()

      {:ok, loan} =
        Loans.create_loan(user, %{
          loan_type: "auto",
          name: "Car loan",
          current_balance: "18500.00",
          current_interest_rate: "0.0799",
          remaining_term_months: 48,
          monthly_payment_total: "452.13"
        })

      {:ok, scenario} =
        Loans.create_loan_refinance_scenario(user, loan, %{
          name: "Credit union refi",
          product_type: "fixed",
          new_term_months: 48,
          new_interest_rate: "0.0599",
          new_principal_amount: "18500.00"
        })

      assert {:ok, %RefinanceAnalysisResult{} = result} =
               Loans.analyze_refinance_scenario(user, scenario)

      assert result.user_id == user.id
      assert result.loan_id == loan.id
      assert is_nil(result.mortgage_id)
      assert result.refinance_scenario_id == scenario.id
      assert D.compare(result.monthly_savings_expected, D.new("0")) == :gt

      assert [%RefinanceAnalysisResult{id: result_id}] =
               Loans.list_refinance_analysis_results(user, loan_id: loan.id)

      assert result_id == result.id
    end

    test "rejects mortgage-specific loan types from generic loans" do
      user = user_fixture()

      assert {:error, changeset} =
               Loans.create_loan(user, %{
                 loan_type: "mortgage",
                 name: "Should stay in mortgages",
                 current_balance: "18500.00",
                 current_interest_rate: "0.0799",
                 remaining_term_months: 48,
                 monthly_payment_total: "452.13"
               })

      assert "is invalid" in errors_on(changeset).loan_type
    end
  end
end
