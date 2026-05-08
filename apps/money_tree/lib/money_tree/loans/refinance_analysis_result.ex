defmodule MoneyTree.Loans.RefinanceAnalysisResult do
  @moduledoc """
  Reproducible snapshot of deterministic refinance analysis output.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Loans.RefinanceScenario
  alias MoneyTree.Mortgages.Mortgage
  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "refinance_analysis_results" do
    field :analysis_version, :string
    field :current_monthly_payment, :decimal
    field :new_monthly_payment_low, :decimal
    field :new_monthly_payment_expected, :decimal
    field :new_monthly_payment_high, :decimal
    field :monthly_savings_low, :decimal
    field :monthly_savings_expected, :decimal
    field :monthly_savings_high, :decimal
    field :true_refinance_cost_low, :decimal
    field :true_refinance_cost_expected, :decimal
    field :true_refinance_cost_high, :decimal
    field :cash_to_close_low, :decimal
    field :cash_to_close_expected, :decimal
    field :cash_to_close_high, :decimal
    field :break_even_months_low, :integer
    field :break_even_months_expected, :integer
    field :break_even_months_high, :integer
    field :current_full_term_total_payment, :decimal
    field :current_full_term_interest_cost, :decimal
    field :new_full_term_total_payment_expected, :decimal
    field :new_full_term_interest_cost_expected, :decimal
    field :full_term_finance_cost_delta_expected, :decimal
    field :warnings, {:array, :string}, default: []
    field :assumptions, :map, default: %{}
    field :computed_at, :utc_datetime_usec

    belongs_to :user, User
    belongs_to :mortgage, Mortgage
    belongs_to :refinance_scenario, RefinanceScenario

    timestamps()
  end

  @doc false
  def changeset(result, attrs) do
    result
    |> cast(attrs, [
      :user_id,
      :mortgage_id,
      :refinance_scenario_id,
      :analysis_version,
      :current_monthly_payment,
      :new_monthly_payment_low,
      :new_monthly_payment_expected,
      :new_monthly_payment_high,
      :monthly_savings_low,
      :monthly_savings_expected,
      :monthly_savings_high,
      :true_refinance_cost_low,
      :true_refinance_cost_expected,
      :true_refinance_cost_high,
      :cash_to_close_low,
      :cash_to_close_expected,
      :cash_to_close_high,
      :break_even_months_low,
      :break_even_months_expected,
      :break_even_months_high,
      :current_full_term_total_payment,
      :current_full_term_interest_cost,
      :new_full_term_total_payment_expected,
      :new_full_term_interest_cost_expected,
      :full_term_finance_cost_delta_expected,
      :warnings,
      :assumptions,
      :computed_at
    ])
    |> validate_required([
      :user_id,
      :mortgage_id,
      :refinance_scenario_id,
      :analysis_version,
      :computed_at
    ])
    |> validate_length(:analysis_version, min: 1, max: 40)
    |> validate_number(:break_even_months_low, greater_than: 0)
    |> validate_number(:break_even_months_expected, greater_than: 0)
    |> validate_number(:break_even_months_high, greater_than: 0)
    |> validate_warnings()
    |> validate_assumptions()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:mortgage_id)
    |> foreign_key_constraint(:refinance_scenario_id)
  end

  defp validate_warnings(changeset) do
    validate_change(changeset, :warnings, fn :warnings, value ->
      cond do
        is_list(value) and Enum.all?(value, &is_binary/1) -> []
        true -> [warnings: "must be a list of strings"]
      end
    end)
  end

  defp validate_assumptions(changeset) do
    validate_change(changeset, :assumptions, fn :assumptions, value ->
      if is_map(value), do: [], else: [assumptions: "must be a map"]
    end)
  end
end
