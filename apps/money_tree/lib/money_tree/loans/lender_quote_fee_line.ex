defmodule MoneyTree.Loans.LenderQuoteFeeLine do
  @moduledoc """
  Individual lender quote fee line classified against modeled fee ranges.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Decimal
  alias MoneyTree.Loans.LenderQuote
  alias MoneyTree.Loans.LoanFeeType

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @classifications ~w(below_expected_range within_expected_range above_expected_range extreme_outlier missing_required_fee not_required_or_optional unknown_fee_type possible_duplicate_fee possible_junk_or_unusual_fee)
  @confidence_levels ~w(very_low low moderate high verified)

  schema "loan_lender_quote_fee_lines" do
    field :original_label, :string
    field :normalized_label, :string
    field :amount, :decimal
    field :classification, :string, default: "unknown_fee_type"
    field :confidence_level, :string, default: "low"
    field :confidence_score, :decimal
    field :required, :boolean, default: false
    field :requires_review, :boolean, default: true
    field :review_note, :string
    field :raw_payload, :map, default: %{}

    belongs_to :lender_quote, LenderQuote
    belongs_to :loan_fee_type, LoanFeeType

    timestamps()
  end

  def changeset(line, attrs) do
    line
    |> cast(attrs, [
      :lender_quote_id,
      :loan_fee_type_id,
      :original_label,
      :normalized_label,
      :amount,
      :classification,
      :confidence_level,
      :confidence_score,
      :required,
      :requires_review,
      :review_note,
      :raw_payload
    ])
    |> validate_required([
      :lender_quote_id,
      :original_label,
      :amount,
      :classification,
      :confidence_level,
      :required,
      :requires_review,
      :raw_payload
    ])
    |> put_normalized_label()
    |> put_default_map(:raw_payload)
    |> update_change(:classification, &normalize_key/1)
    |> update_change(:confidence_level, &normalize_key/1)
    |> validate_length(:original_label, min: 1, max: 160)
    |> validate_length(:normalized_label, max: 160)
    |> validate_inclusion(:classification, @classifications)
    |> validate_inclusion(:confidence_level, @confidence_levels)
    |> validate_non_negative_decimal(:amount)
    |> validate_confidence_score()
    |> validate_map(:raw_payload)
    |> foreign_key_constraint(:lender_quote_id)
    |> foreign_key_constraint(:loan_fee_type_id)
  end

  def classifications, do: @classifications

  defp put_normalized_label(changeset) do
    case get_field(changeset, :normalized_label) do
      value when is_binary(value) and value != "" ->
        changeset

      _value ->
        case get_field(changeset, :original_label) do
          value when is_binary(value) ->
            put_change(changeset, :normalized_label, normalize_label(value))

          _value ->
            changeset
        end
    end
  end

  defp normalize_label(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp normalize_key(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_key(value), do: value

  defp put_default_map(changeset, field) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, %{})
      _value -> changeset
    end
  end

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
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

  defp validate_confidence_score(changeset) do
    validate_change(changeset, :confidence_score, fn :confidence_score, value ->
      case Decimal.cast(value) do
        {:ok, decimal} ->
          if Decimal.compare(decimal, Decimal.new("0")) == :lt or
               Decimal.compare(decimal, Decimal.new("1")) == :gt,
             do: [confidence_score: "must be between 0 and 1"],
             else: []

        :error ->
          [confidence_score: "must be a valid decimal number"]
      end
    end)
  end
end
