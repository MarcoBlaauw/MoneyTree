defmodule MoneyTreeWeb.ImportExportLiveTest do
  use MoneyTreeWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import MoneyTree.AccountsFixtures
  import Phoenix.LiveViewTest

  alias MoneyTree.AI
  alias MoneyTree.ManualImports
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction
  alias MoneyTree.XLSXFixture

  setup :register_and_log_in_user

  test "stages and commits CSV imports from the import/export page", %{conn: conn, user: user} do
    account = account_fixture(user, %{name: "Import Checking"})

    {:ok, view, html} = live(conn, ~p"/app/import-export")

    assert html =~ "Import transactions"
    assert html =~ "Export data"
    refute html =~ "Planned: CSV import and manual upload review workflow."
    refute html =~ "Planned: transaction and budget exports with audit-friendly metadata."

    upload =
      file_input(view, "#import-form", :import_file, [
        %{
          name: "sample.csv",
          content: """
          Date,Description,Amount,Status
          2026-04-20,Coffee,-5.25,Posted
          2026-04-21,Payroll,2000.00,Posted
          """,
          type: "text/csv"
        }
      ])

    render_upload(upload, "sample.csv")

    view
    |> form("#import-form", %{
      "import" => %{
        "account_id" => account.id
      }
    })
    |> render_submit()

    rendered = render(view)
    assert rendered =~ "Staged 2 rows."
    assert rendered =~ "Coffee"
    assert rendered =~ "Payroll"

    view
    |> element("button[phx-click='commit-import']")
    |> render_click()

    rendered = render(view)
    assert rendered =~ "Import committed."

    transactions =
      from(transaction in Transaction,
        where: transaction.account_id == ^account.id and transaction.source == "manual_import"
      )
      |> Repo.all()

    assert length(transactions) == 2

    view
    |> element("button[phx-click='rollback-import']")
    |> render_click()

    rendered = render(view)
    assert rendered =~ "Import batch rolled back."

    remaining_transactions =
      from(transaction in Transaction,
        where: transaction.account_id == ^account.id and transaction.source == "manual_import"
      )
      |> Repo.all()

    assert remaining_transactions == []
  end

  test "can create a manual account directly from import/export page", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/app/import-export")

    assert html =~ "Need an account first?"

    view
    |> form("#manual-account-form", %{
      "manual_account" => %{
        "name" => "Manual Import Account",
        "type" => "depository",
        "subtype" => "checking",
        "currency" => "USD",
        "current_balance" => "100.00"
      }
    })
    |> render_submit()

    rendered = render(view)
    assert rendered =~ "Manual account created and selected for import."
    assert rendered =~ "Manual Import Account (USD)"
  end

  test "stages and commits XLSX imports from the import/export page", %{conn: conn, user: user} do
    account = account_fixture(user, %{name: "XLSX Import Checking"})

    {:ok, view, _html} = live(conn, ~p"/app/import-export")

    xlsx =
      XLSXFixture.simple_workbook_binary([
        ["USAA Checking Export", "", "", ""],
        ["Posting Date", "Transaction Description", "Amount", "Status"],
        ["2026-04-20", "Coffee", -5.25, "Posted"],
        ["2026-04-21", "Payroll", 2000.00, "Posted"]
      ])

    upload =
      file_input(view, "#import-form", :import_file, [
        %{
          name: "sample.xlsx",
          content: xlsx,
          type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        }
      ])

    render_upload(upload, "sample.xlsx")

    view
    |> form("#import-form", %{
      "import" => %{
        "account_id" => account.id
      }
    })
    |> render_submit()

    rendered = render(view)
    assert rendered =~ "Staged 2 rows."
    assert rendered =~ "Coffee"
    assert rendered =~ "Payroll"

    view
    |> element("button[phx-click='commit-import']")
    |> render_click()

    rendered = render(view)
    assert rendered =~ "Import committed."

    transactions =
      from(transaction in Transaction,
        where: transaction.account_id == ^account.id and transaction.source == "manual_import"
      )
      |> Repo.all()

    assert length(transactions) == 2
  end

  test "generates and applies AI hints for staged import rows", %{conn: conn, user: user} do
    account = account_fixture(user, %{name: "AI Import Checking"})

    assert {:ok, _preference} =
             AI.update_settings(user, %{
               "local_ai_enabled" => true,
               "allow_ai_for_categorization" => true
             })

    {:ok, view, _html} = live(conn, ~p"/app/import-export")

    upload =
      file_input(view, "#import-form", :import_file, [
        %{
          name: "sample.csv",
          content: """
          Date,Description,Amount,Status
          2026-04-22,Trader Joe's,-51.35,Posted
          """,
          type: "text/csv"
        }
      ])

    render_upload(upload, "sample.csv")

    view
    |> form("#import-form", %{
      "import" => %{
        "account_id" => account.id
      }
    })
    |> render_submit()

    view
    |> element("button[phx-click='generate-import-ai-suggestions']")
    |> render_click()

    rendered = render(view)
    assert rendered =~ "AI run completed. 1 category hints are available."
    assert rendered =~ "AI run status: completed"
    assert rendered =~ "Refresh AI run status"
    assert rendered =~ "Groceries"

    view
    |> element("button[phx-click='accept-import-ai-suggestion']")
    |> render_click()

    rendered = render(view)
    assert rendered =~ "AI category hint applied to staged row."
    assert rendered =~ "Applied: Groceries"

    [latest_batch | _] = ManualImports.list_batches(user)
    [updated_row] = ManualImports.list_rows(user, latest_batch.id)
    assert updated_row.category_name_snapshot == "Groceries"
  end
end
