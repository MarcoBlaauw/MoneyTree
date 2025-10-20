defmodule MoneyTree.Accounts.Account do
  @moduledoc """
  Financial account belonging to a user and optionally linked to an institution.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias MoneyTree.Accounts.AccountMembership
  alias Decimal
  alias MoneyTree.Currency
  alias MoneyTree.Encrypted.Binary
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Institutions.Institution
  alias MoneyTree.Transactions.Transaction
  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "accounts" do
    field(:name, :string)
    field(:currency, :string)
    field(:type, :string)
    field(:subtype, :string)
    field(:external_id, :string)
    field(:current_balance, :decimal, default: Decimal.new("0"))
    field(:available_balance, :decimal)
    field(:limit, :decimal)
    field(:last_synced_at, :utc_datetime_usec)
    field(:encrypted_account_number, Binary)
    field(:encrypted_routing_number, Binary)
    field(:apr, :decimal)
    field(:fee_schedule, :string)
    field(:minimum_balance, :decimal)
    field(:maximum_balance, :decimal)

    belongs_to(:user, User)
    belongs_to(:institution, Institution)
    belongs_to(:institution_connection, Connection)

    has_many(:memberships, AccountMembership)

    many_to_many(:authorized_users, User,
      join_through: AccountMembership,
      join_keys: [account_id: :id, user_id: :id],
      on_replace: :delete
    )

    has_many(:transactions, Transaction)

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
      :apr,
      :fee_schedule,
      :minimum_balance,
      :maximum_balance,
      :user_id,
      :institution_id,
      :institution_connection_id
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
    |> validate_length(:fee_schedule, max: 2000)
    |> validate_decimal(:current_balance)
    |> validate_decimal(:available_balance)
    |> validate_decimal(:limit)
    |> validate_decimal(:apr, min: Decimal.new("0"), max: Decimal.new("100"))
    |> validate_decimal(:minimum_balance, min: Decimal.new("0"))
    |> validate_decimal(:maximum_balance, min: Decimal.new("0"))
    |> validate_balance_range()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:institution_id)
    |> foreign_key_constraint(:institution_connection_id)
    |> unique_constraint(:external_id, name: :accounts_user_id_external_id_index)
  end

  def with_memberships(query) do
    from(account in query,
      preload: [memberships: ^from(m in AccountMembership, preload: [:user])]
    )
  end

  def with_memberships, do: with_memberships(__MODULE__)

  def with_authorized_users(query) do
    from(account in query,
      preload: [
        authorized_users: ^from(u in User),
        memberships: ^from(m in AccountMembership, preload: [:user])
      ]
    )
  end

  def with_authorized_users, do: with_authorized_users(__MODULE__)

  defp normalize_currency(currency) when is_binary(currency) do
    currency
    |> String.trim()
    |> String.upcase()
  end

  defp normalize_currency(other), do: other

  defp validate_decimal(changeset, field, opts \\ []) do
    validate_change(changeset, field, fn ^field, value ->
      case cast_decimal(value) do
        :skip ->
          []

        :error ->
          [{field, "must be a valid decimal number"}]

        {:ok, decimal} ->
          validate_decimal_constraints(decimal, field, opts)
      end
    end)
  end

  defp validate_balance_range(changeset) do
    min_balance = get_field(changeset, :minimum_balance)
    max_balance = get_field(changeset, :maximum_balance)

    if min_balance && max_balance && Decimal.compare(max_balance, min_balance) == :lt do
      add_error(changeset, :maximum_balance, "must be greater than or equal to the minimum balance")
    else
      changeset
    end
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

  defp cast_decimal(nil), do: :skip
  defp cast_decimal(%Decimal{} = decimal), do: {:ok, decimal}

  defp cast_decimal(value) when is_binary(value) or is_number(value) do
    case Decimal.cast(value) do
      {:ok, decimal} -> {:ok, decimal}
      :error -> :error
    end
  end

  defp cast_decimal(_other), do: :error

  defp validate_decimal_constraints(decimal, field, opts) do
    []
    |> maybe_validate_min(decimal, field, Keyword.get(opts, :min))
    |> maybe_validate_max(decimal, field, Keyword.get(opts, :max))
  end

  defp maybe_validate_min(errors, _decimal, _field, nil), do: errors

  defp maybe_validate_min(errors, decimal, field, limit) do
    limit_decimal = ensure_decimal!(limit)

    case Decimal.compare(decimal, limit_decimal) do
      :lt ->
        errors ++ [{field, "must be greater than or equal to #{Decimal.to_string(limit_decimal)}"}]

      _other ->
        errors
    end
  end

  defp maybe_validate_max(errors, _decimal, _field, nil), do: errors

  defp maybe_validate_max(errors, decimal, field, limit) do
    limit_decimal = ensure_decimal!(limit)

    case Decimal.compare(decimal, limit_decimal) do
      :gt ->
        errors ++ [{field, "must be less than or equal to #{Decimal.to_string(limit_decimal)}"}]

      _other ->
        errors
    end
  end

  defp ensure_decimal!(%Decimal{} = decimal), do: decimal

  defp ensure_decimal!(value) do
    case Decimal.cast(value) do
      {:ok, decimal} -> decimal
      :error -> raise ArgumentError, "expected a decimal-compatible value, got: #{inspect(value)}"
    end
  end
end
