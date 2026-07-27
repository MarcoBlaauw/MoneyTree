defmodule MoneyTree.Repo.Migrations.CreateValuationProviderRuns do
  use Ecto.Migration

  def change do
    create table(:valuation_provider_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :asset_id, references(:assets, type: :binary_id, on_delete: :delete_all), null: false
      add :provider_key, :string, null: false
      add :status, :string, null: false
      add :error_message, :text
      add :requested_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
      add :duration_ms, :integer
      add :request_month, :date, null: false
      add :monthly_limit, :integer, null: false
      add :monthly_remaining, :integer, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:valuation_provider_runs, [:provider_key, :request_month, :status],
             name: :valuation_provider_runs_monthly_usage_index
           )

    create index(:valuation_provider_runs, [:asset_id, :provider_key, "requested_at DESC"],
             name: :valuation_provider_runs_asset_latest_index
           )

    create constraint(:valuation_provider_runs, :valuation_provider_runs_monthly_limit_ceiling,
             check: "monthly_limit > 0 AND monthly_limit <= 500"
           )

    create constraint(:valuation_provider_runs, :valuation_provider_runs_monthly_remaining_valid,
             check: "monthly_remaining >= 0 AND monthly_remaining <= monthly_limit"
           )
  end
end
