defmodule MoneyTree.Repo.Migrations.AddLenderQuoteToRefinanceScenarios do
  use Ecto.Migration

  def change do
    alter table(:refinance_scenarios) do
      add :lender_quote_id,
          references(:loan_lender_quotes, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:refinance_scenarios, [:lender_quote_id])
  end
end
