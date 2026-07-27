defmodule MoneyTree.Repo.Migrations.AddCountyOrParishToMortgages do
  use Ecto.Migration

  def change do
    alter table(:mortgages) do
      add :county_or_parish, :string
    end

    create index(:mortgages, [:country_code, :state_region, :county_or_parish])
  end
end
