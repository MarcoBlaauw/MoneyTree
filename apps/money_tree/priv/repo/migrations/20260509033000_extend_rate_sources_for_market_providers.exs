defmodule MoneyTree.Repo.Migrations.ExtendRateSourcesForMarketProviders do
  use Ecto.Migration

  def change do
    alter table(:loan_rate_sources) do
      add :update_frequency, :string
      add :reliability_score, :decimal, precision: 5, scale: 4
      add :attribution_label, :string
      add :attribution_url, :string
    end

    alter table(:loan_rate_observations) do
      add :effective_date, :date
      add :geography, :string
      add :confidence_score, :decimal, precision: 5, scale: 4
      add :notes, :text
    end

    execute(
      "UPDATE loan_rate_observations SET effective_date = observed_at::date WHERE effective_date IS NULL",
      ""
    )

    alter table(:loan_rate_observations) do
      modify :effective_date, :date, null: false
    end

    create index(:loan_rate_observations, [:effective_date])

    create unique_index(:loan_rate_observations, [:rate_source_id, :series_key, :effective_date],
             name: :loan_rate_observations_source_series_effective_date_index
           )
  end
end
