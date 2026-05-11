defmodule MoneyTree.Loans.LoanFeeType do
  @moduledoc """
  Canonical fee definition used for prediction and quote review.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Decimal
  alias MoneyTree.Loans.LoanFeeJurisdictionRule

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @loan_types ~w(mortgage auto personal student heloc credit_card_balance_transfer other)
  @transaction_types ~w(purchase refinance cash_out_refinance rate_term_refinance new_loan loan_modification balance_transfer)
  @trid_sections ~w(origination_charges services_cannot_shop_for services_can_shop_for taxes_and_government_fees prepaids initial_escrow_payment other lender_credits payoffs_and_payments not_applicable)
  @tolerance_buckets ~w(zero_tolerance ten_percent_aggregate no_limit_best_information not_applicable unknown)
  @finance_charge_treatments ~w(included excluded conditional unknown)
  @calculation_methods ~w(fixed_amount percent_of_loan_amount fixed_plus_percent computed_prepaid_interest computed_escrow_deposit manual_only)
  @confidence_levels ~w(very_low low moderate high verified)

  schema "loan_fee_types" do
    field :loan_type, :string
    field :transaction_type, :string
    field :code, :string
    field :display_name, :string
    field :description, :string
    field :aliases, {:array, :string}, default: []
    field :trid_section, :string, default: "not_applicable"
    field :tolerance_bucket, :string, default: "unknown"
    field :finance_charge_treatment, :string, default: "unknown"
    field :apr_affecting, :boolean, default: false
    field :points_and_fees_included, :boolean, default: false
    field :high_cost_included, :boolean, default: false
    field :is_true_cost, :boolean, default: true
    field :is_timing_cost, :boolean, default: false
    field :is_offset, :boolean, default: false
    field :is_required, :boolean, default: false
    field :is_optional, :boolean, default: false
    field :is_shoppable, :boolean, default: false
    field :is_lender_controlled, :boolean, default: false
    field :is_third_party, :boolean, default: false
    field :is_government_fee, :boolean, default: false
    field :is_state_localized, :boolean, default: false
    field :requires_local_verification, :boolean, default: false
    field :credit_score_sensitive, :boolean, default: false
    field :amount_calculation_method, :string
    field :fixed_low_amount, :decimal
    field :fixed_expected_amount, :decimal
    field :fixed_high_amount, :decimal
    field :percent_low, :decimal
    field :percent_expected, :decimal
    field :percent_high, :decimal
    field :minimum_amount, :decimal
    field :maximum_amount, :decimal
    field :warning_low_threshold_amount, :decimal
    field :warning_high_threshold_amount, :decimal
    field :extreme_high_threshold_amount, :decimal
    field :warning_low_threshold_percent, :decimal
    field :warning_high_threshold_percent, :decimal
    field :extreme_high_threshold_percent, :decimal
    field :confidence_level, :string, default: "low"
    field :source_label, :string
    field :source_url, :string
    field :last_verified_at, :utc_datetime_usec
    field :enabled, :boolean, default: true
    field :sort_order, :integer, default: 0
    field :notes, :string

    has_many :jurisdiction_rules, LoanFeeJurisdictionRule

    timestamps()
  end

  def changeset(fee_type, attrs) do
    fee_type
    |> cast(attrs, [
      :loan_type,
      :transaction_type,
      :code,
      :display_name,
      :description,
      :aliases,
      :trid_section,
      :tolerance_bucket,
      :finance_charge_treatment,
      :apr_affecting,
      :points_and_fees_included,
      :high_cost_included,
      :is_true_cost,
      :is_timing_cost,
      :is_offset,
      :is_required,
      :is_optional,
      :is_shoppable,
      :is_lender_controlled,
      :is_third_party,
      :is_government_fee,
      :is_state_localized,
      :requires_local_verification,
      :credit_score_sensitive,
      :amount_calculation_method,
      :fixed_low_amount,
      :fixed_expected_amount,
      :fixed_high_amount,
      :percent_low,
      :percent_expected,
      :percent_high,
      :minimum_amount,
      :maximum_amount,
      :warning_low_threshold_amount,
      :warning_high_threshold_amount,
      :extreme_high_threshold_amount,
      :warning_low_threshold_percent,
      :warning_high_threshold_percent,
      :extreme_high_threshold_percent,
      :confidence_level,
      :source_label,
      :source_url,
      :last_verified_at,
      :enabled,
      :sort_order,
      :notes
    ])
    |> validate_required([
      :loan_type,
      :transaction_type,
      :code,
      :display_name,
      :trid_section,
      :tolerance_bucket,
      :finance_charge_treatment,
      :amount_calculation_method,
      :confidence_level,
      :enabled,
      :sort_order
    ])
    |> normalize_fields()
    |> validate_inclusion(:loan_type, @loan_types)
    |> validate_inclusion(:transaction_type, @transaction_types)
    |> validate_inclusion(:trid_section, @trid_sections)
    |> validate_inclusion(:tolerance_bucket, @tolerance_buckets)
    |> validate_inclusion(:finance_charge_treatment, @finance_charge_treatments)
    |> validate_inclusion(:amount_calculation_method, @calculation_methods)
    |> validate_inclusion(:confidence_level, @confidence_levels)
    |> validate_length(:code, min: 1, max: 120)
    |> validate_length(:display_name, min: 1, max: 160)
    |> validate_length(:source_url, max: 500)
    |> validate_number(:sort_order, greater_than_or_equal_to: 0)
    |> validate_non_negative_decimals()
    |> unique_constraint([:loan_type, :transaction_type, :code])
  end

  def confidence_levels, do: @confidence_levels
  def loan_types, do: @loan_types
  def transaction_types, do: @transaction_types
  def calculation_methods, do: @calculation_methods

  defp normalize_fields(changeset) do
    changeset
    |> update_change(:loan_type, &normalize_key/1)
    |> update_change(:transaction_type, &normalize_key/1)
    |> update_change(:code, &normalize_key/1)
    |> update_change(:trid_section, &normalize_key/1)
    |> update_change(:tolerance_bucket, &normalize_key/1)
    |> update_change(:finance_charge_treatment, &normalize_key/1)
    |> update_change(:amount_calculation_method, &normalize_key/1)
    |> update_change(:confidence_level, &normalize_key/1)
    |> update_change(:aliases, fn aliases ->
      aliases
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    end)
  end

  defp normalize_key(value) when is_binary(value) do
    value |> String.trim() |> String.downcase()
  end

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
        :maximum_amount,
        :warning_low_threshold_amount,
        :warning_high_threshold_amount,
        :extreme_high_threshold_amount,
        :warning_low_threshold_percent,
        :warning_high_threshold_percent,
        :extreme_high_threshold_percent
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
