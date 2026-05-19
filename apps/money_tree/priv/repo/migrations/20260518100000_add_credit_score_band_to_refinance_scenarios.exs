defmodule MoneyTree.Repo.Migrations.AddCreditScoreBandToRefinanceScenarios do
  use Ecto.Migration

  def change do
    alter table(:refinance_scenarios) do
      add :credit_score_band, :string
    end
  end
end
