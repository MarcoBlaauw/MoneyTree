defmodule MoneyTree.Loans.EscrowPaymentDisplayTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures
  import MoneyTree.MortgagesFixtures

  alias Decimal, as: D
  alias MoneyTree.Loans.EscrowPaymentDisplay
  alias MoneyTree.Mortgages.Mortgage

  describe "monthly_escrow_estimate/1" do
    test "uses escrow profile components when available" do
      mortgage = %Mortgage{
        escrow_profile: %MoneyTree.Mortgages.EscrowProfile{
          property_tax_monthly: D.new("375.00"),
          homeowners_insurance_monthly: D.new("140.00"),
          flood_insurance_monthly: D.new("25.00"),
          other_escrow_monthly: D.new("10.00")
        },
        monthly_payment_total: D.new("3000.00"),
        monthly_principal_interest: D.new("2200.00"),
        escrow_included_in_payment: true
      }

      assert {:ok, amount, :profile} = EscrowPaymentDisplay.monthly_escrow_estimate(mortgage)
      assert D.equal?(amount, D.new("550.00"))
    end

    test "derives escrow from total payment minus principal and interest" do
      mortgage = %Mortgage{
        monthly_payment_total: D.new("3000.00"),
        monthly_principal_interest: D.new("2200.00"),
        escrow_included_in_payment: true
      }

      assert {:ok, amount, :derived} = EscrowPaymentDisplay.monthly_escrow_estimate(mortgage)
      assert D.equal?(amount, D.new("800.00"))
    end

    test "returns unavailable when no escrow estimate exists" do
      mortgage = %Mortgage{
        monthly_payment_total: D.new("3000.00"),
        escrow_included_in_payment: false
      }

      assert EscrowPaymentDisplay.monthly_escrow_estimate(mortgage) == :unavailable
    end
  end

  test "escrow-inclusive payment range adds the monthly escrow estimate" do
    mortgage = %Mortgage{
      escrow_profile: %MoneyTree.Mortgages.EscrowProfile{
        property_tax_monthly: D.new("375.00"),
        homeowners_insurance_monthly: D.new("140.00")
      }
    }

    range = %{low: D.new("2100.00"), expected: D.new("2200.00"), high: D.new("2300.00")}

    assert %{low: low, expected: expected, high: high} =
             EscrowPaymentDisplay.payment_range(range, mortgage, true)

    assert D.equal?(low, D.new("2615.00"))
    assert D.equal?(expected, D.new("2715.00"))
    assert D.equal?(high, D.new("2815.00"))
  end

  test "monthly savings compares matching payment modes" do
    user = user_fixture()

    mortgage =
      mortgage_fixture(user, %{
        current_balance: D.new("400000.00"),
        current_interest_rate: D.new("0.0625"),
        remaining_term_months: 360,
        monthly_principal_interest: D.new("2462.87"),
        monthly_payment_total: D.new("3000.00"),
        escrow_profile: %{
          property_tax_monthly: D.new("400.00"),
          homeowners_insurance_monthly: D.new("137.13")
        }
      })

    range = %{low: D.new("2100.00"), expected: D.new("2200.00"), high: D.new("2300.00")}

    pi_savings = EscrowPaymentDisplay.monthly_savings_range(range, mortgage, false)
    full_savings = EscrowPaymentDisplay.monthly_savings_range(range, mortgage, true)

    assert D.equal?(pi_savings.expected, D.new("262.87"))
    assert D.equal?(full_savings.expected, D.new("262.87"))
  end
end
