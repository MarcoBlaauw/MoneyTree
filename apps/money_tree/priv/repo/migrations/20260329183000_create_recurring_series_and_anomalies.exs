defmodule MoneyTree.Repo.Migrations.CreateRecurringSeriesAndAnomalies do
  use Ecto.Migration

  def change do
    create table(:recurring_series, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :fingerprint, :string, null: false
      add :series_key, :string, null: false
      add :cadence, :string, null: false, default: "custom"
      add :cadence_days, :integer
      add :expected_window_days, :integer, null: false, default: 3
      add :expected_amount_min, :decimal, precision: 18, scale: 2
      add :expected_amount_max, :decimal, precision: 18, scale: 2
      add :confidence, :decimal, precision: 6, scale: 4, null: false, default: 0
      add :status, :string, null: false, default: "active"
      add :last_seen_at, :utc_datetime_usec
      add :next_expected_at, :utc_datetime_usec

      add :last_transaction_id,
          references(:transactions, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:recurring_series, [:user_id, :series_key])
    create index(:recurring_series, [:account_id])
    create index(:recurring_series, [:status])
    create index(:recurring_series, [:next_expected_at])

    create table(:recurring_anomalies, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :series_id, references(:recurring_series, type: :binary_id, on_delete: :delete_all),
        null: false

      add :anomaly_type, :string, null: false
      add :status, :string, null: false, default: "open"
      add :severity, :string, null: false, default: "warning"
      add :occurred_on, :date, null: false
      add :details, :map, null: false, default: %{}
      add :detected_at, :utc_datetime_usec, null: false
      add :resolved_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:recurring_anomalies, [:series_id, :anomaly_type, :occurred_on],
             name: :recurring_anomalies_series_type_occurred_on_index
           )

    create index(:recurring_anomalies, [:status])
    create index(:recurring_anomalies, [:detected_at])
  end
end
