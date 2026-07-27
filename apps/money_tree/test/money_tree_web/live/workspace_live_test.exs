defmodule MoneyTreeWeb.WorkspaceLiveTest do
  use MoneyTreeWeb.ConnCase, async: true

  import MoneyTree.AccountsFixtures
  import MoneyTree.AssetsFixtures
  import MoneyTree.InstitutionsFixtures
  import MoneyTree.ObligationsFixtures
  import Phoenix.LiveViewTest

  alias Decimal
  alias MoneyTree.Categorization
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction

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

  test "accounts page renders account summary and accounts", %{conn: conn} do
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

    assert html =~ "Institutions"
    assert html =~ "Manage institutions"
    assert html =~ "Daily Checking"
    refute html =~ "Linked institutions"
  end

  test "accounts page supports account edit and remove icon actions", %{conn: conn} do
    {:ok, %{conn: conn, user: user}} = register_and_log_in_user(%{conn: conn})

    account =
      account_fixture(user, %{
        name: "Old Checking",
        type: "depository",
        subtype: "checking"
      })

    {:ok, view, html} = live(conn, ~p"/app/accounts")

    assert html =~ ~s(aria-label="Edit Old Checking")
    assert html =~ ~s(aria-label="Remove Old Checking")

    view
    |> element(~s(button[phx-click="edit-account"][phx-value-id="#{account.id}"]))
    |> render_click()

    edit_html = render(view)
    assert edit_html =~ "Account category"
    refute edit_html =~ ~s(name="account[type]")
    refute edit_html =~ ~s(name="account[subtype]")

    view
    |> form(~s(form[phx-submit="update-account"][phx-value-id="#{account.id}"]), %{
      "account" => %{
        "name" => "Renamed Checking",
        "internal_account_kind" => "savings"
      }
    })
    |> render_submit()

    rendered = render(view)
    assert rendered =~ "Renamed Checking"
    assert rendered =~ "Savings"

    view
    |> element(~s(button[phx-click="delete-account"][phx-value-id="#{account.id}"]))
    |> render_click()

    rendered = render(view)
    assert rendered =~ "Account removed."
    refute rendered =~ "Renamed Checking"
  end

  test "accounts page supports categorized view and account sorting", %{conn: conn} do
    {:ok, %{conn: conn, user: user}} = register_and_log_in_user(%{conn: conn})

    account_fixture(user, %{
      name: "Small Checking",
      internal_account_kind: "checking",
      current_balance: Decimal.new("100.00"),
      available_balance: Decimal.new("80.00")
    })

    account_fixture(user, %{
      name: "Large Savings",
      internal_account_kind: "savings",
      current_balance: Decimal.new("5000.00"),
      available_balance: Decimal.new("4900.00")
    })

    account_fixture(user, %{
      name: "Card Debt",
      internal_account_kind: "credit_card",
      current_balance: Decimal.new("-1000.00"),
      available_balance: Decimal.new("250.00")
    })

    {:ok, view, html} = live(conn, ~p"/app/accounts")

    assert html =~ "Categorized"
    assert html =~ "Checking"
    assert html =~ "Savings"
    assert html =~ "Credit card"
    assert html =~ "Operating cash"
    assert html =~ "Cash reserves"
    assert html =~ "Revolving debt"
    assert html =~ "Category total"
    assert html =~ "USD 4900.00"
    assert html =~ "USD -1000.00"

    html =
      view
      |> form(~s(form[phx-change="change-account-list-preferences"]), %{
        "account_view" => "list",
        "account_sort" => "balance_desc"
      })
      |> render_change()

    assert_before(html, "Large Savings", "Small Checking")
    assert_before(html, "Small Checking", "Card Debt")
  end

  test "obligations page renders obligations summary", %{conn: conn} do
    {:ok, %{conn: conn, user: user}} = register_and_log_in_user(%{conn: conn})
    obligation_fixture(user, %{creditor_payee: "Travel Card", due_day: 12})

    {:ok, _view, html} = live(conn, ~p"/app/obligations")

    assert html =~ "Bills &amp; Subscriptions"
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

    assert {:ok, _category} =
             Categorization.create_category(user, %{name: "Groceries", kind: "expense"})

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

  defp assert_before(html, left, right) do
    assert {left_index, _length} = :binary.match(html, left)
    assert {right_index, _length} = :binary.match(html, right)
    assert left_index < right_index
  end
end
