defmodule MoneyTree.Loans.Amortization do
  @moduledoc """
  Deterministic fixed-rate amortization helpers.
  """

  alias Decimal, as: D

  @type summary :: %{
          monthly_payment: D.t(),
          total_payment: D.t(),
          total_interest: D.t()
        }

  @type payoff_summary :: %{
          scheduled_monthly_payment: D.t(),
          extra_monthly_principal: D.t(),
          total_monthly_payment: D.t(),
          payoff_months: pos_integer(),
          total_paid: D.t(),
          total_interest: D.t(),
          interest_saved: D.t()
        }

  @spec summary(D.t() | number() | binary(), D.t() | number() | binary(), pos_integer()) ::
          summary()
  def summary(principal, annual_rate, term_months)
      when is_integer(term_months) and term_months > 0 do
    principal_decimal = cast_decimal!(principal, "principal")
    annual_rate_decimal = cast_decimal!(annual_rate, "annual_rate")
    monthly_payment = monthly_payment(principal_decimal, annual_rate_decimal, term_months)

    term_decimal = D.new(term_months)
    total_payment = monthly_payment |> D.mult(term_decimal) |> D.round(2)
    total_interest = total_payment |> D.sub(principal_decimal) |> D.round(2)

    %{
      monthly_payment: monthly_payment,
      total_payment: total_payment,
      total_interest: total_interest
    }
  end

  @spec monthly_payment(D.t() | number() | binary(), D.t() | number() | binary(), pos_integer()) ::
          D.t()
  def monthly_payment(principal, annual_rate, term_months)
      when is_integer(term_months) and term_months > 0 do
    principal_decimal = cast_decimal!(principal, "principal")
    annual_rate_decimal = cast_decimal!(annual_rate, "annual_rate")

    if D.equal?(annual_rate_decimal, D.new("0")) do
      principal_decimal
      |> D.div(D.new(term_months))
      |> D.round(2)
    else
      # Use the standard fixed-rate loan formula:
      # P * r / (1 - (1 + r)^-n)
      p = D.to_float(principal_decimal)
      r = annual_rate_decimal |> D.div(D.new("12")) |> D.to_float()
      n = term_months

      payment =
        (p * r / (1.0 - :math.pow(1.0 + r, -n)))
        |> D.from_float()
        |> D.round(2)

      payment
    end
  end

  @spec payoff_summary(
          D.t() | number() | binary(),
          D.t() | number() | binary(),
          pos_integer(),
          D.t() | number() | binary()
        ) :: payoff_summary()
  def payoff_summary(principal, annual_rate, term_months, extra_monthly_principal)
      when is_integer(term_months) and term_months > 0 do
    principal_decimal = cast_decimal!(principal, "principal")
    annual_rate_decimal = cast_decimal!(annual_rate, "annual_rate")
    extra_principal = cast_decimal!(extra_monthly_principal, "extra_monthly_principal")

    if D.compare(extra_principal, D.new("0")) == :lt do
      raise ArgumentError, "invalid extra_monthly_principal: #{inspect(extra_monthly_principal)}"
    end

    baseline = summary(principal_decimal, annual_rate_decimal, term_months)

    if D.equal?(extra_principal, D.new("0")) do
      %{
        scheduled_monthly_payment: baseline.monthly_payment,
        extra_monthly_principal: D.new("0.00"),
        total_monthly_payment: baseline.monthly_payment,
        payoff_months: term_months,
        total_paid: baseline.total_payment,
        total_interest: baseline.total_interest,
        interest_saved: D.new("0.00")
      }
    else
      simulate_payoff(principal_decimal, annual_rate_decimal, extra_principal, baseline)
    end
  end

  defp simulate_payoff(principal, annual_rate, extra_principal, baseline) do
    monthly_rate = D.div(annual_rate, D.new("12"))
    planned_payment = D.add(baseline.monthly_payment, extra_principal)

    {payoff_months, total_paid, total_interest} =
      do_simulate_payoff(principal, monthly_rate, planned_payment, 0, D.new("0"), D.new("0"))

    %{
      scheduled_monthly_payment: baseline.monthly_payment,
      extra_monthly_principal: D.round(extra_principal, 2),
      total_monthly_payment: D.round(planned_payment, 2),
      payoff_months: payoff_months,
      total_paid: D.round(total_paid, 2),
      total_interest: D.round(total_interest, 2),
      interest_saved: D.sub(baseline.total_interest, total_interest) |> D.round(2)
    }
  end

  defp do_simulate_payoff(
         balance,
         monthly_rate,
         planned_payment,
         months,
         total_paid,
         total_interest
       ) do
    if D.compare(balance, D.new("0")) == :gt do
      interest = D.mult(balance, monthly_rate) |> D.round(2)
      due = D.add(balance, interest)
      payment = D.min(planned_payment, due) |> D.round(2)
      new_balance = due |> D.sub(payment) |> D.round(2)

      do_simulate_payoff(
        new_balance,
        monthly_rate,
        planned_payment,
        months + 1,
        D.add(total_paid, payment),
        D.add(total_interest, interest)
      )
    else
      {max(months, 1), D.round(total_paid, 2), D.round(total_interest, 2)}
    end
  end

  defp cast_decimal!(%D{} = value, _field), do: value

  defp cast_decimal!(value, field) do
    case D.cast(value) do
      {:ok, decimal} -> decimal
      :error -> raise ArgumentError, "invalid #{field}: #{inspect(value)}"
    end
  end
end
