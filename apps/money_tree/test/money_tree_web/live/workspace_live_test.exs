defmodule MoneyTreeWeb.WorkspaceLiveTest do
  use MoneyTreeWeb.ConnCase, async: false

  import MoneyTree.AccountsFixtures
  import MoneyTree.AssetsFixtures
  import MoneyTree.InstitutionsFixtures
  import MoneyTree.ObligationsFixtures
  import Phoenix.LiveViewTest

  alias Decimal
  alias MoneyTree.Assets
  alias MoneyTree.Assets.ProviderRegistry
  alias MoneyTree.Assets.VehicleValuationProviders.MarketCheck
  alias MoneyTree.Categorization
  alias MoneyTree.Loans
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction

  defmodule FakeSynchronization do
    def schedule_incremental_sync(_connection, _opts \\ []), do: :ok
  end

  setup do
    original = Application.get_env(:money_tree, :synchronization)
    original_registry = Application.get_env(:money_tree, ProviderRegistry)
    original_marketcheck = Application.get_env(:money_tree, MarketCheck)

    Application.put_env(:money_tree, :synchronization, FakeSynchronization)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:money_tree, :synchronization)
      else
        Application.put_env(:money_tree, :synchronization, original)
      end

      restore_env(ProviderRegistry, original_registry)
      restore_env(MarketCheck, original_marketcheck)
    end)

    :ok
  end

  setup {Req.Test, :verify_on_exit!}

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

    {:ok, vehicle_loan} =
      Loans.create_loan(user, %{
        loan_type: "auto",
        name: "Collector car loan",
        current_balance: "18000",
        current_interest_rate: "0.06",
        remaining_term_months: 48,
        monthly_payment_total: "425"
      })

    Application.put_env(:money_tree, ProviderRegistry,
      enabled_providers: ["marketcheck"],
      monthly_request_limit: 450,
      refresh_interval_days: 7
    )

    Application.put_env(:money_tree, MarketCheck,
      api_key: "test-key",
      base_url: "https://api.marketcheck.test",
      dealer_type: "independent",
      plug: {Req.Test, __MODULE__}
    )

    {:ok, view, html} = live(conn, ~p"/app/assets")

    assert html =~ "Assets"
    assert html =~ "Family Cabin"

    view |> element("button", "Add asset") |> render_click()

    assert has_element?(view, "#vehicle-lookup-form")
    refute has_element?(view, "#asset-form")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/v2/decode/car/1HGCM82633A004352/specs"

      Req.Test.json(conn, %{
        "is_valid" => true,
        "year" => 2003,
        "make" => "Honda",
        "model" => "Accord",
        "trim" => "EX",
        "body_type" => "Sedan"
      })
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/v2/predict/car/us/marketcheck_price"
      Req.Test.json(conn, %{"marketcheck_price" => 52_000})
    end)

    view
    |> form("#vehicle-lookup-form", %{
      vehicle: %{
        vin: "1HGCM82633A004352",
        mileage: "125000",
        market_region: "60601"
      }
    })
    |> render_submit()

    preview_html = render(view)
    assert preview_html =~ "Review before saving"
    assert preview_html =~ "2003 Honda Accord"
    assert preview_html =~ "USD 52000.00"
    assert Assets.list_assets(user) |> Enum.all?(&(&1.name != "Collector Car"))

    view
    |> form("#vehicle-confirm-form", %{
      asset: %{
        account_id: account.id,
        name: "Collector Car",
        linked_loan_id: "",
        acquisition_cost: "",
        ownership_type: "individual",
        ownership_details: "",
        location: "Garage",
        notes: "",
        acquired_on: "",
        documents_text: "title.pdf"
      }
    })
    |> render_submit()

    rendered = render(view)
    assert rendered =~ "Vehicle added from the reviewed MarketCheck estimate."
    assert rendered =~ "Collector Car"
    assert rendered =~ "Gross value"
    assert rendered =~ "Net equity"

    collector_car = Enum.find(Assets.list_assets(user), &(&1.name == "Collector Car"))

    view
    |> element(~s(button[phx-click="view-asset"][phx-value-id="#{collector_car.id}"]))
    |> render_click()

    assert render(view) =~ "Record manual valuation"
    assert render(view) =~ "Vehicle details"
    assert has_element?(view, "#asset-debt-link-form")

    view
    |> form("#asset-debt-link-form", %{
      asset: %{linked_loan_id: vehicle_loan.id}
    })
    |> render_submit()

    rendered = render(view)
    assert rendered =~ "Linked debt updated."
    assert rendered =~ "USD 18000.00"

    collector_car = Assets.get_asset!(user, collector_car.id)
    assert collector_car.linked_loan_id == vehicle_loan.id

    render_submit(view, "record-valuation", %{
      "asset_valuation" => %{
        "amount" => "50000",
        "currency" => "USD",
        "valued_on" => "2026-07-27",
        "mileage" => "126000",
        "source" => "provider",
        "provider_key" => "forged-provider"
      }
    })

    rendered = render(view)
    assert rendered =~ "Valuation recorded without replacing prior history."
    assert rendered =~ "Provider estimate"
    assert rendered =~ "Manual value"
    assert rendered =~ "Depreciation"
    assert rendered =~ "USD 2000.00"
    assert rendered =~ "+1000 miles"

    assert {:ok, valuations} = Assets.list_asset_valuations(user, collector_car)
    assert length(valuations) == 2
    assert Decimal.equal?(hd(valuations).amount, Decimal.new("50000"))
    assert hd(valuations).source == "manual"
    assert hd(valuations).provider_key == nil
  end

  test "assets page uses a compact form for non-vehicle assets", %{conn: conn} do
    {:ok, %{conn: conn}} = register_and_log_in_user(%{conn: conn})
    {:ok, view, _html} = live(conn, ~p"/app/assets")

    view |> element("button", "Add asset") |> render_click()

    view
    |> form("#asset-type-form", %{asset_setup: %{type: "equipment"}})
    |> render_change()

    assert has_element?(view, "#asset-form")
    refute has_element?(view, "#vehicle-lookup-form")
    assert has_element?(view, "#asset-form details", "More details")

    view
    |> form("#asset-form", %{
      asset: %{
        asset_type: "equipment",
        name: "Workshop tools",
        valuation_amount: "2500",
        valuation_currency: "USD",
        ownership_type: "individual"
      }
    })
    |> render_submit()

    assert render(view) =~ "Asset added successfully."
    assert render(view) =~ "Workshop tools"
  end

  test "assets page presents provider ranges ahead of point estimates", %{conn: conn} do
    {:ok, %{conn: conn, user: user}} = register_and_log_in_user(%{conn: conn})
    asset = unlinked_asset_fixture(user, %{name: "Range vehicle"})

    assert {:ok, %{asset: updated}} =
             Assets.record_valuation(user, asset, %{
               amount: "20000",
               currency: "USD",
               source: "provider",
               provider_key: "marketcheck",
               valued_on: ~D[2026-07-27],
               mileage: 50_000,
               value_low: "18000",
               value_high: "22000",
               confidence: "medium"
             })

    {:ok, view, _html} = live(conn, ~p"/app/assets")

    view
    |> element(~s(button[phx-click="view-asset"][phx-value-id="#{updated.id}"]))
    |> render_click()

    rendered = render(view)
    assert rendered =~ "USD 18000.00 – USD 22000.00"
    assert rendered =~ "Point estimate: USD 20000.00"
    assert rendered =~ "MarketCheck estimate"
    assert rendered =~ "Medium confidence"
  end

  defp restore_env(key, nil), do: Application.delete_env(:money_tree, key)
  defp restore_env(key, value), do: Application.put_env(:money_tree, key, value)

  defp assert_before(html, left, right) do
    assert {left_index, _length} = :binary.match(html, left)
    assert {right_index, _length} = :binary.match(html, right)
    assert left_index < right_index
  end
end
