defmodule MoneyTree.Loans.AmortizationTest do
  use MoneyTree.DataCase, async: true

  alias Decimal, as: D
  alias MoneyTree.Loans.Amortization

  test "computes fixed-rate monthly payment and full-term totals" do
    summary = Amortization.summary("400000.00", "0.0625", 360)

    assert summary.monthly_payment == D.new("2462.87")
    assert summary.total_payment == D.new("886633.20")
    assert summary.total_interest == D.new("486633.20")
  end

  test "handles zero-interest loans deterministically" do
    summary = Amortization.summary("12000.00", "0.00", 24)

    assert summary.monthly_payment == D.new("500.00")
    assert summary.total_payment == D.new("12000.00")
    assert summary.total_interest == D.new("0.00")
  end

  test "payoff summary without extra principal matches amortization summary" do
    summary = Amortization.summary("400000.00", "0.0625", 360)
    payoff = Amortization.payoff_summary("400000.00", "0.0625", 360, "0.00")

    assert payoff.scheduled_monthly_payment == summary.monthly_payment
    assert payoff.total_monthly_payment == summary.monthly_payment
    assert payoff.payoff_months == 360
    assert payoff.total_paid == summary.total_payment
    assert payoff.total_interest == summary.total_interest
    assert payoff.interest_saved == D.new("0.00")
  end

  test "extra monthly principal reduces payoff months and total interest" do
    baseline = Amortization.payoff_summary("400000.00", "0.0625", 360, "0.00")
    accelerated = Amortization.payoff_summary("400000.00", "0.0625", 360, "500.00")

    assert accelerated.scheduled_monthly_payment == D.new("2462.87")
    assert accelerated.extra_monthly_principal == D.new("500.00")
    assert accelerated.total_monthly_payment == D.new("2962.87")
    assert accelerated.payoff_months < baseline.payoff_months
    assert D.compare(accelerated.total_interest, baseline.total_interest) == :lt
    assert D.compare(accelerated.interest_saved, D.new("0")) == :gt
  end

  test "payoff summary handles zero-interest loans with extra principal" do
    payoff = Amortization.payoff_summary("12000.00", "0.00", 24, "100.00")

    assert payoff.scheduled_monthly_payment == D.new("500.00")
    assert payoff.total_monthly_payment == D.new("600.00")
    assert payoff.payoff_months == 20
    assert payoff.total_paid == D.new("12000.00")
    assert payoff.total_interest == D.new("0.00")
    assert payoff.interest_saved == D.new("0.00")
  end
end
