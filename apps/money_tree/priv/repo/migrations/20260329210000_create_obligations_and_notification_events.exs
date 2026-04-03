defmodule MoneyTree.Repo.Migrations.CreateObligationsAndNotificationEvents do
  use Ecto.Migration

  def change do
    create table(:alert_preferences, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :email_enabled, :boolean, null: false, default: true
      add :sms_enabled, :boolean, null: false, default: false
      add :push_enabled, :boolean, null: false, default: false
      add :dashboard_enabled, :boolean, null: false, default: true
      add :upcoming_enabled, :boolean, null: false, default: true
      add :due_today_enabled, :boolean, null: false, default: true
      add :overdue_enabled, :boolean, null: false, default: true
      add :recovered_enabled, :boolean, null: false, default: true
      add :upcoming_lead_days, :integer, null: false, default: 3
      add :resend_interval_hours, :integer, null: false, default: 24
      add :max_resends, :integer, null: false, default: 2

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:alert_preferences, [:user_id])

    create table(:obligations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :linked_funding_account_id,
          references(:accounts, type: :binary_id, on_delete: :nilify_all),
          null: false

      add :creditor_payee, :string, null: false
      add :due_day, :integer
      add :due_rule, :string, null: false, default: "calendar_day"
      add :minimum_due_amount, :decimal, precision: 18, scale: 2, null: false
      add :currency, :string, size: 3, null: false
      add :grace_period_days, :integer, null: false, default: 0
      add :alert_preferences, :map, null: false, default: %{}
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:obligations, [:user_id])
    create index(:obligations, [:linked_funding_account_id])
    create index(:obligations, [:active])

    create constraint(:obligations, :obligations_due_day_check,
             check: "(due_day IS NULL) OR (due_day >= 1 AND due_day <= 31)"
           )

    create constraint(:obligations, :obligations_grace_period_days_check,
             check: "grace_period_days >= 0"
           )

    create table(:notification_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :obligation_id, references(:obligations, type: :binary_id, on_delete: :delete_all)
      add :kind, :string, null: false
      add :status, :string, null: false
      add :severity, :string, null: false
      add :title, :string, null: false
      add :message, :text, null: false
      add :action, :string
      add :event_date, :date
      add :occurred_at, :utc_datetime_usec, null: false
      add :resolved_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}
      add :dedupe_key, :string, null: false
      add :delivery_status, :string, null: false, default: "pending"
      add :last_delivered_at, :utc_datetime_usec
      add :next_delivery_at, :utc_datetime_usec
      add :delivery_attempt_count, :integer, null: false, default: 0
      add :last_delivery_error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:notification_events, [:dedupe_key])
    create index(:notification_events, [:user_id, :kind])
    create index(:notification_events, [:obligation_id, :status])
    create index(:notification_events, [:resolved_at])
    create index(:notification_events, [:delivery_status, :next_delivery_at])

    create table(:notification_delivery_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :event_id, references(:notification_events, type: :binary_id, on_delete: :delete_all),
        null: false

      add :channel, :string, null: false
      add :adapter, :string, null: false
      add :status, :string, null: false
      add :idempotency_key, :string, null: false
      add :attempted_at, :utc_datetime_usec, null: false
      add :delivered_at, :utc_datetime_usec
      add :provider_reference, :string
      add :error_message, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:notification_delivery_attempts, [:idempotency_key])
    create index(:notification_delivery_attempts, [:event_id, :attempted_at])
  end
end
