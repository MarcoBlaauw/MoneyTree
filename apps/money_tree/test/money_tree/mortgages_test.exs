defmodule MoneyTree.MortgagesTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures
  import MoneyTree.MortgagesFixtures

  alias Decimal
  alias MoneyTree.Mortgages
  alias MoneyTree.Mortgages.Mortgage

  describe "mortgage CRUD" do
    test "lists and fetches mortgages scoped to the current user" do
      user = user_fixture()
      other_user = user_fixture()

      mortgage = mortgage_fixture(user, %{property_name: "Main residence"})
      _other = mortgage_fixture(other_user, %{property_name: "Hidden residence"})

      assert [%Mortgage{id: listed_id}] = Mortgages.list_mortgages(user)
      assert listed_id == mortgage.id

      assert {:ok, %Mortgage{id: fetched_id}} = Mortgages.fetch_mortgage(user, mortgage.id)
      assert fetched_id == mortgage.id

      assert {:error, :not_found} = Mortgages.fetch_mortgage(user, "missing")

      assert {:error, :not_found} =
               Mortgages.fetch_mortgage(user, mortgage_fixture(other_user).id)
    end

    test "creates a mortgage with an escrow profile" do
      user = user_fixture()

      params = %{
        property_name: "Townhome",
        loan_type: "fha",
        current_balance: "255000.40",
        current_interest_rate: "0.0545",
        remaining_term_months: 301,
        monthly_payment_total: "1935.11",
        escrow_profile: %{
          property_tax_monthly: "220.00",
          homeowners_insurance_monthly: "95.30",
          confidence_score: "0.8000"
        }
      }

      assert {:ok, %Mortgage{} = mortgage} = Mortgages.create_mortgage(user, params)
      assert mortgage.property_name == "Townhome"
      assert mortgage.current_balance == Decimal.new("255000.40")
      assert mortgage.escrow_profile.property_tax_monthly == Decimal.new("220.00")
      assert mortgage.escrow_profile.confidence_score == Decimal.new("0.8000")
    end

    test "updates mortgage and escrow profile" do
      user = user_fixture()
      mortgage = mortgage_fixture(user)

      assert {:ok, %Mortgage{} = updated} =
               Mortgages.update_mortgage(user, mortgage, %{
                 monthly_payment_total: "3010.91",
                 escrow_profile: %{other_escrow_monthly: "45.00", confidence_score: "0.95"}
               })

      assert updated.monthly_payment_total == Decimal.new("3010.91")
      assert updated.escrow_profile.other_escrow_monthly == Decimal.new("45.00")
      assert updated.escrow_profile.confidence_score == Decimal.new("0.9500")
    end

    test "deletes mortgages only for the owner" do
      user = user_fixture()
      other = user_fixture()
      mortgage = mortgage_fixture(user)

      assert {:error, :not_found} = Mortgages.delete_mortgage(other, mortgage)
      assert {:ok, %Mortgage{}} = Mortgages.delete_mortgage(user, mortgage)
      assert {:error, :not_found} = Mortgages.fetch_mortgage(user, mortgage.id)
    end
  end
end
