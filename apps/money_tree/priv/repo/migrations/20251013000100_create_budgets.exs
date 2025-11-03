defmodule MoneyTree.Repo.Migrations.CreateBudgets do
  use Ecto.Migration

  def change do
    create table(:budgets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :period, :string, null: false
      add :allocation_amount, :decimal, null: false
      add :currency, :string, null: false
      add :entry_type, :string, null: false
      add :variability, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:budgets, [:user_id])
    create index(:budgets, [:user_id, :period])
    create index(:budgets, [:user_id, :entry_type])
    create index(:budgets, [:user_id, :variability])
    create unique_index(:budgets, [:user_id, :period, :name], name: :budgets_user_id_period_name_index)
  end
end

