defmodule MoneyTree.Transactions.DashboardQueriesTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures

  alias Decimal
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Repo
  alias MoneyTree.Transactions
  alias MoneyTree.Transactions.Transaction

  setup do
    user = user_fixture()
    account = account_fixture(user)
    %{user: user, account: account}
  end

  test "recent_with_color tags amounts with semantic colors", %{user: user, account: account} do
    insert_transaction(account, Decimal.new("25.00"))
    insert_transaction(account, Decimal.new("-10.00"))

    [latest | _] = Transactions.recent_with_color(user, limit: 2)
    assert latest.color_class in ["text-rose-600", "text-emerald-600", "text-slate-600"]
    assert latest.amount_masked =~ "••"
  end

  test "category_rollups aggregates spend", %{user: user, account: account} do
    insert_transaction(account, Decimal.new("75.50"), category: "Dining")
    insert_transaction(account, Decimal.new("125.00"), category: "Dining")

    [rollup | _] = Transactions.category_rollups(user)
    assert rollup.category == "Dining"
    assert rollup.total =~ "USD"
  end

  test "subscription_spend recognises recurring spend", %{user: user, account: account} do
    insert_transaction(account, Decimal.new("30.00"),
      description: "Video Subscription",
      category: "Subscription"
    )

    summary = Transactions.subscription_spend(user)
    assert summary.monthly_total =~ "USD"
    assert summary.monthly_total_decimal == Decimal.new("30.00")
  end

  defp insert_transaction(%Account{} = account, amount, opts \\ %{}) do
    params = %{
      external_id: System.unique_integer([:positive]) |> Integer.to_string(),
      amount: amount,
      currency: account.currency,
      type: "card",
      posted_at: DateTime.utc_now(),
      description: Map.get(opts, :description, "Txn"),
      category: Map.get(opts, :category),
      status: "posted",
      account_id: account.id
    }

    %Transaction{}
    |> Transaction.changeset(params)
    |> Repo.insert!()
  end
end
