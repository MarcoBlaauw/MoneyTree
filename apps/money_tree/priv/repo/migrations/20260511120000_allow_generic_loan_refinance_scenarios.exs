defmodule MoneyTree.Repo.Migrations.AllowGenericLoanRefinanceScenarios do
  use Ecto.Migration

  def change do
    alter table(:refinance_scenarios) do
      modify :mortgage_id, references(:mortgages, type: :binary_id, on_delete: :delete_all),
        null: true,
        from: references(:mortgages, type: :binary_id, on_delete: :delete_all)

      add :loan_id, references(:loans, type: :binary_id, on_delete: :delete_all)
    end

    create index(:refinance_scenarios, [:loan_id])

    create constraint(:refinance_scenarios, :refinance_scenarios_single_owner,
             check: """
             (mortgage_id IS NOT NULL AND loan_id IS NULL) OR
             (mortgage_id IS NULL AND loan_id IS NOT NULL)
             """
           )
  end
end
