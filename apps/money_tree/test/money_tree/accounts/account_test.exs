defmodule MoneyTree.Accounts.AccountTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures

  alias Decimal
  alias MoneyTree.Accounts.Account

  describe "financial metadata validations" do
    setup do
      %{user: user_fixture()}
    end

    test "accepts optional APR, fee schedule, and balance thresholds", %{user: user} do
      attrs = valid_account_attrs(user, %{
        apr: Decimal.new("4.25"),
        fee_schedule: "No monthly fee when balance stays above $500",
        minimum_balance: Decimal.new("500.00"),
        maximum_balance: Decimal.new("50000.00")
      })

      changeset = Account.changeset(%Account{}, attrs)

      assert changeset.valid?
      assert changeset.changes.apr == Decimal.new("4.25")
      assert changeset.changes.fee_schedule =~ "No monthly fee"
    end

    test "rejects APR greater than 100", %{user: user} do
      changeset = Account.changeset(%Account{}, valid_account_attrs(user, %{apr: Decimal.new("120")}))

      assert "must be less than or equal to 100" in errors_on(changeset).apr
    end

    test "rejects negative minimum balance", %{user: user} do
      changeset =
        Account.changeset(%Account{}, valid_account_attrs(user, %{minimum_balance: Decimal.new("-1")}))

      assert "must be greater than or equal to 0" in errors_on(changeset).minimum_balance
    end

    test "rejects maximum balance below minimum", %{user: user} do
      changeset =
        Account.changeset(
          %Account{},
          valid_account_attrs(user, %{
            minimum_balance: Decimal.new("500.00"),
            maximum_balance: Decimal.new("100.00")
          })
        )

      assert "must be greater than or equal to the minimum balance" in errors_on(changeset).maximum_balance
    end
  end

  defp valid_account_attrs(user, overrides) do
    Map.merge(
      %{
        name: "Test Account",
        currency: "USD",
        type: "depository",
        subtype: "checking",
        external_id: unique_account_external_id(),
        current_balance: Decimal.new("0"),
        available_balance: Decimal.new("0"),
        user_id: user.id
      },
      overrides
    )
  end
end
