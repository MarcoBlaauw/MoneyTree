defmodule MoneyTree.BudgetsTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures

  alias Decimal
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Budgets
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction

  test "aggregate_totals groups spend by budget name" do
    user = user_fixture()
    account = account_fixture(user)

    insert_transaction(account, %{
      amount: Decimal.new("3000.00"),
      category: "Housing",
      description: "Rent"
    })

    insert_transaction(account, %{
      amount: Decimal.new("150.00"),
      category: "Groceries",
      description: "Market"
    })

    budgets = Budgets.aggregate_totals(user)

    assert %{status: :over, spent: "USD 3000.00"} = Enum.find(budgets, &(&1.name == "Housing"))
    assert %{status: :under} = Enum.find(budgets, &(&1.name == "Groceries"))
  end

  defp insert_transaction(%Account{} = account, attrs) do
    params = %{
      external_id: System.unique_integer([:positive]) |> Integer.to_string(),
      amount: Map.fetch!(attrs, :amount),
      currency: account.currency,
      type: "card",
      posted_at: DateTime.utc_now(),
      description: Map.get(attrs, :description, "Budget Test"),
      category: Map.get(attrs, :category),
      status: "posted",
      account_id: account.id
    }

    %Transaction{}
    |> Transaction.changeset(params)
    |> Repo.insert!()
  end
end
