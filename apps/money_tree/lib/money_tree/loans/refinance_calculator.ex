defmodule MoneyTree.Loans.RefinanceCalculator do
  @moduledoc """
  Deterministic refinance analysis for monthly payment, break-even, and full-term cost.
  """

  alias Decimal, as: D
  alias MoneyTree.Loans.Amortization
  alias MoneyTree.Loans.CostRangeEstimator
  alias MoneyTree.Loans.PaymentRangeEstimator
  alias MoneyTree.Loans.WarningEngine

  @type analysis :: %{
          current_monthly_payment: D.t(),
          new_monthly_payment: D.t(),
          payment_range: %{low: D.t(), expected: D.t(), high: D.t()},
          monthly_savings: D.t(),
          monthly_savings_range: %{low: D.t(), expected: D.t(), high: D.t()},
          true_refinance_cost: D.t(),
          true_refinance_cost_range: %{low: D.t(), expected: D.t(), high: D.t()},
          cash_to_close_timing_cost: D.t(),
          cash_to_close_range: %{low: D.t(), expected: D.t(), high: D.t()},
          break_even_months: pos_integer() | nil,
          break_even_range: %{
            low: pos_integer() | nil,
            expected: pos_integer() | nil,
            high: pos_integer() | nil
          },
          current_full_term_total_payment: D.t(),
          current_full_term_interest_cost: D.t(),
          new_full_term_total_payment: D.t(),
          new_full_term_interest_cost: D.t(),
          full_term_finance_cost_delta: D.t(),
          warnings: [String.t()]
        }

  @spec analyze(map()) :: analysis()
  def analyze(params) when is_map(params) do
    current_principal = cast_decimal!(Map.fetch!(params, :current_principal), "current_principal")
    current_rate = cast_decimal!(Map.fetch!(params, :current_rate), "current_rate")
    current_term = Map.fetch!(params, :current_remaining_term_months)
    new_principal = cast_decimal!(Map.fetch!(params, :new_principal), "new_principal")
    new_rate = cast_decimal!(Map.fetch!(params, :new_rate), "new_rate")
    new_term = Map.fetch!(params, :new_term_months)

    true_refinance_cost =
      cast_decimal!(Map.fetch!(params, :true_refinance_cost), "true_refinance_cost")

    cash_to_close_timing_cost = optional_decimal(params, :cash_to_close_timing_cost, "0")

    validate_term!(current_term, :current_remaining_term_months)
    validate_term!(new_term, :new_term_months)

    current_monthly_payment =
      params
      |> Map.get(:current_monthly_payment)
      |> case do
        nil -> Amortization.monthly_payment(current_principal, current_rate, current_term)
        value -> cast_decimal!(value, "current_monthly_payment") |> D.round(2)
      end

    current_summary = Amortization.summary(current_principal, current_rate, current_term)
    new_summary = Amortization.summary(new_principal, new_rate, new_term)
    new_monthly_payment = new_summary.monthly_payment

    monthly_savings =
      current_monthly_payment
      |> D.sub(new_monthly_payment)
      |> D.round(2)

    payment_range = PaymentRangeEstimator.estimate(new_monthly_payment)
    monthly_savings_range = compute_monthly_savings_range(current_monthly_payment, payment_range)
    true_refinance_cost_range = CostRangeEstimator.estimate(true_refinance_cost)

    cash_to_close_range =
      compute_cash_to_close_range(true_refinance_cost_range, cash_to_close_timing_cost)

    break_even_months = compute_break_even_months(true_refinance_cost, monthly_savings)
    break_even_range = compute_break_even_range(true_refinance_cost_range, monthly_savings_range)

    new_full_term_total_payment =
      new_summary.total_payment
      |> D.add(true_refinance_cost)
      |> D.round(2)

    full_term_finance_cost_delta =
      new_full_term_total_payment
      |> D.sub(current_summary.total_payment)
      |> D.round(2)

    warnings =
      WarningEngine.warnings(%{
        current_monthly_payment: current_monthly_payment,
        new_monthly_payment: new_monthly_payment,
        full_term_finance_cost_delta: full_term_finance_cost_delta
      })
      |> Enum.reverse()

    %{
      current_monthly_payment: current_monthly_payment,
      new_monthly_payment: new_monthly_payment,
      payment_range: payment_range,
      monthly_savings: monthly_savings,
      monthly_savings_range: monthly_savings_range,
      true_refinance_cost: D.round(true_refinance_cost, 2),
      true_refinance_cost_range: true_refinance_cost_range,
      cash_to_close_timing_cost: D.round(cash_to_close_timing_cost, 2),
      cash_to_close_range: cash_to_close_range,
      break_even_months: break_even_months,
      break_even_range: break_even_range,
      current_full_term_total_payment: current_summary.total_payment,
      current_full_term_interest_cost: current_summary.total_interest,
      new_full_term_total_payment: new_full_term_total_payment,
      new_full_term_interest_cost: new_summary.total_interest,
      full_term_finance_cost_delta: full_term_finance_cost_delta,
      warnings: warnings
    }
  end

  defp compute_break_even_months(_cost, savings) when savings == nil, do: nil

  defp compute_break_even_months(cost, savings) do
    if D.compare(savings, D.new("0")) == :gt do
      cost_float = D.to_float(cost)
      savings_float = D.to_float(savings)
      max(1, ceil(cost_float / savings_float))
    else
      nil
    end
  end

  defp compute_monthly_savings_range(current_monthly_payment, payment_range) do
    %{
      low: current_monthly_payment |> D.sub(payment_range.high) |> D.round(2),
      expected: current_monthly_payment |> D.sub(payment_range.expected) |> D.round(2),
      high: current_monthly_payment |> D.sub(payment_range.low) |> D.round(2)
    }
  end

  defp compute_cash_to_close_range(true_refinance_cost_range, cash_to_close_timing_cost) do
    timing_cost_range = CostRangeEstimator.estimate(cash_to_close_timing_cost)

    %{
      low: true_refinance_cost_range.low |> D.add(timing_cost_range.low) |> D.round(2),
      expected:
        true_refinance_cost_range.expected |> D.add(timing_cost_range.expected) |> D.round(2),
      high: true_refinance_cost_range.high |> D.add(timing_cost_range.high) |> D.round(2)
    }
  end

  defp compute_break_even_range(true_refinance_cost_range, monthly_savings_range) do
    %{
      low: compute_break_even_months(true_refinance_cost_range.low, monthly_savings_range.high),
      expected:
        compute_break_even_months(
          true_refinance_cost_range.expected,
          monthly_savings_range.expected
        ),
      high: compute_break_even_months(true_refinance_cost_range.high, monthly_savings_range.low)
    }
  end

  defp validate_term!(value, _field) when is_integer(value) and value > 0, do: value

  defp validate_term!(value, field) do
    raise ArgumentError, "invalid #{field}: #{inspect(value)}"
  end

  defp cast_decimal!(%D{} = value, _field), do: value

  defp cast_decimal!(value, field) do
    case D.cast(value) do
      {:ok, decimal} -> decimal
      :error -> raise ArgumentError, "invalid #{field}: #{inspect(value)}"
    end
  end

  defp optional_decimal(params, key, default) do
    params
    |> Map.get(key, default)
    |> cast_decimal!(Atom.to_string(key))
  end
end
