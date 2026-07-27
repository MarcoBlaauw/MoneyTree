defmodule MoneyTree.Loans.WarningEngine do
  @moduledoc """
  Produces explainable refinance warnings from deterministic analysis outputs.
  """

  alias Decimal, as: D

  @spec warnings(%{
          required(:current_monthly_payment) => D.t(),
          required(:new_monthly_payment) => D.t(),
          required(:full_term_finance_cost_delta) => D.t()
        }) :: [String.t()]
  def warnings(%{
        current_monthly_payment: current_monthly_payment,
        new_monthly_payment: new_monthly_payment,
        full_term_finance_cost_delta: full_term_finance_cost_delta
      }) do
    lower_payment? = D.compare(new_monthly_payment, current_monthly_payment) == :lt
    higher_full_term_cost? = D.compare(full_term_finance_cost_delta, D.new("0")) == :gt

    []
    |> maybe_add(
      lower_payment? and higher_full_term_cost?,
      "Monthly payment decreases, but full-term finance cost increases."
    )
  end

  defp maybe_add(acc, true, warning), do: [warning | acc]
  defp maybe_add(acc, false, _warning), do: acc
end
