defmodule MoneyTree.Repo.Migrations.CreateGenericLoans do
  use Ecto.Migration

  def change do
    create table(:loans, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :loan_type, :string, null: false
      add :name, :string, null: false
      add :lender_name, :string
      add :servicer_name, :string
      add :original_loan_amount, :decimal, precision: 18, scale: 2
      add :current_balance, :decimal, precision: 18, scale: 2, null: false
      add :original_interest_rate, :decimal, precision: 9, scale: 6
      add :current_interest_rate, :decimal, precision: 9, scale: 6, null: false
      add :original_term_months, :integer
      add :remaining_term_months, :integer, null: false
      add :monthly_payment_total, :decimal, precision: 18, scale: 2, null: false
      add :collateral_description, :string
      add :status, :string, null: false, default: "active"
      add :source, :string
      add :last_reviewed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:loans, [:user_id])
    create index(:loans, [:loan_type])
    create index(:loans, [:status])
  end
end
