defmodule MoneyTree.Transactions.TransferMatcherTest do
  use ExUnit.Case, async: true

  alias Decimal
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Transactions.Transaction
  alias MoneyTree.Transactions.TransferMatcher

  test "suggests checking to savings transfer" do
    outflow_account = %Account{id: "acct-checking", internal_account_kind: "checking"}
    inflow_account = %Account{id: "acct-savings", internal_account_kind: "savings"}

    outflow = %Transaction{
      id: "txn-out",
      account_id: outflow_account.id,
      amount: Decimal.new("-600.00"),
      posted_at: ~U[2026-04-20 10:00:00Z],
      description: "ALLY BANK TRANSFER"
    }

    inflow = %Transaction{
      id: "txn-in",
      account_id: inflow_account.id,
      amount: Decimal.new("600.00"),
      posted_at: ~U[2026-04-21 10:00:00Z],
      description: "TRANSFER FROM CHECKING"
    }

    assert {:ok, suggestion} =
             TransferMatcher.suggest_pair(outflow, outflow_account, inflow, inflow_account)

    assert suggestion.match_type == "checking_to_savings"
    assert suggestion.status == "suggested"
  end

  test "does not match transactions with same sign" do
    account_one = %Account{id: "acct-1", internal_account_kind: "checking"}
    account_two = %Account{id: "acct-2", internal_account_kind: "savings"}

    left = %Transaction{
      id: "txn-1",
      account_id: account_one.id,
      amount: Decimal.new("-25.00"),
      posted_at: ~U[2026-04-20 10:00:00Z],
      description: "payment"
    }

    right = %Transaction{
      id: "txn-2",
      account_id: account_two.id,
      amount: Decimal.new("-25.00"),
      posted_at: ~U[2026-04-20 10:00:00Z],
      description: "payment"
    }

    assert :no_match == TransferMatcher.suggest_pair(left, account_one, right, account_two)
  end
end
