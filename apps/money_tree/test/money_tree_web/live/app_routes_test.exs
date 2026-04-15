defmodule MoneyTreeWeb.AppRoutesTest do
  use MoneyTreeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "browser authentication" do
    test "redirects unauthenticated users", %{conn: conn} do
      paths = [
        ~p"/app/dashboard",
        ~p"/app/accounts",
        ~p"/app/accounts/connect",
        ~p"/app/transactions",
        ~p"/app/transactions/categorization",
        ~p"/app/obligations",
        ~p"/app/assets",
        ~p"/app/transfers",
        ~p"/app/budgets",
        ~p"/app/settings",
        ~p"/app/categorization",
        ~p"/app/import-export"
      ]

      Enum.each(paths, fn path ->
        response_conn = conn |> recycle() |> get(path)
        assert redirected_to(response_conn) == ~p"/login"
      end)
    end

    test "allows authenticated users to mount LiveViews", %{conn: conn} do
      {:ok, %{conn: authed_conn}} = register_and_log_in_user(%{conn: conn})

      {:ok, dashboard, _html} = live(authed_conn, ~p"/app/dashboard")

      assert render(dashboard) =~ "Dashboard"

      {:ok, accounts, _html} = live(authed_conn, ~p"/app/accounts")
      assert render(accounts) =~ "Linked institutions"

      {:ok, transactions, _html} = live(authed_conn, ~p"/app/transactions")
      assert render(transactions) =~ "Recent transactions"

      {:ok, obligations, _html} = live(authed_conn, ~p"/app/obligations")
      assert render(obligations) =~ "Obligations"

      {:ok, assets, _html} = live(authed_conn, ~p"/app/assets")
      assert render(assets) =~ "Assets"

      {:ok, transfers, _html} = live(authed_conn, ~p"/app/transfers")

      assert render(transfers) =~ "Transfers"

      {:ok, budgets, _html} = live(authed_conn, ~p"/app/budgets")
      assert render(budgets) =~ "Budgets"

      {:ok, settings, _html} = live(authed_conn, ~p"/app/settings")
      assert render(settings) =~ "Settings"

      {:ok, categorization, _html} = live(authed_conn, ~p"/app/transactions/categorization")
      assert render(categorization) =~ "Categorization rules"

      {:ok, import_export, _html} = live(authed_conn, ~p"/app/import-export")
      assert render(import_export) =~ "Import / Export"
    end

    test "keeps legacy utility routes as compatibility redirects", %{conn: conn} do
      {:ok, %{conn: authed_conn}} = register_and_log_in_user(%{conn: conn})

      connect = get(recycle(authed_conn), ~p"/app/accounts/connect")
      assert redirected_to(connect) == ~p"/app/accounts"

      categorization = get(recycle(authed_conn), ~p"/app/categorization")
      assert redirected_to(categorization) == ~p"/app/transactions/categorization"
    end
  end
end
