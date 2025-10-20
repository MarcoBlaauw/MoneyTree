defmodule MoneyTree.Repo.Migrations.CreateAssets do
  use Ecto.Migration

  def change do
    create table(:assets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :asset_type, :string, null: false
      add :category, :string
      add :valuation_amount, :decimal, null: false
      add :valuation_currency, :string, null: false
      add :ownership_type, :string, null: false
      add :ownership_details, :text
      add :location, :string
      add :notes, :text
      add :acquired_on, :date
      add :last_valued_on, :date
      add :document_refs, {:array, :string}, default: [], null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:assets, [:account_id])
    create index(:assets, [:asset_type])
    create index(:assets, [:valuation_currency])
  end
end
