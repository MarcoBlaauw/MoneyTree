defmodule MoneyTree.Repo.Migrations.CreateCategorizationTables do
  use Ecto.Migration

  def change do
    alter table(:transactions) do
      add :categorization_confidence, :decimal, precision: 5, scale: 4
      add :categorization_source, :string
    end

    create table(:category_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :category, :string, null: false
      add :merchant_regex, :string
      add :description_keywords, {:array, :string}, null: false, default: []
      add :min_amount, :decimal, precision: 18, scale: 2
      add :max_amount, :decimal, precision: 18, scale: 2
      add :account_types, {:array, :string}, null: false, default: []
      add :priority, :integer, null: false, default: 0
      add :confidence, :decimal, precision: 5, scale: 4
      add :source, :string, null: false, default: "rule"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:category_rules, [:user_id])
    create index(:category_rules, [:priority])

    create table(:user_category_overrides, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :transaction_id, references(:transactions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :category, :string, null: false
      add :confidence, :decimal, precision: 5, scale: 4
      add :source, :string, null: false, default: "manual"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_category_overrides, [:transaction_id])
  end
end
