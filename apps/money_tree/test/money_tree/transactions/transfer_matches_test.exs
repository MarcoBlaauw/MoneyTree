defmodule MoneyTree.Transactions.TransferMatchesTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures

  alias Decimal
  alias MoneyTree.Repo
  alias MoneyTree.Transactions
  alias MoneyTree.Transactions.Transaction

  setup do
    user = user_fixture()
    checking = account_fixture(user, %{type: "depository", subtype: "checking"})
    savings = account_fixture(user, %{type: "depository", subtype: "savings"})

    %{user: user, checking: checking, savings: savings}
  end

  test "confirmed match updates transfer flags and excludes spending", %{
    user: user,
    checking: checking,
    savings: savings
  } do
    outflow =
      create_transaction!(checking, %{
        amount: Decimal.new("-50.00"),
        description: "TRANSFER TO SAVINGS",
        category: "Transfer"
      })

    inflow =
      create_transaction!(savings, %{
        amount: Decimal.new("50.00"),
        description: "TRANSFER FROM CHECKING",
        category: "Transfer"
      })

    assert {:ok, match} =
             Transactions.create_transfer_match(user, %{
               outflow_transaction_id: outflow.id,
               inflow_transaction_id: inflow.id,
               match_type: "checking_to_savings",
               status: "confirmed",
               matched_by: "system",
               confidence_score: Decimal.new("0.98"),
               match_reason: "test"
             })

    assert match.status == "confirmed"

    reloaded_outflow = Repo.get!(Transaction, outflow.id)
    reloaded_inflow = Repo.get!(Transaction, inflow.id)

    assert reloaded_outflow.excluded_from_spending
    assert reloaded_inflow.excluded_from_spending
    assert reloaded_outflow.transaction_kind == "internal_transfer"

    assert [] == Transactions.category_rollups(user)
  end

  test "suggest_transfer_matches returns deterministic suggestions", %{
    user: user,
    checking: checking,
    savings: savings
  } do
    _outflow =
      create_transaction!(checking, %{
        amount: Decimal.new("-120.00"),
        description: "ALLY TRANSFER"
      })

    _inflow =
      create_transaction!(savings, %{
        amount: Decimal.new("120.00"),
        description: "TRANSFER FROM CHECKING"
      })

    suggestions = Transactions.suggest_transfer_matches(user, lookback_days: 30)

    assert Enum.any?(suggestions, &(&1.match_type == "checking_to_savings"))
  end

  test "rejected status clears spending exclusion flags", %{
    user: user,
    checking: checking,
    savings: savings
  } do
    outflow =
      create_transaction!(checking, %{
        amount: Decimal.new("-25.00"),
        description: "TRANSFER TO SAVINGS"
      })

    inflow =
      create_transaction!(savings, %{
        amount: Decimal.new("25.00"),
        description: "TRANSFER FROM CHECKING"
      })

    {:ok, match} =
      Transactions.create_transfer_match(user, %{
        outflow_transaction_id: outflow.id,
        inflow_transaction_id: inflow.id,
        match_type: "checking_to_savings",
        status: "confirmed",
        matched_by: "system"
      })

    assert {:ok, updated_match} =
             Transactions.update_transfer_match_status(user, match.id, "rejected")

    assert updated_match.status == "rejected"

    refute Repo.get!(Transaction, outflow.id).excluded_from_spending
    refute Repo.get!(Transaction, inflow.id).excluded_from_spending
  end

  defp create_transaction!(account, attrs) do
    params =
      %{
        external_id: "txn-#{System.unique_integer([:positive])}",
        source: "manual_import",
        source_transaction_id: nil,
        amount: Decimal.new("-10.00"),
        currency: account.currency,
        posted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        description: "Txn",
        category: nil,
        status: "posted",
        account_id: account.id
      }
      |> Map.merge(attrs)

    %Transaction{}
    |> Transaction.changeset(params)
    |> Repo.insert!()
  end
end
