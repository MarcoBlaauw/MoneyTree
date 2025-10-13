defmodule MoneyTree.Accounts.Account do
  @moduledoc """
  Financial account belonging to a user and optionally linked to an institution.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Decimal
  alias MoneyTree.Currency
  alias MoneyTree.Encrypted.Binary
  alias MoneyTree.Institutions.Institution
  alias MoneyTree.Transactions.Transaction
  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "accounts" do
    field :name, :string
    field :currency, :string
    field :type, :string
    field :subtype, :string
    field :external_id, :string
    field :current_balance, :decimal, default: Decimal.new("0")
    field :available_balance, :decimal
    field :limit, :decimal
    field :last_synced_at, :utc_datetime_usec
    field :encrypted_account_number, Binary
    field :encrypted_routing_number, Binary

    belongs_to :user, User
    belongs_to :institution, Institution

    has_many :transactions, Transaction

    timestamps()
  end

  @doc false
  def changeset(account, attrs) do
    account
    |> cast(attrs, [
      :name,
      :currency,
      :type,
      :subtype,
      :external_id,
      :current_balance,
      :available_balance,
      :limit,
      :last_synced_at,
      :encrypted_account_number,
      :encrypted_routing_number,
      :user_id,
      :institution_id
    ])
    |> validate_required([
      :name,
      :currency,
      :type,
      :external_id,
      :current_balance,
      :user_id
    ])
    |> update_change(:currency, &normalize_currency/1)
    |> validate_currency(:currency)
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:type, min: 1, max: 60)
    |> validate_length(:subtype, max: 60)
    |> validate_length(:external_id, max: 120)
    |> validate_decimal(:current_balance)
    |> validate_decimal(:available_balance)
    |> validate_decimal(:limit)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:institution_id)
    |> unique_constraint(:external_id, name: :accounts_user_id_external_id_index)
  end

  defp normalize_currency(currency) when is_binary(currency) do
    currency
    |> String.trim()
    |> String.upcase()
  end

  defp normalize_currency(other), do: other

  defp validate_decimal(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        is_nil(value) ->
          []

        match?(%Decimal{}, value) ->
          []

        is_binary(value) or is_number(value) ->
          case Decimal.cast(value) do
            {:ok, _decimal} -> []
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
