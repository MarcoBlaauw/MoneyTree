defmodule MoneyTree.Repo.Migrations.AddStateRegionToGenericLoans do
  use Ecto.Migration

  def change do
    alter table(:loans) do
      add :state_region, :string
    end
  end
end
