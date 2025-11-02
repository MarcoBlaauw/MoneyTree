defmodule MoneyTree.Budgets.Budget do
  @moduledoc """
  User defined budget classification that powers spending analysis and planning tools.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Decimal
  alias MoneyTree.Currency
  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @periods ~w(weekly monthly yearly)a
  @entry_types ~w(income expense)a
  @variabilities ~w(fixed variable)a

  schema "budgets" do
    field :name, :string
    field :period, Ecto.Enum, values: @periods
    field :allocation_amount, :decimal
    field :currency, :string
    field :entry_type, Ecto.Enum, values: @entry_types
    field :variability, Ecto.Enum, values: @variabilities

    belongs_to :user, User

    timestamps()
  end

  @doc false
  def changeset(budget, attrs) do
    budget
    |> cast(attrs, [
      :name,
      :period,
      :allocation_amount,
      :currency,
      :entry_type,
      :variability,
      :user_id
    ])
    |> validate_required([
      :name,
      :period,
      :allocation_amount,
      :currency,
      :entry_type,
      :variability,
      :user_id
    ])
    |> validate_length(:name, min: 1, max: 120)
    |> update_change(:currency, &normalize_currency/1)
    |> validate_currency(:currency)
    |> validate_positive_decimal(:allocation_amount)
    |> assoc_constraint(:user)
    |> unique_constraint(:name, name: :budgets_user_id_period_name_index)
  end

  @spec periods() :: [atom()]
  def periods, do: @periods

  @spec entry_types() :: [atom()]
  def entry_types, do: @entry_types

  @spec variabilities() :: [atom()]
  def variabilities, do: @variabilities

  defp normalize_currency(currency) when is_binary(currency) do
    currency
    |> String.trim()
    |> String.upcase()
  end

  defp normalize_currency(other), do: other

  defp validate_currency(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if Currency.valid_code?(value) do
        []
      else
        [{field, "must be a valid ISO 4217 currency code"}]
      end
    end)
  end

  defp validate_positive_decimal(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      with {:ok, %Decimal{} = decimal} <- Decimal.cast(value) do
        if Decimal.compare(decimal, Decimal.new("0")) == :gt do
          []
        else
          [{field, "must be greater than zero"}]
        end
      else
        _ -> [{field, "must be a valid decimal number"}]
      end
    end)
  end
end

