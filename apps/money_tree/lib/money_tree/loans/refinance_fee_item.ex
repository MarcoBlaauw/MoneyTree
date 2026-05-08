defmodule MoneyTree.Loans.RefinanceFeeItem do
  @moduledoc """
  Line-item refinance cost or cash-flow timing assumption.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Decimal
  alias MoneyTree.Loans.RefinanceScenario

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @kinds ~w(fee lender_credit escrow_refund waived_fee other_credit timing_cost)

  schema "refinance_fee_items" do
    field :category, :string
    field :code, :string
    field :name, :string
    field :low_amount, :decimal
    field :expected_amount, :decimal
    field :high_amount, :decimal
    field :fixed_amount, :decimal
    field :percentage_of_loan_amount, :decimal
    field :kind, :string, default: "fee"
    field :paid_at_closing, :boolean, default: true
    field :financed, :boolean, default: false
    field :is_true_cost, :boolean, default: true
    field :is_prepaid_or_escrow, :boolean, default: false
    field :required, :boolean, default: false
    field :sort_order, :integer, default: 0
    field :notes, :string

    belongs_to :refinance_scenario, RefinanceScenario

    timestamps()
  end

  @doc false
  def changeset(fee_item, attrs) do
    fee_item
    |> cast(attrs, [
      :refinance_scenario_id,
      :category,
      :code,
      :name,
      :low_amount,
      :expected_amount,
      :high_amount,
      :fixed_amount,
      :percentage_of_loan_amount,
      :kind,
      :paid_at_closing,
      :financed,
      :is_true_cost,
      :is_prepaid_or_escrow,
      :required,
      :sort_order,
      :notes
    ])
    |> validate_required([
      :refinance_scenario_id,
      :category,
      :name,
      :kind,
      :paid_at_closing,
      :financed,
      :is_true_cost,
      :is_prepaid_or_escrow,
      :required,
      :sort_order
    ])
    |> update_change(:category, &normalize_downcase/1)
    |> update_change(:kind, &normalize_downcase/1)
    |> validate_length(:category, min: 1, max: 120)
    |> validate_length(:code, max: 80)
    |> validate_length(:name, min: 1, max: 160)
    |> validate_length(:notes, max: 2000)
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:sort_order, greater_than_or_equal_to: 0)
    |> validate_non_negative_decimal(:low_amount)
    |> validate_non_negative_decimal(:expected_amount)
    |> validate_non_negative_decimal(:high_amount)
    |> validate_non_negative_decimal(:fixed_amount)
    |> validate_non_negative_decimal(:percentage_of_loan_amount)
    |> foreign_key_constraint(:refinance_scenario_id)
  end

  def kinds, do: @kinds

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
