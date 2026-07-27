defmodule MoneyTree.Repo.Migrations.CreateLoanLenderQuotes do
  use Ecto.Migration

  def change do
    create table(:loan_lender_quotes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :mortgage_id, references(:mortgages, type: :binary_id, on_delete: :delete_all),
        null: false

      add :lender_name, :string, null: false
      add :quote_source, :string, null: false, default: "manual"
      add :quote_reference, :string
      add :loan_type, :string, null: false, default: "mortgage"
      add :product_type, :string
      add :term_months, :integer, null: false
      add :interest_rate, :decimal, precision: 9, scale: 6, null: false
      add :apr, :decimal, precision: 9, scale: 6
      add :points, :decimal, precision: 9, scale: 4
      add :lender_credit_amount, :decimal, precision: 18, scale: 2
      add :estimated_closing_costs_low, :decimal, precision: 18, scale: 2
      add :estimated_closing_costs_expected, :decimal, precision: 18, scale: 2
      add :estimated_closing_costs_high, :decimal, precision: 18, scale: 2
      add :estimated_cash_to_close_low, :decimal, precision: 18, scale: 2
      add :estimated_cash_to_close_expected, :decimal, precision: 18, scale: 2
      add :estimated_cash_to_close_high, :decimal, precision: 18, scale: 2
      add :estimated_monthly_payment_low, :decimal, precision: 18, scale: 2
      add :estimated_monthly_payment_expected, :decimal, precision: 18, scale: 2
      add :estimated_monthly_payment_high, :decimal, precision: 18, scale: 2
      add :lock_available, :boolean, null: false, default: false
      add :lock_expires_at, :utc_datetime_usec
      add :quote_expires_at, :utc_datetime_usec
      add :raw_payload, :map, null: false, default: %{}
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:loan_lender_quotes, [:user_id])
    create index(:loan_lender_quotes, [:mortgage_id])
    create index(:loan_lender_quotes, [:status])
    create index(:loan_lender_quotes, [:quote_expires_at])
  end
end
