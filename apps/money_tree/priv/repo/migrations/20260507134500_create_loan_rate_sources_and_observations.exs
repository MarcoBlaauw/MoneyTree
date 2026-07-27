defmodule MoneyTree.Repo.Migrations.CreateLoanRateSourcesAndObservations do
  use Ecto.Migration

  def change do
    create table(:loan_rate_sources, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider_key, :string, null: false
      add :name, :string, null: false
      add :source_type, :string, null: false, default: "manual"
      add :base_url, :string
      add :enabled, :boolean, null: false, default: true
      add :requires_api_key, :boolean, null: false, default: false
      add :config, :map, null: false, default: %{}
      add :last_success_at, :utc_datetime_usec
      add :last_error_at, :utc_datetime_usec
      add :last_error_message, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:loan_rate_sources, [:provider_key])
    create index(:loan_rate_sources, [:source_type])
    create index(:loan_rate_sources, [:enabled])

    create table(:loan_rate_observations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :rate_source_id,
          references(:loan_rate_sources, type: :binary_id, on_delete: :delete_all),
          null: false

      add :provider_key, :string
      add :series_key, :string
      add :loan_type, :string, null: false
      add :product_type, :string
      add :term_months, :integer, null: false
      add :rate, :decimal, precision: 9, scale: 6, null: false
      add :apr, :decimal, precision: 9, scale: 6
      add :points, :decimal, precision: 9, scale: 4
      add :assumptions, :map, null: false, default: %{}
      add :source_url, :string
      add :published_at, :utc_datetime_usec
      add :observed_at, :utc_datetime_usec, null: false
      add :imported_at, :utc_datetime_usec, null: false
      add :raw_payload, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:loan_rate_observations, [:rate_source_id])
    create index(:loan_rate_observations, [:loan_type, :product_type, :term_months])
    create index(:loan_rate_observations, [:observed_at])
    create index(:loan_rate_observations, [:imported_at])
  end
end
