defmodule MoneyTree.Accounts.ManualAccountCreationTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures

  alias MoneyTree.Accounts

  test "create_manual_account/2 creates a user-owned manual account" do
    user = user_fixture()

    assert {:ok, account} =
             Accounts.create_manual_account(user, %{
               name: "Manual Checking",
               type: "depository",
               subtype: "checking",
               currency: "USD",
               current_balance: "120.50"
             })

    assert account.user_id == user.id
    assert account.manual_account
    assert account.is_internal
    assert account.include_in_cash_flow
    assert account.include_in_net_worth
    assert account.internal_account_kind == "checking"
    assert String.starts_with?(account.external_id, "manual:")
  end
end
