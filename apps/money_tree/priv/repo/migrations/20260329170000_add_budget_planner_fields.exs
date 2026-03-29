defmodule MoneyTree.Repo.Migrations.AddBudgetPlannerFields do
  use Ecto.Migration

  def change do
    alter table(:budgets) do
      add :target_mode, :string, null: false, default: "strict"
      add :minimum_amount, :decimal
      add :maximum_amount, :decimal
      add :rollover_policy, :string, null: false, default: "none"
      add :priority, :integer, null: false, default: 0
    end

    create table(:budget_revisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :budget_id, references(:budgets, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :string, null: false
      add :previous_allocation_amount, :decimal
      add :suggested_allocation_amount, :decimal
      add :explanation, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:budget_revisions, [:budget_id])
    create index(:budget_revisions, [:user_id])
    create index(:budget_revisions, [:status])
  end
end
