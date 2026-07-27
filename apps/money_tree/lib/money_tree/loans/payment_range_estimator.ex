defmodule MoneyTree.Loans.PaymentRangeEstimator do
  @moduledoc """
  Deterministic low/expected/high estimator for monthly payment outputs.
  """

  alias Decimal, as: D

  @default_spread D.new("0.05")

  @spec estimate(D.t() | number() | binary(), D.t() | number() | binary() | nil) ::
          %{low: D.t(), expected: D.t(), high: D.t()}
  def estimate(expected_payment, spread \\ @default_spread) do
    expected = cast_decimal!(expected_payment, "expected_payment")
    spread_decimal = cast_decimal!(spread || @default_spread, "spread")

    factor_low = D.sub(D.new("1"), spread_decimal)
    factor_high = D.add(D.new("1"), spread_decimal)

    %{
      low: expected |> D.mult(factor_low) |> D.round(2),
      expected: D.round(expected, 2),
      high: expected |> D.mult(factor_high) |> D.round(2)
    }
  end

  defp cast_decimal!(%D{} = value, _field), do: value

  defp cast_decimal!(value, field) do
    case D.cast(value) do
      {:ok, decimal} -> decimal
      :error -> raise ArgumentError, "invalid #{field}: #{inspect(value)}"
    end
  end
end
