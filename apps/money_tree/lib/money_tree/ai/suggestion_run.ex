defmodule MoneyTree.AI.SuggestionRun do
  @moduledoc """
  Tracks one AI generation run and its lifecycle metadata.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.AI.Suggestion
  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @features ~w(categorization import_categorization budget_discovery pattern_detection)
  @statuses ~w(queued running completed failed cancelled completed_with_warnings)

  schema "ai_suggestion_runs" do
    field :provider, :string, default: "ollama"
    field :model, :string
    field :feature, :string
    field :status, :string, default: "queued"
    field :input_scope, :map, default: %{}
    field :prompt_version, :string
    field :schema_version, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :duration_ms, :integer
    field :error_code, :string
    field :error_message_safe, :string

    belongs_to :user, User
    has_many :suggestions, Suggestion, foreign_key: :ai_suggestion_run_id

    timestamps()
  end

  @doc false
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :user_id,
      :provider,
      :model,
      :feature,
      :status,
      :input_scope,
      :prompt_version,
      :schema_version,
      :started_at,
      :completed_at,
      :duration_ms,
      :error_code,
      :error_message_safe
    ])
    |> validate_required([:user_id, :provider, :feature, :status])
    |> validate_inclusion(:feature, @features)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:provider, max: 60)
    |> validate_length(:model, max: 120)
    |> validate_length(:prompt_version, max: 120)
    |> validate_length(:schema_version, max: 120)
    |> validate_length(:error_code, max: 120)
    |> validate_length(:error_message_safe, max: 500)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:user_id)
  end
end
