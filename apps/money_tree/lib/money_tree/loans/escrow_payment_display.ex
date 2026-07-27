defmodule MoneyTree.Loans.EscrowPaymentDisplay do
  @moduledoc """
  Display-only helpers for showing mortgage payments with optional recurring escrow.

  These helpers do not change refinance finance math. Escrow is presented as a
  recurring tax/insurance pass-through estimate, not as a refinance fee.
  """

  alias Decimal, as: D
  alias MoneyTree.Loans.Amortization
  alias MoneyTree.Mortgages.EscrowProfile
  alias MoneyTree.Mortgages.Mortgage

  @zero D.new("0")

  @spec monthly_escrow_estimate(Mortgage.t()) :: {:ok, D.t(), :profile | :derived} | :unavailable
  def monthly_escrow_estimate(%Mortgage{escrow_profile: %EscrowProfile{} = profile} = mortgage) do
    [
      profile.property_tax_monthly,
      profile.homeowners_insurance_monthly,
      profile.flood_insurance_monthly,
      profile.other_escrow_monthly
    ]
    |> Enum.reduce(@zero, fn value, acc -> D.add(acc, decimal_or_zero(value)) end)
    |> D.round(2)
    |> case do
      amount ->
        if D.compare(amount, @zero) == :gt do
          {:ok, amount, :profile}
        else
          derived_escrow_estimate(mortgage)
        end
    end
  end

  def monthly_escrow_estimate(%Mortgage{} = mortgage), do: derived_escrow_estimate(mortgage)

  @spec principal_interest_payment(Mortgage.t()) :: D.t()
  def principal_interest_payment(%Mortgage{monthly_principal_interest: %D{} = payment}) do
    D.round(payment, 2)
  end

  def principal_interest_payment(%Mortgage{} = mortgage) do
    cond do
      decimal_present?(mortgage.current_balance) &&
        decimal_present?(mortgage.current_interest_rate) &&
        is_integer(mortgage.remaining_term_months) &&
          mortgage.remaining_term_months > 0 ->
        Amortization.monthly_payment(
          mortgage.current_balance,
          mortgage.current_interest_rate,
          mortgage.remaining_term_months
        )

      decimal_present?(mortgage.monthly_payment_total) ->
        D.round(mortgage.monthly_payment_total, 2)

      true ->
        @zero
    end
  end

  @spec current_payment(Mortgage.t(), boolean()) :: D.t()
  def current_payment(%Mortgage{} = mortgage, false), do: principal_interest_payment(mortgage)

  def current_payment(%Mortgage{} = mortgage, true) do
    cond do
      mortgage.escrow_included_in_payment && decimal_present?(mortgage.monthly_payment_total) ->
        D.round(mortgage.monthly_payment_total, 2)

      match?({:ok, _, _}, monthly_escrow_estimate(mortgage)) ->
        {:ok, escrow, _source} = monthly_escrow_estimate(mortgage)
        mortgage |> principal_interest_payment() |> D.add(escrow) |> D.round(2)

      true ->
        principal_interest_payment(mortgage)
    end
  end

  @spec payment_range(map(), Mortgage.t(), boolean()) :: map()
  def payment_range(range, %Mortgage{} = mortgage, true) do
    case monthly_escrow_estimate(mortgage) do
      {:ok, escrow, _source} ->
        add_to_range(range, escrow)

      :unavailable ->
        range
    end
  end

  def payment_range(range, %Mortgage{}, false), do: range

  @spec monthly_savings_range(map(), Mortgage.t(), boolean()) :: map()
  def monthly_savings_range(payment_range, %Mortgage{} = mortgage, include_escrow?) do
    current_payment = current_payment(mortgage, include_escrow?)
    displayed_range = payment_range(payment_range, mortgage, include_escrow?)

    %{
      low: current_payment |> D.sub(displayed_range.high) |> D.round(2),
      expected: current_payment |> D.sub(displayed_range.expected) |> D.round(2),
      high: current_payment |> D.sub(displayed_range.low) |> D.round(2)
    }
  end

  @spec add_to_range(map(), D.t()) :: map()
  def add_to_range(range, amount) do
    %{
      low: range.low |> D.add(amount) |> D.round(2),
      expected: range.expected |> D.add(amount) |> D.round(2),
      high: range.high |> D.add(amount) |> D.round(2)
    }
  end

  defp derived_escrow_estimate(%Mortgage{
         escrow_included_in_payment: true,
         monthly_payment_total: %D{} = total,
         monthly_principal_interest: %D{} = principal_interest
       }) do
    total
    |> D.sub(principal_interest)
    |> D.round(2)
    |> case do
      amount ->
        if D.compare(amount, @zero) == :gt, do: {:ok, amount, :derived}, else: :unavailable
    end
  end

  defp derived_escrow_estimate(_mortgage), do: :unavailable

  defp decimal_or_zero(%D{} = value), do: value
  defp decimal_or_zero(_value), do: @zero

  defp decimal_present?(%D{}), do: true
  defp decimal_present?(_value), do: false
end
