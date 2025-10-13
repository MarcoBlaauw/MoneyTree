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

  schema "transactions" do
    field :external_id, :string
    field :amount, :decimal
    field :currency, :string
    field :type, :string
    field :posted_at, :utc_datetime_usec
    field :settled_at, :utc_datetime_usec
    field :description, :string
    field :category, :string
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
      :amount,
      :currency,
      :type,
      :posted_at,
      :settled_at,
      :description,
      :category,
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
    |> validate_length(:external_id, min: 1, max: 120)
    |> validate_length(:description, min: 1, max: 255)
    |> validate_length(:category, max: 120)
    |> validate_length(:merchant_name, max: 160)
    |> validate_change(:status, &validate_status/2)
    |> validate_decimal(:amount)
    |> foreign_key_constraint(:account_id)
    |> unique_constraint(:external_id, name: :transactions_account_id_external_id_index)
  end

  defp normalize_currency(currency) when is_binary(currency) do
    currency
    |> String.trim()
    |> String.upcase()
  end

  defp normalize_currency(other), do: other

  defp validate_status(:status, status) when status in @supported_statuses, do: []
  defp validate_status(:status, _status), do: [status: "must be one of #{Enum.join(@supported_statuses, ", ")}"]

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
