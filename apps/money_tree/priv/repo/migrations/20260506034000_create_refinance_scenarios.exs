defmodule MoneyTree.Repo.Migrations.CreateRefinanceScenarios do
  use Ecto.Migration

  def change do
    create table(:refinance_scenarios, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :mortgage_id, references(:mortgages, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :scenario_type, :string, null: false, default: "manual"
      add :product_type, :string
      add :new_term_months, :integer, null: false
      add :new_interest_rate, :decimal, precision: 9, scale: 6, null: false
      add :new_apr, :decimal, precision: 9, scale: 6
      add :new_principal_amount, :decimal, precision: 18, scale: 2, null: false
      add :cash_out_amount, :decimal, precision: 18, scale: 2
      add :cash_in_amount, :decimal, precision: 18, scale: 2
      add :roll_costs_into_loan, :boolean, null: false, default: false
      add :points, :decimal, precision: 9, scale: 4
      add :lender_credit_amount, :decimal, precision: 18, scale: 2
      add :expected_years_before_sale_or_refi, :integer
      add :closing_date_assumption, :date
      add :rate_source_type, :string
      add :status, :string, null: false, default: "draft"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:refinance_scenarios, [:user_id])
    create index(:refinance_scenarios, [:mortgage_id])
    create index(:refinance_scenarios, [:status])

    create table(:refinance_fee_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :refinance_scenario_id,
          references(:refinance_scenarios, type: :binary_id, on_delete: :delete_all),
          null: false

      add :category, :string, null: false
      add :code, :string
      add :name, :string, null: false
      add :low_amount, :decimal, precision: 18, scale: 2
      add :expected_amount, :decimal, precision: 18, scale: 2
      add :high_amount, :decimal, precision: 18, scale: 2
      add :fixed_amount, :decimal, precision: 18, scale: 2
      add :percentage_of_loan_amount, :decimal, precision: 9, scale: 6
      add :kind, :string, null: false, default: "fee"
      add :paid_at_closing, :boolean, null: false, default: true
      add :financed, :boolean, null: false, default: false
      add :is_true_cost, :boolean, null: false, default: true
      add :is_prepaid_or_escrow, :boolean, null: false, default: false
      add :required, :boolean, null: false, default: false
      add :sort_order, :integer, null: false, default: 0
      add :notes, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:refinance_fee_items, [:refinance_scenario_id])
    create index(:refinance_fee_items, [:category])

    create table(:refinance_analysis_results, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :mortgage_id, references(:mortgages, type: :binary_id, on_delete: :delete_all),
        null: false

      add :refinance_scenario_id,
          references(:refinance_scenarios, type: :binary_id, on_delete: :delete_all),
          null: false

      add :analysis_version, :string, null: false
      add :current_monthly_payment, :decimal, precision: 18, scale: 2
      add :new_monthly_payment_low, :decimal, precision: 18, scale: 2
      add :new_monthly_payment_expected, :decimal, precision: 18, scale: 2
      add :new_monthly_payment_high, :decimal, precision: 18, scale: 2
      add :monthly_savings_low, :decimal, precision: 18, scale: 2
      add :monthly_savings_expected, :decimal, precision: 18, scale: 2
      add :monthly_savings_high, :decimal, precision: 18, scale: 2
      add :true_refinance_cost_low, :decimal, precision: 18, scale: 2
      add :true_refinance_cost_expected, :decimal, precision: 18, scale: 2
      add :true_refinance_cost_high, :decimal, precision: 18, scale: 2
      add :cash_to_close_low, :decimal, precision: 18, scale: 2
      add :cash_to_close_expected, :decimal, precision: 18, scale: 2
      add :cash_to_close_high, :decimal, precision: 18, scale: 2
      add :break_even_months_low, :integer
      add :break_even_months_expected, :integer
      add :break_even_months_high, :integer
      add :current_full_term_total_payment, :decimal, precision: 18, scale: 2
      add :current_full_term_interest_cost, :decimal, precision: 18, scale: 2
      add :new_full_term_total_payment_expected, :decimal, precision: 18, scale: 2
      add :new_full_term_interest_cost_expected, :decimal, precision: 18, scale: 2
      add :full_term_finance_cost_delta_expected, :decimal, precision: 18, scale: 2
      add :warnings, {:array, :string}, null: false, default: []
      add :assumptions, :map, null: false, default: %{}
      add :computed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:refinance_analysis_results, [:user_id])
    create index(:refinance_analysis_results, [:mortgage_id])
    create index(:refinance_analysis_results, [:refinance_scenario_id])
    create index(:refinance_analysis_results, [:computed_at])
  end
end
