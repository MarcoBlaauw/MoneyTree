defmodule MoneyTree.Repo.Migrations.AddCategoryRegistryAndObligationRecurringMetadata do
  use Ecto.Migration

  def change do
    create table(:user_categories, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :kind, :string, null: false, default: "expense"
      add :source, :string, null: false, default: "manual"
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_categories, [:user_id, "lower(name)"],
             name: :user_categories_user_id_lower_name_index
           )

    create index(:user_categories, [:user_id, :active])

    alter table(:obligations) do
      add :obligation_type, :string, null: false, default: "bill"
      add :source, :string, null: false, default: "manual"

      add :recurring_series_id,
          references(:recurring_series, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:obligations, [:obligation_type])
    create index(:obligations, [:recurring_series_id])
  end
end
