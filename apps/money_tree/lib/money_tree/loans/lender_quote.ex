defmodule MoneyTree.Loans.LenderQuote do
  @moduledoc """
  Lender-specific refinance quote stored separately from benchmark rates.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Decimal
  alias MoneyTree.Mortgages.Mortgage
  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(active expired archived converted)
  @quote_sources ~w(manual document lender_api aggregator_api imported)

  schema "loan_lender_quotes" do
    field :lender_name, :string
    field :quote_source, :string, default: "manual"
    field :quote_reference, :string
    field :loan_type, :string, default: "mortgage"
    field :product_type, :string
    field :term_months, :integer
    field :interest_rate, :decimal
    field :apr, :decimal
    field :points, :decimal
    field :lender_credit_amount, :decimal
    field :estimated_closing_costs_low, :decimal
    field :estimated_closing_costs_expected, :decimal
    field :estimated_closing_costs_high, :decimal
    field :estimated_cash_to_close_low, :decimal
    field :estimated_cash_to_close_expected, :decimal
    field :estimated_cash_to_close_high, :decimal
    field :estimated_monthly_payment_low, :decimal
    field :estimated_monthly_payment_expected, :decimal
    field :estimated_monthly_payment_high, :decimal
    field :lock_available, :boolean, default: false
    field :lock_expires_at, :utc_datetime_usec
    field :quote_expires_at, :utc_datetime_usec
    field :raw_payload, :map, default: %{}
    field :status, :string, default: "active"

    belongs_to :user, User
    belongs_to :mortgage, Mortgage

    timestamps()
  end

  @doc false
  def changeset(quote, attrs) do
    quote
    |> cast(attrs, [
      :user_id,
      :mortgage_id,
      :lender_name,
      :quote_source,
      :quote_reference,
      :loan_type,
      :product_type,
      :term_months,
      :interest_rate,
      :apr,
      :points,
      :lender_credit_amount,
      :estimated_closing_costs_low,
      :estimated_closing_costs_expected,
      :estimated_closing_costs_high,
      :estimated_cash_to_close_low,
      :estimated_cash_to_close_expected,
      :estimated_cash_to_close_high,
      :estimated_monthly_payment_low,
      :estimated_monthly_payment_expected,
      :estimated_monthly_payment_high,
      :lock_available,
      :lock_expires_at,
      :quote_expires_at,
      :raw_payload,
      :status
    ])
    |> validate_required([
      :user_id,
      :mortgage_id,
      :lender_name,
      :quote_source,
      :loan_type,
      :term_months,
      :interest_rate,
      :lock_available,
      :raw_payload,
      :status
    ])
    |> update_change(:quote_source, &normalize_downcase/1)
    |> update_change(:loan_type, &normalize_downcase/1)
    |> update_change(:status, &normalize_downcase/1)
    |> validate_length(:lender_name, min: 1, max: 160)
    |> validate_length(:quote_reference, max: 160)
    |> validate_length(:loan_type, min: 1, max: 80)
    |> validate_length(:product_type, max: 120)
    |> validate_inclusion(:quote_source, @quote_sources)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:term_months, greater_than: 0)
    |> validate_non_negative_decimal(:interest_rate)
    |> validate_non_negative_decimal(:apr)
    |> validate_non_negative_decimal(:points)
    |> validate_non_negative_decimal(:lender_credit_amount)
    |> validate_non_negative_decimal(:estimated_closing_costs_low)
    |> validate_non_negative_decimal(:estimated_closing_costs_expected)
    |> validate_non_negative_decimal(:estimated_closing_costs_high)
    |> validate_non_negative_decimal(:estimated_cash_to_close_low)
    |> validate_non_negative_decimal(:estimated_cash_to_close_expected)
    |> validate_non_negative_decimal(:estimated_cash_to_close_high)
    |> validate_non_negative_decimal(:estimated_monthly_payment_low)
    |> validate_non_negative_decimal(:estimated_monthly_payment_expected)
    |> validate_non_negative_decimal(:estimated_monthly_payment_high)
    |> validate_map(:raw_payload)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:mortgage_id)
  end

  def statuses, do: @statuses
  def quote_sources, do: @quote_sources

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end

  defp normalize_downcase(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_downcase(value), do: value

  defp validate_non_negative_decimal(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case cast_decimal(value) do
        {:ok, nil} ->
          []

        {:ok, decimal} ->
          if Decimal.compare(decimal, Decimal.new("0")) == :lt do
            [{field, "must be greater than or equal to 0"}]
          else
            []
          end

        :error ->
          [{field, "must be a valid decimal number"}]
      end
    end)
  end

  defp cast_decimal(nil), do: {:ok, nil}
  defp cast_decimal(%Decimal{} = decimal), do: {:ok, decimal}

  defp cast_decimal(value) when is_binary(value) or is_number(value) do
    Decimal.cast(value)
  end

  defp cast_decimal(_value), do: :error
end
