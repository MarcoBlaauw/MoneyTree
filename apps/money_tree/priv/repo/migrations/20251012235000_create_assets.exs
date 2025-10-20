defmodule MoneyTree.Repo.Migrations.CreateAssets do
  use Ecto.Migration

  def change do
    create table(:assets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :type, :string, null: false
      add :valuation_amount, :decimal, precision: 18, scale: 2, null: false, default: 0
      add :valuation_currency, :string, null: false
      add :valuation_date, :date
      add :ownership, :string
      add :location, :string
      add :documents, {:array, :string}, default: []
      add :notes, :text
      add :metadata, :map, default: %{}

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:assets, [:account_id])
    create index(:assets, [:valuation_currency])
    create index(:assets, [:type])
  end
end
