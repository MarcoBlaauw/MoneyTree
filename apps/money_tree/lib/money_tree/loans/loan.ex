defmodule MoneyTree.Loans.Loan do
  @moduledoc """
  Generic non-mortgage loan baseline for Loan Center.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Decimal
  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @loan_types ~w(auto personal student other)
  @statuses ~w(active paid_off inactive archived)

  schema "loans" do
    field :loan_type, :string
    field :name, :string
    field :lender_name, :string
    field :servicer_name, :string
    field :original_loan_amount, :decimal
    field :current_balance, :decimal
    field :original_interest_rate, :decimal
    field :current_interest_rate, :decimal
    field :original_term_months, :integer
    field :remaining_term_months, :integer
    field :monthly_payment_total, :decimal
    field :collateral_description, :string
    field :status, :string, default: "active"
    field :source, :string
    field :last_reviewed_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps()
  end

  @doc false
  def changeset(loan, attrs) do
    loan
    |> cast(attrs, [
      :user_id,
      :loan_type,
      :name,
      :lender_name,
      :servicer_name,
      :original_loan_amount,
      :current_balance,
      :original_interest_rate,
      :current_interest_rate,
      :original_term_months,
      :remaining_term_months,
      :monthly_payment_total,
      :collateral_description,
      :status,
      :source,
      :last_reviewed_at
    ])
    |> validate_required([
      :user_id,
      :loan_type,
      :name,
      :current_balance,
      :current_interest_rate,
      :remaining_term_months,
      :monthly_payment_total,
      :status
    ])
    |> update_change(:loan_type, &normalize_downcase/1)
    |> update_change(:status, &normalize_downcase/1)
    |> validate_inclusion(:loan_type, @loan_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:name, min: 1, max: 160)
    |> validate_length(:lender_name, max: 160)
    |> validate_length(:servicer_name, max: 160)
    |> validate_length(:collateral_description, max: 255)
    |> validate_length(:source, max: 120)
    |> validate_number(:original_term_months, greater_than: 0)
    |> validate_number(:remaining_term_months, greater_than: 0)
    |> validate_non_negative_decimal(:original_loan_amount)
    |> validate_non_negative_decimal(:current_balance)
    |> validate_non_negative_decimal(:original_interest_rate)
    |> validate_non_negative_decimal(:current_interest_rate)
    |> validate_non_negative_decimal(:monthly_payment_total)
    |> foreign_key_constraint(:user_id)
  end

  def loan_types, do: @loan_types
  def statuses, do: @statuses

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
  defp cast_decimal(value) when is_binary(value) or is_number(value), do: Decimal.cast(value)
  defp cast_decimal(_value), do: :error
end
