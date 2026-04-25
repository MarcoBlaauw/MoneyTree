defmodule MoneyTree.ManualImports.Row do
  @moduledoc """
  Parsed staging row for a manual import batch.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Decimal
  alias MoneyTree.ManualImports.Batch
  alias MoneyTree.Transactions.Transaction

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @valid_parse_statuses ~w(parsed warning error excluded committed)
  @valid_review_decisions ~w(accept exclude needs_review)
  @valid_directions ~w(income expense transfer)
  @valid_transfer_match_statuses ~w(suggested confirmed rejected auto_confirmed)

  schema "manual_import_rows" do
    field :row_index, :integer
    field :raw_row, :map, default: %{}
    field :parse_status, :string, default: "parsed"
    field :parse_errors, :map, default: %{}
    field :posted_at, :utc_datetime_usec
    field :authorized_at, :utc_datetime_usec
    field :description, :string
    field :original_description, :string
    field :merchant_name, :string
    field :amount, :decimal
    field :currency, :string, default: "USD"
    field :direction, :string
    field :external_transaction_id, :string
    field :source_reference, :string
    field :check_number, :string
    field :category_name_snapshot, :string
    field :category_rule_id, :binary_id
    field :duplicate_confidence, :decimal
    field :transfer_match_confidence, :decimal
    field :transfer_match_status, :string
    field :review_decision, :string, default: "accept"

    belongs_to :manual_import_batch, Batch
    belongs_to :duplicate_candidate_transaction, Transaction
    belongs_to :transfer_match_candidate_transaction, Transaction
    belongs_to :committed_transaction, Transaction

    timestamps()
  end

  @doc false
  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :manual_import_batch_id,
      :row_index,
      :raw_row,
      :parse_status,
      :parse_errors,
      :posted_at,
      :authorized_at,
      :description,
      :original_description,
      :merchant_name,
      :amount,
      :currency,
      :direction,
      :external_transaction_id,
      :source_reference,
      :check_number,
      :category_name_snapshot,
      :category_rule_id,
      :duplicate_candidate_transaction_id,
      :duplicate_confidence,
      :transfer_match_candidate_transaction_id,
      :transfer_match_confidence,
      :transfer_match_status,
      :review_decision,
      :committed_transaction_id
    ])
    |> validate_required([
      :manual_import_batch_id,
      :row_index,
      :parse_status,
      :review_decision,
      :currency
    ])
    |> validate_number(:row_index, greater_than_or_equal_to: 0)
    |> validate_length(:parse_status, max: 60)
    |> validate_length(:review_decision, max: 60)
    |> validate_length(:currency, is: 3)
    |> validate_length(:description, max: 255)
    |> validate_length(:original_description, max: 255)
    |> validate_length(:merchant_name, max: 160)
    |> validate_length(:direction, max: 60)
    |> validate_length(:external_transaction_id, max: 120)
    |> validate_length(:source_reference, max: 255)
    |> validate_length(:check_number, max: 60)
    |> validate_length(:category_name_snapshot, max: 120)
    |> validate_length(:transfer_match_status, max: 60)
    |> validate_inclusion(:parse_status, @valid_parse_statuses)
    |> validate_inclusion(:review_decision, @valid_review_decisions)
    |> validate_direction()
    |> validate_transfer_match_status()
    |> validate_decimal(:amount)
    |> validate_decimal(:duplicate_confidence)
    |> validate_decimal(:transfer_match_confidence)
    |> update_change(:currency, &normalize_currency/1)
    |> unique_constraint([:manual_import_batch_id, :row_index],
      name: :manual_import_rows_batch_row_index_index
    )
    |> foreign_key_constraint(:manual_import_batch_id)
    |> foreign_key_constraint(:duplicate_candidate_transaction_id)
    |> foreign_key_constraint(:transfer_match_candidate_transaction_id)
    |> foreign_key_constraint(:committed_transaction_id)
  end

  defp validate_direction(changeset) do
    validate_change(changeset, :direction, fn :direction, value ->
      cond do
        is_nil(value) -> []
        value in @valid_directions -> []
        true -> [direction: "must be one of #{Enum.join(@valid_directions, ", ")}"]
      end
    end)
  end

  defp validate_transfer_match_status(changeset) do
    validate_change(changeset, :transfer_match_status, fn :transfer_match_status, value ->
      cond do
        is_nil(value) ->
          []

        value in @valid_transfer_match_statuses ->
          []

        true ->
          [
            transfer_match_status:
              "must be one of #{Enum.join(@valid_transfer_match_statuses, ", ")}"
          ]
      end
    end)
  end

  defp validate_decimal(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        is_nil(value) ->
          []

        match?(%Decimal{}, value) ->
          []

        is_binary(value) or is_number(value) ->
          case Decimal.cast(value) do
            {:ok, _} -> []
            :error -> [{field, "must be a valid decimal number"}]
          end

        true ->
          [{field, "must be a valid decimal number"}]
      end
    end)
  end

  defp normalize_currency(currency) when is_binary(currency),
    do: currency |> String.trim() |> String.upcase()

  defp normalize_currency(other), do: other
end
