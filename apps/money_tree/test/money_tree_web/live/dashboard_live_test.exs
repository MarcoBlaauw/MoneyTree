defmodule MoneyTreeWeb.DashboardLiveTest do
  use MoneyTreeWeb.ConnCase, async: true

  import MoneyTree.AccountsFixtures
  import MoneyTree.AssetsFixtures
  import MoneyTree.MortgagesFixtures
  import MoneyTree.ObligationsFixtures
  import Phoenix.LiveViewTest

  alias Decimal
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Assets.Asset
  alias MoneyTree.Budgets
  alias MoneyTree.Notifications
  alias MoneyTree.Notifications.Event
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction

  setup :register_and_log_in_user

  test "budget widgets reflect period rollups", %{conn: conn, user: user} do
    account = account_fixture(user, %{name: "Spending Account"})

    {:ok, _} =
      Budgets.create_budget(user, %{
        name: "Salary",
        period: :monthly,
        allocation_amount: "5000.00",
        currency: "USD",
        entry_type: :income,
        variability: :fixed
      })

    {:ok, _} =
      Budgets.create_budget(user, %{
        name: "Freelance",
        period: :monthly,
        allocation_amount: "600.00",
        currency: "USD",
        entry_type: :income,
        variability: :variable
      })

    {:ok, _} =
      Budgets.create_budget(user, %{
        name: "Rent",
        period: :monthly,
        allocation_amount: "2400.00",
        currency: "USD",
        entry_type: :expense,
        variability: :fixed
      })

    {:ok, _} =
      Budgets.create_budget(user, %{
        name: "Dining",
        period: :monthly,
        allocation_amount: "600.00",
        currency: "USD",
        entry_type: :expense,
        variability: :variable
      })

    today = Date.utc_today()
    timestamp = DateTime.new!(today, ~T[10:00:00], "Etc/UTC")

    insert_transaction(account, %{
      amount: Decimal.new("5000.00"),
      category: "Salary",
      posted_at: timestamp
    })

    insert_transaction(account, %{
      amount: Decimal.new("650.00"),
      category: "Freelance",
      posted_at: timestamp
    })

    insert_transaction(account, %{
      amount: Decimal.new("-2400.00"),
      category: "Rent",
      posted_at: timestamp
    })

    insert_transaction(account, %{
      amount: Decimal.new("-420.00"),
      category: "Dining",
      posted_at: timestamp
    })

    {:ok, view, _html} = live(conn, ~p"/app/dashboard")

    view |> element("#toggle-balances") |> render_click()

    monthly = render(view)
    assert monthly =~ "Monthly overview"
    assert monthly =~ "Planned"
    assert monthly =~ "Actual"
    assert monthly =~ "Remaining"
    assert monthly =~ "Budget watchlist"
    assert monthly =~ "Planner"
    assert monthly =~ "Income vs. expenses"
    assert monthly =~ "Open budgets"
    assert monthly =~ "USD 8600.00"
    assert monthly =~ "USD 8470.00"
    assert monthly =~ "USD 130.00"
    assert monthly =~ "USD 5650.00"
    assert monthly =~ "USD 2820.00"
    assert monthly =~ "USD -180.00"
    assert monthly =~ "Fixed vs. variable"

    view
    |> element(~s(button[phx-click="change-budget-period"][phx-value-period="weekly"]))
    |> render_click()

    weekly = render(view)
    assert weekly =~ "Weekly overview"
    assert weekly =~ "Weekly totals"
    assert weekly =~ "Income vs. expenses"
    assert weekly =~ "Fixed vs. variable"
    refute weekly =~ "Monthly overview"
  end

  test "renders dashboard metrics and masks balances by default", %{conn: conn, user: user} do
    checking =
      account_fixture(user, %{
        name: "Household Checking",
        type: "depository",
        current_balance: Decimal.new("3100.00"),
        available_balance: Decimal.new("2800.00"),
        apr: Decimal.from_float(4.5),
        fee_schedule: "Waived with direct deposit",
        minimum_balance: Decimal.new(500),
        maximum_balance: Decimal.new(5000)
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
    assert html =~ "Controls"
    assert html =~ "Balances masked"
    assert html =~ "Cash &amp; savings"
    assert html =~ "Budget status"
    assert html =~ "Credit cards"
    assert html =~ "Due soon"
    assert html =~ "Needs review"
    assert html =~ "Needs attention"
    assert html =~ "Notifications and review prompts"
    assert html =~ "Budget pulse"
    assert html =~ "Account snapshot"
    assert html =~ "Category-level account composition"
    assert html =~ "Cash &amp; reserves"
    assert html =~ "Loans"
    assert html =~ "Recent activity"
    assert html =~ "View all transactions"
    assert html =~ "Open notifications"
    refute html =~ "Notification inbox"
    refute html =~ "FICO &amp; insights"
    refute html =~ "Placeholder"
    refute html =~ "Connected financial accounts"
    refute html =~ "Tangible asset records"
    refute html =~ "Monthly recurring spend"

    refute html =~
             "Reveal values only when needed, lock the session when you step away, and refresh the latest activity without leaving the dashboard."

    assert html =~ "••"
    refute html =~ "USD 3100.00"
    refute html =~ "USD 500.00"

    view |> element("#toggle-balances") |> render_click()

    rendered = render(view)
    assert rendered =~ "USD 120.00"
    assert rendered =~ "text-rose-600"
    assert rendered =~ "text-emerald-600"
  end

  test "surfaces evaluation status summary on the dashboard", %{conn: conn, user: user} do
    mortgage_fixture(user, %{
      nickname: "Home loan",
      home_value_estimate: nil,
      last_reviewed_at: nil
    })

    {:ok, _view, html} = live(conn, ~p"/app/dashboard")

    assert html =~ "Evaluation status"
    assert html =~ "Missing facts, stale data, review queues, and expiring items"
    assert html =~ "Needs review"
    assert html =~ "Incomplete"
    assert html =~ "Home loan is missing a home value estimate"
    assert html =~ ~s(href="/app/react/evaluations")
  end

  test "lists tangible assets and reveals valuations when unmasked", %{conn: conn, user: user} do
    account = account_fixture(user, %{name: "Equity Account"})

    asset_fixture(account, %{
      name: "Family Home",
      valuation_amount: Decimal.new("450000.00"),
      valuation_currency: "USD",
      asset_type: "real_estate",
      document_refs: ["Deed #123"]
    })

    {:ok, view, html} = live(conn, ~p"/app/dashboard")

    assert html =~ "Tangible assets"
    assert html =~ "Family Home"
    assert html =~ "assets tracked"
    assert html =~ "Documents: Deed #123"
    refute html =~ "USD 450000.00"

    view |> element("#toggle-balances") |> render_click()

    rendered = render(view)
    assert rendered =~ "USD 450000.00"
  end

  test "empty tangible assets are linked to the assets page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/app/dashboard")

    assert html =~ "No tangible assets are tracked yet."
    assert html =~ ~s(href="/app/assets")
    refute html =~ ~s(id="new-asset")
    refute html =~ "Record tangible assets to include their valuations in your dashboard metrics."
  end

  test "recent activity is limited on the dashboard", %{conn: conn, user: user} do
    account = account_fixture(user, %{name: "Activity Account"})
    today = Date.utc_today()

    for index <- 1..6 do
      insert_transaction(account, %{
        amount: Decimal.new("#{index}.00"),
        description: "Dashboard Activity #{index}",
        posted_at: DateTime.new!(Date.add(today, index), ~T[12:00:00], "Etc/UTC")
      })
    end

    {:ok, _view, html} = live(conn, ~p"/app/dashboard")

    assert html =~ "Dashboard Activity 6"
    assert html =~ "Dashboard Activity 2"
    refute html =~ "Dashboard Activity 1"
    assert html =~ ~s(href="/app/transactions")
  end

  test "needs attention panel combines notifications and evaluation prompts", %{
    conn: conn,
    user: user
  } do
    obligation = obligation_fixture(user, %{creditor_payee: "Travel Card"})

    {:ok, _event} =
      Notifications.record_event(%{
        user_id: user.id,
        obligation_id: obligation.id,
        kind: "payment_obligation",
        status: "overdue",
        severity: "critical",
        title: "Travel Card overdue",
        message: "Travel Card payment is overdue.",
        action: "Verify payment",
        event_date: Date.utc_today(),
        occurred_at: DateTime.utc_now(),
        metadata: %{},
        dedupe_key: "dashboard-attention-#{obligation.id}"
      })

    mortgage_fixture(user, %{
      nickname: "Home loan",
      home_value_estimate: nil,
      last_reviewed_at: nil
    })

    {:ok, _view, html} = live(conn, ~p"/app/dashboard")

    assert html =~ "Needs attention"
    assert html =~ "Notification"
    assert html =~ "Travel Card payment is overdue."
    assert html =~ ~s(href="/app/notifications")
    assert html =~ "Evaluation"
    assert html =~ "Home loan is missing a home value estimate"
    assert html =~ ~s(href="/app/react/evaluations")
  end

  test "users can manage assets from the dashboard", %{conn: conn, user: user} do
    account = account_fixture(user, %{name: "Asset Account"})

    asset_fixture(account, %{
      name: "Existing Asset",
      valuation_amount: Decimal.new("5000.00"),
      valuation_currency: "USD",
      asset_type: "vehicle"
    })

    {:ok, view, _html} = live(conn, ~p"/app/dashboard")

    view |> element("#new-asset") |> render_click()

    params = %{
      "asset" => %{
        "account_id" => account.id,
        "name" => "Weekend Cabin",
        "asset_type" => "real_estate",
        "valuation_amount" => "120000",
        "valuation_currency" => "USD",
        "ownership_type" => "joint",
        "location" => "Lakeside",
        "documents_text" => "Deed #CABIN-001"
      }
    }

    view |> form("#asset-form", params) |> render_submit()

    rendered = render(view)
    assert rendered =~ "Asset added successfully."
    assert rendered =~ "Weekend Cabin"

    asset = Repo.get_by!(Asset, name: "Weekend Cabin")

    view |> element("#asset-#{asset.id} [phx-click=\"edit-asset\"]") |> render_click()

    update_params = %{
      "asset" => %{
        "account_id" => account.id,
        "name" => "Updated Cabin",
        "asset_type" => "real_estate",
        "valuation_amount" => "125000",
        "valuation_currency" => "USD",
        "ownership_type" => "joint",
        "location" => "Lakeside",
        "documents_text" => "Deed #CABIN-001\nInsurance #CABIN-INS"
      }
    }

    view |> form("#asset-form", update_params) |> render_submit()

    rendered = render(view)
    assert rendered =~ "Asset updated successfully."
    assert rendered =~ "Updated Cabin"
    assert rendered =~ "Insurance #CABIN-INS"

    view |> element("#asset-#{asset.id} [phx-click=\"delete-asset\"]") |> render_click()

    rendered = render(view)
    assert rendered =~ "Asset removed successfully."
    refute rendered =~ "Updated Cabin"
  end

  test "locking prevents balance reveal until unlocked", %{conn: conn, user: user} do
    account_fixture(user, %{current_balance: Decimal.new("45.00")})

    {:ok, view, _html} = live(conn, ~p"/app/dashboard")

    view |> element("#lock-dashboard") |> render_click()

    assert view |> element("#toggle-balances") |> render_click() =~ "Unlock the dashboard"

    view |> element("#unlock-dashboard") |> render_click()

    refute render(view) =~ "Unlock the dashboard"
  end

  test "dashboard does not render the full accounts list", %{conn: conn, user: user} do
    account_fixture(user, %{name: "Visible Account"})

    other_user = user_fixture(%{email: "other@example.com"})
    account_fixture(other_user, %{name: "Hidden Account"})

    {:ok, _view, html} = live(conn, ~p"/app/dashboard")

    refute html =~ "Visible Account"
    refute html =~ "Hidden Account"
  end

  test "users can dismiss durable notification events from the notifications page", %{
    conn: conn,
    user: user
  } do
    obligation = obligation_fixture(user, %{creditor_payee: "Travel Card"})

    {:ok, event} =
      Notifications.record_event(%{
        user_id: user.id,
        obligation_id: obligation.id,
        kind: "payment_obligation",
        status: "overdue",
        severity: "critical",
        title: "Travel Card overdue",
        message: "Travel Card payment is overdue.",
        action: "Verify payment",
        event_date: ~D[2026-03-15],
        occurred_at: ~U[2026-03-18 00:00:00Z],
        metadata: %{},
        dedupe_key: "dashboard-dismiss-#{obligation.id}"
      })

    {:ok, view, html} = live(conn, ~p"/app/notifications")

    assert html =~ "Travel Card payment is overdue."
    assert html =~ "Dismiss"

    view
    |> element(~s(button[phx-click="resolve-notification"][phx-value-id="#{event.id}"]))
    |> render_click()

    rendered = render(view)
    assert rendered =~ "Notification dismissed."
    refute rendered =~ "Travel Card payment is overdue."
    assert Repo.get!(Event, event.id).resolved_at
  end

  test "users can hide computed advisories for the current notifications session", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/app/notifications")

    assert html =~ "You&#39;re all caught up!"
    assert html =~ "Hide"

    view
    |> element(~s(button[phx-click="hide-computed-notification"]))
    |> render_click()

    rendered = render(view)
    assert rendered =~ "Advisory hidden for this session."
    assert rendered =~ "No notifications need attention right now."
    refute rendered =~ "You&#39;re all caught up!"
  end

  defp insert_transaction(%Account{} = account, attrs) do
    params =
      %{
        external_id: System.unique_integer([:positive]) |> Integer.to_string(),
        amount: Map.get(attrs, :amount, Decimal.new("1.00")),
        currency: account.currency,
        type: Map.get(attrs, :type, "card"),
        posted_at: Map.get(attrs, :posted_at, DateTime.utc_now()),
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
