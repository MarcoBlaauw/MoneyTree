defmodule MoneyTree.Repo.Migrations.CreateLoanAlertRules do
  use Ecto.Migration

  def change do
    create table(:loan_alert_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :mortgage_id, references(:mortgages, type: :binary_id, on_delete: :delete_all),
        null: false

      add :loan_id, :binary_id
      add :name, :string, null: false
      add :kind, :string, null: false
      add :active, :boolean, null: false, default: true
      add :threshold_config, :map, null: false, default: %{}
      add :delivery_preferences, :map, null: false, default: %{}
      add :last_evaluated_at, :utc_datetime_usec
      add :last_triggered_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:loan_alert_rules, [:user_id])
    create index(:loan_alert_rules, [:mortgage_id])
    create index(:loan_alert_rules, [:active])
    create index(:loan_alert_rules, [:kind])
  end
end
