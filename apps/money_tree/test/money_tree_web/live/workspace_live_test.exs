defmodule MoneyTreeWeb.WorkspaceLiveTest do
  use MoneyTreeWeb.ConnCase, async: true

  import MoneyTree.AccountsFixtures
  import MoneyTree.AssetsFixtures
  import MoneyTree.InstitutionsFixtures
  import MoneyTree.ObligationsFixtures
  import Phoenix.LiveViewTest

  alias Decimal
  alias MoneyTree.Institutions
  alias MoneyTree.Transactions.Transaction
  alias MoneyTree.Repo

  defmodule FakeSynchronization do
    def schedule_incremental_sync(_connection, _opts \\ []), do: :ok
  end

  setup do
    original = Application.get_env(:money_tree, :synchronization)
    Application.put_env(:money_tree, :synchronization, FakeSynchronization)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:money_tree, :synchronization)
      else
        Application.put_env(:money_tree, :synchronization, original)
      end
    end)

    :ok
  end

  test "accounts page renders linked institutions and accounts", %{conn: conn} do
    {:ok, %{conn: conn, user: user}} = register_and_log_in_user(%{conn: conn})
    institution = institution_fixture(%{name: "Northwind Credit Union"})
    connection = connection_fixture(user, %{institution: institution})

    account_fixture(user, %{
      name: "Daily Checking",
      institution_id: institution.id,
      institution_connection_id: connection.id,
      current_balance: Decimal.new("1450.00"),
      available_balance: Decimal.new("1300.00")
    })

    {:ok, _view, html} = live(conn, ~p"/app/accounts")

    assert html =~ "Linked institutions"
    assert html =~ "Northwind Credit Union"
    assert html =~ "Daily Checking"
  end

  test "accounts page supports sync and revoke actions", %{conn: conn} do
    {:ok, %{conn: conn, user: user}} = register_and_log_in_user(%{conn: conn})
    institution = institution_fixture(%{name: "Harbor Bank"})
    connection = connection_fixture(user, %{institution: institution})

    {:ok, view, _html} = live(conn, ~p"/app/accounts")

    view
    |> element(~s(button[phx-click="refresh-connection"][phx-value-id="#{connection.id}"]))
    |> render_click()

    assert render(view) =~ "Sync requested for Harbor Bank."

    view
    |> element(~s(button[phx-click="revoke-connection"][phx-value-id="#{connection.id}"]))
    |> render_click()

    rendered = render(view)
    assert rendered =~ "Revoked Harbor Bank."
    assert rendered =~ "No institutions linked yet."

    assert {:error, :revoked} ==
             Institutions.get_active_connection_for_user(user, connection.id)
  end

  test "obligations page renders obligations summary", %{conn: conn} do
    {:ok, %{conn: conn, user: user}} = register_and_log_in_user(%{conn: conn})
    obligation_fixture(user, %{creditor_payee: "Travel Card", due_day: 12})

    {:ok, _view, html} = live(conn, ~p"/app/obligations")

    assert html =~ "Obligations"
    assert html =~ "Travel Card"
    assert html =~ "day 12"
  end

  test "transactions page renders entries and supports recategorization", %{conn: conn} do
    {:ok, %{conn: conn, user: user}} = register_and_log_in_user(%{conn: conn})
    account = account_fixture(user, %{name: "Primary Checking"})

    transaction =
      %Transaction{}
      |> Transaction.changeset(%{
        account_id: account.id,
        external_id: "txn-#{System.unique_integer([:positive])}",
        amount: Decimal.new("-42.50"),
        currency: "USD",
        posted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        description: "Corner Market",
        merchant_name: "Corner Market",
        status: "posted"
      })
      |> Repo.insert!()

    {:ok, view, html} = live(conn, ~p"/app/transactions")

    assert html =~ "Recent transactions"
    assert html =~ "Corner Market"

    view
    |> form("form", %{transaction_id: transaction.id, category: "Groceries"})
    |> render_submit()

    assert render(view) =~ "Transaction recategorized."
    assert render(view) =~ "Groceries"
  end

  test "assets page renders tracked assets and supports creation", %{conn: conn} do
    {:ok, %{conn: conn, user: user}} = register_and_log_in_user(%{conn: conn})
    account = account_fixture(user, %{name: "Asset Funding"})
    asset_fixture(account, %{name: "Family Cabin", valuation_amount: Decimal.new("245000.00")})

    {:ok, view, html} = live(conn, ~p"/app/assets")

    assert html =~ "Assets"
    assert html =~ "Family Cabin"

    view |> element("button", "Add asset") |> render_click()

    view
    |> form("#asset-form", %{
      asset: %{
        account_id: account.id,
        name: "Collector Car",
        asset_type: "Vehicle",
        category: "Classic",
        valuation_amount: "52000.00",
        valuation_currency: "USD",
        ownership_type: "Owned",
        ownership_details: "",
        location: "Garage",
        notes: "",
        acquired_on: "",
        last_valued_on: "",
        documents_text: "title.pdf"
      }
    })
    |> render_submit()

    rendered = render(view)
    assert rendered =~ "Asset added successfully."
    assert rendered =~ "Collector Car"
  end
end
