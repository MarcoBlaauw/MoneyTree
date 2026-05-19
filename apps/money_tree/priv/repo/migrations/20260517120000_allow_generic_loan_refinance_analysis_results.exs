defmodule MoneyTree.Repo.Migrations.AllowGenericLoanRefinanceAnalysisResults do
  use Ecto.Migration

  def change do
    alter table(:refinance_analysis_results) do
      modify :mortgage_id, references(:mortgages, type: :binary_id, on_delete: :delete_all),
        null: true,
        from: references(:mortgages, type: :binary_id, on_delete: :delete_all)

      add :loan_id, references(:loans, type: :binary_id, on_delete: :delete_all)
    end

    create index(:refinance_analysis_results, [:loan_id])

    create constraint(:refinance_analysis_results, :refinance_analysis_results_single_owner,
             check: """
             (mortgage_id IS NOT NULL AND loan_id IS NULL) OR
             (mortgage_id IS NULL AND loan_id IS NOT NULL)
             """
           )
  end
end
