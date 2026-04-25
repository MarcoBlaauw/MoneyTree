defmodule MoneyTree.Transactions.Transaction do
  @moduledoc """
  Monetary movement associated with an account, including encrypted supplemental metadata.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Decimal
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Currency
  alias MoneyTree.Encrypted.Map, as: EncryptedMap

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @supported_statuses ~w(pending posted voided reversed)
  @supported_categorization_sources ~w(provider rule manual model)
  @supported_sources ~w(unknown plaid teller manual_import user_manual pdf_extract screenshot_extract)
  @supported_transaction_kinds ~w(
    unknown
    income
    expense
    internal_transfer
    credit_card_payment
    loan_payment
    adjustment
  )

  schema "transactions" do
    field :external_id, :string
    field :source, :string, default: "unknown"
    field :source_transaction_id, :string
    field :source_reference, :string
    field :source_fingerprint, :string
    field :normalized_fingerprint, :string
    field :amount, :decimal
    field :currency, :string
    field :type, :string
    field :posted_at, :utc_datetime_usec
    field :authorized_at, :utc_datetime_usec
    field :settled_at, :utc_datetime_usec
    field :description, :string
    field :original_description, :string
    field :category, :string
    field :transaction_kind, :string, default: "unknown"
    field :excluded_from_spending, :boolean, default: false
    field :needs_review, :boolean, default: false
    field :review_reason, :string
    field :manual_import_batch_id, :binary_id
    field :manual_import_row_id, :binary_id
    field :categorization_confidence, :decimal
    field :categorization_source, :string
    field :merchant_name, :string
    field :status, :string, default: "posted"
    field :encrypted_metadata, EncryptedMap

    belongs_to :account, Account

    timestamps()
  end

  @doc false
  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [
      :external_id,
      :source,
      :source_transaction_id,
      :source_reference,
      :source_fingerprint,
      :normalized_fingerprint,
      :amount,
      :currency,
      :type,
      :posted_at,
      :authorized_at,
      :settled_at,
      :description,
      :original_description,
      :category,
      :transaction_kind,
      :excluded_from_spending,
      :needs_review,
      :review_reason,
      :manual_import_batch_id,
      :manual_import_row_id,
      :categorization_confidence,
      :categorization_source,
      :merchant_name,
      :status,
      :encrypted_metadata,
      :account_id
    ])
    |> validate_required([
      :external_id,
      :amount,
      :currency,
      :posted_at,
      :description,
      :status,
      :account_id
    ])
    |> update_change(:currency, &normalize_currency/1)
    |> validate_currency(:currency)
    |> validate_length(:source, max: 60)
    |> validate_length(:source_transaction_id, max: 120)
    |> validate_length(:source_reference, max: 255)
    |> validate_length(:source_fingerprint, max: 128)
    |> validate_length(:normalized_fingerprint, max: 128)
    |> validate_length(:external_id, min: 1, max: 120)
    |> validate_length(:description, min: 1, max: 255)
    |> validate_length(:original_description, max: 255)
    |> validate_length(:category, max: 120)
    |> validate_length(:transaction_kind, max: 60)
    |> validate_length(:review_reason, max: 400)
    |> validate_length(:merchant_name, max: 160)
    |> validate_change(:categorization_source, &validate_categorization_source/2)
    |> validate_change(:source, &validate_source/2)
    |> validate_change(:transaction_kind, &validate_transaction_kind/2)
    |> validate_change(:status, &validate_status/2)
    |> validate_decimal(:amount)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:manual_import_batch_id)
    |> foreign_key_constraint(:manual_import_row_id)
    |> unique_constraint(:external_id, name: :transactions_account_id_external_id_index)
  end

  defp normalize_currency(currency) when is_binary(currency) do
    currency
    |> String.trim()
    |> String.upcase()
  end

  defp normalize_currency(other), do: other

  defp validate_status(:status, status) when status in @supported_statuses, do: []

  defp validate_status(:status, _status),
    do: [status: "must be one of #{Enum.join(@supported_statuses, ", ")}"]

  defp validate_source(:source, source) when source in @supported_sources, do: []

  defp validate_source(:source, _source),
    do: [source: "must be one of #{Enum.join(@supported_sources, ", ")}"]

  defp validate_transaction_kind(:transaction_kind, kind)
       when kind in @supported_transaction_kinds,
       do: []

  defp validate_transaction_kind(:transaction_kind, _kind),
    do: [
      transaction_kind: "must be one of #{Enum.join(@supported_transaction_kinds, ", ")}"
    ]

  defp validate_categorization_source(:categorization_source, nil), do: []

  defp validate_categorization_source(:categorization_source, source)
       when source in @supported_categorization_sources,
       do: []

  defp validate_categorization_source(:categorization_source, _source),
    do: [
      categorization_source:
        "must be one of #{Enum.join(@supported_categorization_sources, ", ")}"
    ]

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

  defp validate_currency(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if Currency.valid_code?(value) do
        []
      else
        [{field, "must be a valid ISO 4217 currency code"}]
      end
    end)
  end
end
