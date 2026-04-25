defmodule MoneyTree.Transactions.TransferMatch do
  @moduledoc """
  Persisted link between two transactions that represent the same transfer movement.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Decimal
  alias MoneyTree.Transactions.Transaction

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @match_types ~w(checking_to_savings checking_to_credit_card checking_to_loan peer_transfer manual_link unknown)
  @statuses ~w(suggested confirmed rejected auto_confirmed broken)
  @matched_by_values ~w(system user rule import_batch)

  schema "transaction_transfer_matches" do
    field :match_type, :string, default: "unknown"
    field :status, :string, default: "suggested"
    field :confidence_score, :decimal
    field :matched_by, :string, default: "system"
    field :match_reason, :string
    field :amount_difference, :decimal
    field :date_difference_days, :integer

    belongs_to :outflow_transaction, Transaction
    belongs_to :inflow_transaction, Transaction

    timestamps()
  end

  @doc false
  def changeset(match, attrs) do
    match
    |> cast(attrs, [
      :outflow_transaction_id,
      :inflow_transaction_id,
      :match_type,
      :status,
      :confidence_score,
      :matched_by,
      :match_reason,
      :amount_difference,
      :date_difference_days
    ])
    |> validate_required([
      :outflow_transaction_id,
      :inflow_transaction_id,
      :match_type,
      :status,
      :matched_by
    ])
    |> validate_length(:match_type, max: 60)
    |> validate_length(:status, max: 60)
    |> validate_length(:matched_by, max: 60)
    |> validate_length(:match_reason, max: 400)
    |> validate_change(:match_type, &validate_match_type/2)
    |> validate_change(:status, &validate_status/2)
    |> validate_change(:matched_by, &validate_matched_by/2)
    |> validate_change(:confidence_score, &validate_decimal/2)
    |> validate_change(:amount_difference, &validate_decimal/2)
    |> validate_number(:date_difference_days, greater_than_or_equal_to: 0)
    |> validate_different_transactions()
    |> foreign_key_constraint(:outflow_transaction_id)
    |> foreign_key_constraint(:inflow_transaction_id)
    |> unique_constraint([:outflow_transaction_id, :inflow_transaction_id],
      name: :transaction_transfer_matches_outflow_inflow_index
    )
  end

  defp validate_different_transactions(changeset) do
    outflow_id = get_field(changeset, :outflow_transaction_id)
    inflow_id = get_field(changeset, :inflow_transaction_id)

    if outflow_id && inflow_id && outflow_id == inflow_id do
      add_error(changeset, :inflow_transaction_id, "must be different from outflow transaction")
    else
      changeset
    end
  end

  defp validate_match_type(:match_type, value) when value in @match_types, do: []

  defp validate_match_type(:match_type, _value),
    do: [match_type: "must be one of #{Enum.join(@match_types, ", ")}"]

  defp validate_status(:status, value) when value in @statuses, do: []

  defp validate_status(:status, _value),
    do: [status: "must be one of #{Enum.join(@statuses, ", ")}"]

  defp validate_matched_by(:matched_by, value) when value in @matched_by_values, do: []

  defp validate_matched_by(:matched_by, _value),
    do: [matched_by: "must be one of #{Enum.join(@matched_by_values, ", ")}"]

  defp validate_decimal(_field, nil), do: []
  defp validate_decimal(_field, %Decimal{}), do: []

  defp validate_decimal(field, value) do
    case Decimal.cast(value) do
      {:ok, _} -> []
      :error -> [{field, "must be a valid decimal number"}]
    end
  end
end
