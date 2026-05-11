defmodule MoneyTree.Loans.LoanFeeJurisdictionRule do
  @moduledoc """
  Fee-specific jurisdiction override.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Decimal
  alias MoneyTree.Loans.LoanFeeJurisdictionProfile
  alias MoneyTree.Loans.LoanFeeType

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @calculation_methods ~w(fixed_amount percent_of_loan_amount fixed_plus_percent computed_prepaid_interest computed_escrow_deposit manual_only)

  schema "loan_fee_jurisdiction_rules" do
    field :amount_calculation_method, :string
    field :fixed_low_amount, :decimal
    field :fixed_expected_amount, :decimal
    field :fixed_high_amount, :decimal
    field :percent_low, :decimal
    field :percent_expected, :decimal
    field :percent_high, :decimal
    field :minimum_amount, :decimal
    field :maximum_amount, :decimal
    field :requires_local_verification, :boolean
    field :source_label, :string
    field :source_url, :string
    field :last_verified_at, :utc_datetime_usec
    field :notes, :string
    field :enabled, :boolean, default: true

    belongs_to :jurisdiction_profile, LoanFeeJurisdictionProfile
    belongs_to :loan_fee_type, LoanFeeType

    timestamps()
  end

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :jurisdiction_profile_id,
      :loan_fee_type_id,
      :amount_calculation_method,
      :fixed_low_amount,
      :fixed_expected_amount,
      :fixed_high_amount,
      :percent_low,
      :percent_expected,
      :percent_high,
      :minimum_amount,
      :maximum_amount,
      :requires_local_verification,
      :source_label,
      :source_url,
      :last_verified_at,
      :notes,
      :enabled
    ])
    |> validate_required([:jurisdiction_profile_id, :loan_fee_type_id, :enabled])
    |> update_change(:amount_calculation_method, &normalize_key/1)
    |> validate_inclusion(:amount_calculation_method, @calculation_methods)
    |> validate_non_negative_decimals()
    |> foreign_key_constraint(:jurisdiction_profile_id)
    |> foreign_key_constraint(:loan_fee_type_id)
    |> unique_constraint([:jurisdiction_profile_id, :loan_fee_type_id])
  end

  defp normalize_key(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_key(value), do: value

  defp validate_non_negative_decimals(changeset) do
    Enum.reduce(
      [
        :fixed_low_amount,
        :fixed_expected_amount,
        :fixed_high_amount,
        :percent_low,
        :percent_expected,
        :percent_high,
        :minimum_amount,
        :maximum_amount
      ],
      changeset,
      &validate_non_negative_decimal(&2, &1)
    )
  end

  defp validate_non_negative_decimal(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case Decimal.cast(value) do
        {:ok, decimal} ->
          if Decimal.compare(decimal, Decimal.new("0")) == :lt,
            do: [{field, "must be greater than or equal to 0"}],
            else: []

        :error ->
          [{field, "must be a valid decimal number"}]
      end
    end)
  end
end
