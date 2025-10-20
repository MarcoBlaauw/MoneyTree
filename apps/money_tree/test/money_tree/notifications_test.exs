defmodule MoneyTree.NotificationsTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures

  alias Decimal
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Notifications
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction

  test "pending returns fallback when no alerts" do
    user = user_fixture()
    assert [%{message: "You're all caught up!"}] = Notifications.pending(user)
  end

  test "pending includes credit utilization warnings" do
    user = user_fixture()

    card =
      account_fixture(user, %{
        name: "Travel Card",
        type: "credit",
        current_balance: Decimal.new("900.00"),
        available_balance: Decimal.new("50.00"),
        limit: Decimal.new("950.00")
      })

    insert_transaction(card, Decimal.new("100.00"))

    notifications = Notifications.pending(user)
    assert Enum.any?(notifications, &String.contains?(&1.message, "utilisation"))
  end

  defp insert_transaction(%Account{} = account, amount) do
    params = %{
      external_id: System.unique_integer([:positive]) |> Integer.to_string(),
      amount: amount,
      currency: account.currency,
      type: "card",
      posted_at: DateTime.utc_now(),
      description: "Spend",
      status: "posted",
      account_id: account.id
    }

    %Transaction{}
    |> Transaction.changeset(params)
    |> Repo.insert!()
  end
end
