defmodule MoneyTreeWeb.DashboardLiveTest do
  use MoneyTreeWeb.ConnCase, async: true

  import MoneyTree.AccountsFixtures
  import MoneyTree.AssetsFixtures
  import Phoenix.LiveViewTest

  alias Decimal
  alias MoneyTree.Accounts
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction

  setup :register_and_log_in_user

  test "includes CSP meta tags and masks balances by default", %{conn: conn, user: user} do
    account =
      account_fixture(user, %{
        current_balance: Decimal.new("100.50"),
        available_balance: Decimal.new("80.25")
      })

    insert_transaction(account, %{amount: Decimal.new("25.00"), description: "Coffee"})

    {:ok, view, html} = live(conn, ~p"/app/dashboard")

    assert html =~ "<meta name=\"csp-nonce\""
    assert html =~ "<meta name=\"csp-script-src\""
    assert html =~ "<meta name=\"csp-style-src\""
    assert html =~ "Dashboard"
    assert html =~ "Assets"
    assert html =~ "••"
    refute html =~ "USD 100.50"

    view |> element("#toggle-balances") |> render_click()
    assert render(view) =~ "USD 100.50"
    assert render(view) =~ "USD 80.25"
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

  test "dashboard lists only accessible assets", %{conn: conn, user: user} do
    account = account_fixture(user, %{name: "Home"})
    asset_fixture(user, account, %{name: "Family Home"})

    other_user = user_fixture(%{email: "asset-other@example.com"})
    other_account = account_fixture(other_user, %{name: "Other Account"})
    asset_fixture(other_user, other_account, %{name: "Hidden Asset"})

    {:ok, _view, html} = live(conn, ~p"/app/dashboard")

    assert html =~ "Family Home"
    refute html =~ "Hidden Asset"
  end

  test "user can create assets from the dashboard", %{conn: conn, user: user} do
    account = account_fixture(user, %{name: "Asset Account"})

    {:ok, view, _html} = live(conn, ~p"/app/dashboard")

    view |> element("button", "Add asset") |> render_click()

    params = %{
      "name" => "New Vehicle",
      "type" => "vehicle",
      "valuation_amount" => "15000",
      "valuation_currency" => "USD",
      "valuation_date" => "2024-01-01",
      "account_id" => account.id,
      "ownership" => "Joint",
      "location" => "Garage",
      "documents" => "https://example.com/title.pdf",
      "metadata" => ~s({"note":"leased"})
    }

    view
    |> form("#asset-form", %{asset: params})
    |> render_submit()

    assert render(view) =~ "Asset saved."
    assert render(view) =~ "New Vehicle"
    assert render(view) =~ "vehicle"
  end

  test "user can edit and remove assets from the dashboard", %{conn: conn, user: user} do
    account = account_fixture(user, %{name: "Edit Account"})
    asset = asset_fixture(user, account, %{name: "Updatable Asset"})

    {:ok, view, _html} = live(conn, ~p"/app/dashboard")

    view
    |> element("button[phx-value-id=\"#{asset.id}\"]", "Edit")
    |> render_click()

    view
    |> form("#asset-form", %{asset: %{name: "Renamed Asset", ownership: "Solo"}})
    |> render_submit()

    assert render(view) =~ "Asset saved."
    assert render(view) =~ "Renamed Asset"

    view
    |> element("button[phx-value-id=\"#{asset.id}\"]", "Remove")
    |> render_click()

    assert render(view) =~ "Asset removed."
    refute render(view) =~ "Renamed Asset"
  end

  defp insert_transaction(%Account{} = account, attrs) do
    params =
      %{
        external_id: System.unique_integer([:positive]) |> Integer.to_string(),
        amount: Map.get(attrs, :amount, Decimal.new("1.00")),
        currency: account.currency,
        type: "card",
        posted_at: DateTime.utc_now(),
        description: Map.get(attrs, :description, "Test"),
        status: "posted",
        account_id: account.id
      }

    %Transaction{}
    |> Transaction.changeset(params)
    |> Repo.insert!()
  end
end
