defmodule MoneyTree.AI.Suggestion do
  @moduledoc """
  Individual reviewable AI suggestion produced by a suggestion run.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Decimal
  alias MoneyTree.AI.SuggestionRun
  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @target_types ~w(
    transaction
    manual_import_row
    budget
    pattern
    merchant
    obligation
    transfer_match
    category_rule
  )
  @suggestion_types ~w(
    set_category
    set_import_row_category
    create_budget
    adjust_budget
    flag_pattern
    create_rule
    mark_transfer
  )
  @statuses ~w(pending accepted edited_and_accepted rejected expired superseded failed_to_apply)

  schema "ai_suggestions" do
    field :target_type, :string
    field :target_id, :binary_id
    field :suggestion_type, :string
    field :payload, :map, default: %{}
    field :approved_payload, :map, default: %{}
    field :confidence, :decimal
    field :reason, :string
    field :evidence, :map, default: %{}
    field :status, :string, default: "pending"
    field :reviewed_at, :utc_datetime_usec
    field :applied_at, :utc_datetime_usec

    belongs_to :ai_suggestion_run, SuggestionRun
    belongs_to :user, User
    belongs_to :reviewed_by_user, User

    timestamps()
  end

  @doc false
  def changeset(suggestion, attrs) do
    suggestion
    |> cast(attrs, [
      :ai_suggestion_run_id,
      :user_id,
      :target_type,
      :target_id,
      :suggestion_type,
      :payload,
      :approved_payload,
      :confidence,
      :reason,
      :evidence,
      :status,
      :reviewed_by_user_id,
      :reviewed_at,
      :applied_at
    ])
    |> validate_required([
      :ai_suggestion_run_id,
      :user_id,
      :target_type,
      :suggestion_type,
      :status
    ])
    |> validate_inclusion(:target_type, @target_types)
    |> validate_inclusion(:suggestion_type, @suggestion_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:target_type, max: 60)
    |> validate_length(:suggestion_type, max: 120)
    |> validate_length(:reason, max: 500)
    |> validate_confidence()
    |> foreign_key_constraint(:ai_suggestion_run_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:reviewed_by_user_id)
  end

  defp validate_confidence(changeset) do
    validate_change(changeset, :confidence, fn :confidence, value ->
      cond do
        is_nil(value) ->
          []

        match?(%Decimal{}, value) ->
          validate_confidence_range(value)

        true ->
          case Decimal.cast(value) do
            {:ok, decimal} -> validate_confidence_range(decimal)
            :error -> [confidence: "must be a valid decimal between 0 and 1"]
          end
      end
    end)
  end

  defp validate_confidence_range(%Decimal{} = value) do
    min = Decimal.new("0")
    max = Decimal.new("1")

    if Decimal.compare(value, min) in [:lt] or Decimal.compare(value, max) in [:gt] do
      [confidence: "must be between 0 and 1"]
    else
      []
    end
  end
end
