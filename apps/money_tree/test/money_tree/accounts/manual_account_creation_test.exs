defmodule MoneyTree.Accounts.ManualAccountCreationTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures
  import MoneyTree.ObligationsFixtures

  alias MoneyTree.Accounts
  alias MoneyTree.Obligations.Obligation
  alias MoneyTree.Repo

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

  test "update_owned_account/3 updates editable account fields for the owner" do
    user = user_fixture()
    account = account_fixture(user, %{name: "Old name"})

    assert {:ok, updated} =
             Accounts.update_owned_account(user, account.id, %{
               "name" => "New name",
               "type" => "unexpected_provider_type",
               "subtype" => "unexpected_provider_subtype",
               "internal_account_kind" => "credit_card",
               "liability_type" => "credit_card"
             })

    assert updated.name == "New name"
    assert updated.type == "credit"
    assert updated.subtype == "credit_card"
    assert updated.internal_account_kind == "credit_card"
    assert updated.liability_type == "credit_card"
  end

  test "update_owned_account/3 persists escrow classification without liability type" do
    user = user_fixture()
    account = account_fixture(user, %{name: "Escrow holding"})

    assert {:ok, updated} =
             Accounts.update_owned_account(user, account.id, %{
               "internal_account_kind" => "escrow",
               "liability_type" => "mortgage"
             })

    assert updated.internal_account_kind == "escrow"
    assert updated.liability_type == nil
    assert updated.type == "escrow"
    assert updated.subtype == "escrow"
  end

  test "delete_owned_account/2 removes an owned account" do
    user = user_fixture()
    account = account_fixture(user)

    assert {:ok, deleted} = Accounts.delete_owned_account(user, account.id)
    assert deleted.id == account.id
    assert Repo.get(MoneyTree.Accounts.Account, account.id) == nil
  end

  test "delete_owned_account/2 succeeds when a model-detected obligation still funds from it" do
    user = user_fixture()
    account = account_fixture(user)
    obligation = obligation_fixture(user, %{linked_funding_account: account})

    assert {:ok, _deleted} = Accounts.delete_owned_account(user, account.id)

    assert %Obligation{linked_funding_account_id: nil} = Repo.get(Obligation, obligation.id)
  end
end
