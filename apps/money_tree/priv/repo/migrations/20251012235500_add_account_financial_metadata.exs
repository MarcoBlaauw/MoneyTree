defmodule MoneyTree.Repo.Migrations.AddAccountFinancialMetadata do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :apr, :decimal, precision: 8, scale: 4
      add :fee_schedule, :text
      add :minimum_balance, :decimal, precision: 18, scale: 2
      add :maximum_balance, :decimal, precision: 18, scale: 2
    end
  end
end
