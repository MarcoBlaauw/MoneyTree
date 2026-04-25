defmodule MoneyTreeWeb.ImportExportControllerTest do
  use MoneyTreeWeb.ConnCase

  import MoneyTree.AccountsFixtures

  alias Decimal
  alias MoneyTree.Budgets
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction
  alias MoneyTreeWeb.Auth

  @session_cookie Auth.session_cookie_name()

  test "downloads transactions csv for authenticated user", %{conn: conn} do
    user = user_fixture()
    %{token: token} = session_fixture(user)
    account = account_fixture(user, %{name: "Checking Export"})

    %Transaction{}
    |> Transaction.changeset(%{
      account_id: account.id,
      external_id: "txn-export-1",
      source: "manual_import",
      posted_at: ~U[2026-04-20 12:00:00Z],
      amount: Decimal.new("-12.34"),
      currency: "USD",
      description: "Coffee",
      status: "posted"
    })
    |> Repo.insert!()

    conn =
      conn
      |> put_req_header("cookie", "#{@session_cookie}=#{token}")
      |> get(~p"/app/import-export/transactions.csv?days=30")

    assert response(conn, 200) =~ "transaction_id,account_name,posted_at,amount"
    assert response(conn, 200) =~ "Checking Export"
    assert response(conn, 200) =~ "Coffee"
    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/csv"
  end

  test "downloads budgets csv for authenticated user", %{conn: conn} do
    user = user_fixture()
    %{token: token} = session_fixture(user)

    {:ok, _budget} =
      Budgets.create_budget(user, %{
        name: "Housing",
        period: :monthly,
        allocation_amount: "2500.00",
        currency: "USD",
        entry_type: :expense,
        variability: :fixed
      })

    conn =
      conn
      |> put_req_header("cookie", "#{@session_cookie}=#{token}")
      |> get(~p"/app/import-export/budgets.csv")

    assert response(conn, 200) =~ "budget_id,name,period,entry_type,variability"
    assert response(conn, 200) =~ "Housing"
    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/csv"
  end
end
