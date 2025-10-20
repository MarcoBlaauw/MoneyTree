defmodule MoneyTreeWeb.DashboardLiveTest do
  use MoneyTreeWeb.ConnCase, async: true

  import MoneyTree.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Decimal
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction

  setup :register_and_log_in_user

  test "renders dashboard metrics and masks balances by default", %{conn: conn, user: user} do
    checking =
      account_fixture(user, %{
        name: "Household Checking",
        type: "depository",
        current_balance: Decimal.new("3100.00"),
        available_balance: Decimal.new("2800.00")
      })

    credit =
      account_fixture(user, %{
        name: "Rewards Card",
        type: "credit",
        current_balance: Decimal.new("520.00"),
        available_balance: Decimal.new("80.00"),
        limit: Decimal.new("600.00")
      })

    loan =
      account_fixture(user, %{
        name: "Student Loan",
        type: "loan",
        subtype: "student",
        current_balance: Decimal.new("15000.00")
      })

    insert_transaction(checking, %{
      amount: Decimal.new("3000.00"),
      description: "Mortgage",
      category: "Housing"
    })

    insert_transaction(checking, %{
      amount: Decimal.new("120.00"),
      description: "Weekly Groceries",
      category: "Groceries"
    })

    insert_transaction(checking, %{
      amount: Decimal.new("45.99"),
      description: "Music Subscription",
      category: "Subscription"
    })

    insert_transaction(credit, %{amount: Decimal.new("-25.00"), description: "Refund"})
    insert_transaction(loan, %{amount: Decimal.new("-150.00"), description: "Loan Payment"})

    {:ok, view, html} = live(conn, ~p"/app/dashboard")

    assert html =~ "<meta name=\"csp-nonce\""
    assert html =~ "Next.js demos"
    assert html =~ "Budget pulse"
    assert html =~ "Loans &amp; autopay"
    assert html =~ "Recent activity"

    assert html =~ "••"
    refute html =~ "USD 3100.00"

    view |> element("#toggle-balances") |> render_click()

    rendered = render(view)
    assert rendered =~ "USD 3100.00"
    assert rendered =~ "USD 120.00"
    assert rendered =~ "text-rose-600"
    assert rendered =~ "text-emerald-600"
    assert rendered =~ "Subscription spend this month"
  end

  test "locking prevents balance reveal until unlocked", %{conn: conn, user: user} do
    account_fixture(user, %{current_balance: Decimal.new("45.00")})

    {:ok, view, _html} = live(conn, ~p"/app/dashboard")

    view |> element("#lock-dashboard") |> render_click()

    assert view |> element("#toggle-balances") |> render_click() =~ "Unlock the dashboard"

    view |> element("#unlock-dashboard") |> render_click()

    refute render(view) =~ "Unlock the dashboard"
  end

  test "dashboard only lists accounts owned by the user", %{conn: conn, user: user} do
    account_fixture(user, %{name: "Visible Account"})

    other_user = user_fixture(%{email: "other@example.com"})
    account_fixture(other_user, %{name: "Hidden Account"})

    {:ok, _view, html} = live(conn, ~p"/app/dashboard")

    assert html =~ "Visible Account"
    refute html =~ "Hidden Account"
  end

  defp insert_transaction(%Account{} = account, attrs) do
    params =
      %{
        external_id: System.unique_integer([:positive]) |> Integer.to_string(),
        amount: Map.get(attrs, :amount, Decimal.new("1.00")),
        currency: account.currency,
        type: Map.get(attrs, :type, "card"),
        posted_at: DateTime.utc_now(),
        description: Map.get(attrs, :description, "Test"),
        category: Map.get(attrs, :category),
        status: "posted",
        account_id: account.id
      }

    %Transaction{}
    |> Transaction.changeset(params)
    |> Repo.insert!()
  end
end
