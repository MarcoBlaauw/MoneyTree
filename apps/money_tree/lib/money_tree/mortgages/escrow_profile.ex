defmodule MoneyTree.Mortgages.EscrowProfile do
  @moduledoc """
  Stored escrow assumptions and recurring escrow components for a mortgage.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Decimal
  alias MoneyTree.Mortgages.Mortgage

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "mortgage_escrow_profiles" do
    field :property_tax_monthly, :decimal
    field :homeowners_insurance_monthly, :decimal
    field :flood_insurance_monthly, :decimal
    field :other_escrow_monthly, :decimal
    field :escrow_cushion_months, :decimal
    field :expected_old_escrow_refund, :decimal
    field :annual_tax_growth_rate, :decimal
    field :annual_insurance_growth_rate, :decimal
    field :source, :string
    field :confidence_score, :decimal

    belongs_to :mortgage, Mortgage

    timestamps()
  end

  @doc false
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :mortgage_id,
      :property_tax_monthly,
      :homeowners_insurance_monthly,
      :flood_insurance_monthly,
      :other_escrow_monthly,
      :escrow_cushion_months,
      :expected_old_escrow_refund,
      :annual_tax_growth_rate,
      :annual_insurance_growth_rate,
      :source,
      :confidence_score
    ])
    |> validate_required([:mortgage_id])
    |> validate_length(:source, max: 120)
    |> validate_non_negative_decimal(:property_tax_monthly)
    |> validate_non_negative_decimal(:homeowners_insurance_monthly)
    |> validate_non_negative_decimal(:flood_insurance_monthly)
    |> validate_non_negative_decimal(:other_escrow_monthly)
    |> validate_non_negative_decimal(:escrow_cushion_months)
    |> validate_non_negative_decimal(:expected_old_escrow_refund)
    |> validate_non_negative_decimal(:annual_tax_growth_rate)
    |> validate_non_negative_decimal(:annual_insurance_growth_rate)
    |> validate_confidence_score()
    |> foreign_key_constraint(:mortgage_id)
    |> unique_constraint(:mortgage_id)
  end

  defp validate_confidence_score(changeset) do
    validate_change(changeset, :confidence_score, fn :confidence_score, value ->
      case cast_decimal(value) do
        {:ok, nil} ->
          []

        {:ok, decimal} ->
          if Decimal.compare(decimal, Decimal.new("0")) == :lt or
               Decimal.compare(decimal, Decimal.new("1")) == :gt do
            [confidence_score: "must be between 0 and 1"]
          else
            []
          end

        :error ->
          [confidence_score: "must be a valid decimal number"]
      end
    end)
  end

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
