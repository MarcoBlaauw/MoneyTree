defmodule MoneyTreeWeb.DashboardLiveTest do
  use MoneyTreeWeb.ConnCase, async: true

  import MoneyTree.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Decimal
  alias MoneyTree.Accounts
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction
  alias MoneyTreeWeb.Auth

  setup %{conn: conn} do
    user = user_fixture()
    %{token: token} = session_fixture(user, %{context: "test"})

    {:ok,
     conn: authed_conn(conn, token),
     user: user}
  end

  test "masks balances by default and reveals them on toggle", %{conn: conn, user: user} do
    account = account_fixture(user, %{current_balance: Decimal.new("100.50"), available_balance: Decimal.new("80.25")})
    insert_transaction(account, %{amount: Decimal.new("25.00"), description: "Coffee"})

    {:ok, view, html} = live(conn, ~p"/app/dashboard")

    assert html =~ "Dashboard"
    assert html =~ "••"
    refute html =~ "USD 100.50"

    view
    |> element("#toggle-balances")
    |> render_click()

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

  defp authed_conn(conn, token) do
    cookie_name = Auth.session_cookie_name()

    conn
    |> recycle()
    |> init_test_session(%{user_token: token})
    |> put_req_cookie(cookie_name, token)
  end
end
