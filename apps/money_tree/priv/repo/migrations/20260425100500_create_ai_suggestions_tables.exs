defmodule MoneyTree.Repo.Migrations.CreateAiSuggestionsTables do
  use Ecto.Migration

  def change do
    create table(:ai_user_preferences, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :local_ai_enabled, :boolean, null: false, default: false
      add :provider, :string, null: false, default: "ollama"
      add :ollama_base_url, :string
      add :default_model, :string
      add :allow_ai_for_categorization, :boolean, null: false, default: true
      add :allow_ai_for_budget_recommendations, :boolean, null: false, default: false
      add :allow_ai_pattern_detection, :boolean, null: false, default: false
      add :store_prompt_debug_data, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:ai_user_preferences, [:user_id])

    create table(:ai_suggestion_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :provider, :string, null: false, default: "ollama"
      add :model, :string
      add :feature, :string, null: false
      add :status, :string, null: false, default: "queued"
      add :input_scope, :map, null: false, default: %{}
      add :prompt_version, :string
      add :schema_version, :string
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :duration_ms, :integer
      add :error_code, :string
      add :error_message_safe, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ai_suggestion_runs, [:user_id, :inserted_at])
    create index(:ai_suggestion_runs, [:feature])
    create index(:ai_suggestion_runs, [:status])

    create table(:ai_suggestions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :ai_suggestion_run_id,
          references(:ai_suggestion_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :target_type, :string, null: false
      add :target_id, :binary_id
      add :suggestion_type, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :approved_payload, :map, null: false, default: %{}
      add :confidence, :decimal, precision: 5, scale: 4
      add :reason, :string
      add :evidence, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"

      add :reviewed_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      add :reviewed_at, :utc_datetime_usec
      add :applied_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ai_suggestions, [:ai_suggestion_run_id])
    create index(:ai_suggestions, [:user_id, :status])
    create index(:ai_suggestions, [:target_type, :target_id])
  end
end
