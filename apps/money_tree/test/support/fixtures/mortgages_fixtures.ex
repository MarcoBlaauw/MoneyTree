defmodule MoneyTree.MortgagesFixtures do
  @moduledoc """
  Helpers for creating mortgage records in tests.
  """

  alias Decimal
  alias MoneyTree.Mortgages

  def mortgage_fixture(user, attrs \\ %{}) do
    attrs = Map.new(attrs)

    params = %{
      nickname: Map.get(attrs, :nickname, "Primary home"),
      property_name: Map.get(attrs, :property_name, "Main residence"),
      street_line_1: Map.get(attrs, :street_line_1, "123 Main St"),
      city: Map.get(attrs, :city, "Austin"),
      state_region: Map.get(attrs, :state_region, "TX"),
      postal_code: Map.get(attrs, :postal_code, "78701"),
      country_code: Map.get(attrs, :country_code, "US"),
      occupancy_type: Map.get(attrs, :occupancy_type, "primary_residence"),
      loan_type: Map.get(attrs, :loan_type, "conventional"),
      servicer_name: Map.get(attrs, :servicer_name, "MoneyTree Servicing"),
      lender_name: Map.get(attrs, :lender_name, "MoneyTree Lender"),
      current_balance: Map.get(attrs, :current_balance, Decimal.new("410000.00")),
      current_interest_rate: Map.get(attrs, :current_interest_rate, Decimal.new("0.0625")),
      remaining_term_months: Map.get(attrs, :remaining_term_months, 332),
      monthly_payment_total: Map.get(attrs, :monthly_payment_total, Decimal.new("2894.11")),
      has_escrow: Map.get(attrs, :has_escrow, true),
      escrow_included_in_payment: Map.get(attrs, :escrow_included_in_payment, true),
      status: Map.get(attrs, :status, "active"),
      source: Map.get(attrs, :source, "manual_entry"),
      escrow_profile:
        Map.get(attrs, :escrow_profile, %{
          property_tax_monthly: Decimal.new("375.00"),
          homeowners_insurance_monthly: Decimal.new("140.00"),
          source: "manual_entry",
          confidence_score: Decimal.new("1.0")
        })
    }

    {:ok, mortgage} = Mortgages.create_mortgage(user, params)
    mortgage
  end
end
