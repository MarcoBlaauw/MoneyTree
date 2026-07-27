defmodule MoneyTree.Loans.RefinanceCalculatorTest do
  use MoneyTree.DataCase, async: true

  alias Decimal, as: D
  alias MoneyTree.Loans.RefinanceCalculator

  test "returns monthly payment, break-even, and full-term outputs" do
    analysis =
      RefinanceCalculator.analyze(%{
        current_principal: "400000.00",
        current_rate: "0.0625",
        current_remaining_term_months: 360,
        new_principal: "406000.00",
        new_rate: "0.0550",
        new_term_months: 360,
        true_refinance_cost: "6000.00"
      })

    assert analysis.current_monthly_payment == D.new("2462.87")
    assert analysis.new_monthly_payment == D.new("2305.22")
    assert analysis.monthly_savings == D.new("157.65")

    assert analysis.monthly_savings_range == %{
             low: D.new("42.39"),
             expected: D.new("157.65"),
             high: D.new("272.91")
           }

    assert analysis.true_refinance_cost_range == %{
             low: D.new("5400.00"),
             expected: D.new("6000.00"),
             high: D.new("6600.00")
           }

    assert analysis.break_even_months == 39
    assert analysis.break_even_range == %{low: 20, expected: 39, high: 156}
    assert analysis.current_full_term_total_payment == D.new("886633.20")
    assert analysis.new_full_term_total_payment == D.new("835879.20")
    assert analysis.full_term_finance_cost_delta == D.new("-50754.00")
    assert analysis.warnings == []
  end

  test "adds warning when lower payment increases full-term finance cost" do
    analysis =
      RefinanceCalculator.analyze(%{
        current_principal: "200000.00",
        current_rate: "0.0300",
        current_remaining_term_months: 120,
        current_monthly_payment: "1931.00",
        new_principal: "210000.00",
        new_rate: "0.0200",
        new_term_months: 360,
        true_refinance_cost: "8000.00"
      })

    assert D.compare(analysis.new_monthly_payment, analysis.current_monthly_payment) == :lt
    assert D.compare(analysis.full_term_finance_cost_delta, D.new("0")) == :gt

    assert analysis.warnings == [
             "Monthly payment decreases, but full-term finance cost increases."
           ]
  end

  test "break-even is nil when monthly savings are not positive" do
    analysis =
      RefinanceCalculator.analyze(%{
        current_principal: "180000.00",
        current_rate: "0.0400",
        current_remaining_term_months: 300,
        current_monthly_payment: "950.00",
        new_principal: "180000.00",
        new_rate: "0.0600",
        new_term_months: 300,
        true_refinance_cost: "5000.00"
      })

    assert analysis.break_even_months == nil
  end

  test "separates true refinance cost from cash-to-close timing costs" do
    analysis =
      RefinanceCalculator.analyze(%{
        current_principal: "400000.00",
        current_rate: "0.0625",
        current_remaining_term_months: 360,
        new_principal: "406000.00",
        new_rate: "0.0550",
        new_term_months: 360,
        true_refinance_cost: "6000.00",
        cash_to_close_timing_cost: "4200.00"
      })

    assert analysis.true_refinance_cost == D.new("6000.00")
    assert analysis.cash_to_close_timing_cost == D.new("4200.00")

    assert analysis.true_refinance_cost_range == %{
             low: D.new("5400.00"),
             expected: D.new("6000.00"),
             high: D.new("6600.00")
           }

    assert analysis.cash_to_close_range == %{
             low: D.new("9180.00"),
             expected: D.new("10200.00"),
             high: D.new("11220.00")
           }

    assert analysis.break_even_months == 39
    assert analysis.break_even_range == %{low: 20, expected: 39, high: 156}
  end
end
