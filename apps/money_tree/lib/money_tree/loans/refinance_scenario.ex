defmodule MoneyTree.Loans.RefinanceScenario do
  @moduledoc """
  Persisted refinance assumptions for a mortgage-backed Loan Center scenario.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Decimal
  alias MoneyTree.Loans.LenderQuote
  alias MoneyTree.Loans.RefinanceAnalysisResult
  alias MoneyTree.Loans.RefinanceFeeItem
  alias MoneyTree.Mortgages.Mortgage
  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(draft active archived)

  schema "refinance_scenarios" do
    field :name, :string
    field :scenario_type, :string, default: "manual"
    field :product_type, :string
    field :new_term_months, :integer
    field :new_interest_rate, :decimal
    field :new_apr, :decimal
    field :new_principal_amount, :decimal
    field :cash_out_amount, :decimal
    field :cash_in_amount, :decimal
    field :roll_costs_into_loan, :boolean, default: false
    field :points, :decimal
    field :lender_credit_amount, :decimal
    field :expected_years_before_sale_or_refi, :integer
    field :closing_date_assumption, :date
    field :rate_source_type, :string
    field :status, :string, default: "draft"

    belongs_to :user, User
    belongs_to :mortgage, Mortgage
    belongs_to :lender_quote, LenderQuote
    has_many :fee_items, RefinanceFeeItem
    has_many :analysis_results, RefinanceAnalysisResult

    timestamps()
  end

  @doc false
  def changeset(scenario, attrs) do
    scenario
    |> cast(attrs, [
      :user_id,
      :mortgage_id,
      :name,
      :scenario_type,
      :product_type,
      :new_term_months,
      :new_interest_rate,
      :new_apr,
      :new_principal_amount,
      :cash_out_amount,
      :cash_in_amount,
      :roll_costs_into_loan,
      :points,
      :lender_credit_amount,
      :expected_years_before_sale_or_refi,
      :closing_date_assumption,
      :rate_source_type,
      :lender_quote_id,
      :status
    ])
    |> validate_required([
      :user_id,
      :mortgage_id,
      :name,
      :scenario_type,
      :new_term_months,
      :new_interest_rate,
      :new_principal_amount,
      :status
    ])
    |> update_change(:status, &normalize_downcase/1)
    |> update_change(:scenario_type, &normalize_downcase/1)
    |> validate_length(:name, min: 1, max: 160)
    |> validate_length(:scenario_type, min: 1, max: 80)
    |> validate_length(:product_type, max: 120)
    |> validate_length(:rate_source_type, max: 120)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:new_term_months, greater_than: 0)
    |> validate_number(:expected_years_before_sale_or_refi, greater_than: 0)
    |> validate_non_negative_decimal(:new_interest_rate)
    |> validate_non_negative_decimal(:new_apr)
    |> validate_non_negative_decimal(:new_principal_amount)
    |> validate_non_negative_decimal(:cash_out_amount)
    |> validate_non_negative_decimal(:cash_in_amount)
    |> validate_non_negative_decimal(:points)
    |> validate_non_negative_decimal(:lender_credit_amount)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:mortgage_id)
  end

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

  defp cast_decimal(value) when is_binary(value) or is_number(value) do
    Decimal.cast(value)
  end

  defp cast_decimal(_value), do: :error
end
