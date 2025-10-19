defmodule MoneyTreeWeb.TransfersLiveTest do
  use MoneyTreeWeb.ConnCase, async: true

  import MoneyTree.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Decimal
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Repo
  alias MoneyTreeWeb.Auth

  setup %{conn: conn} do
    user = user_fixture()
    %{token: token} = session_fixture(user, %{context: "test"})

    source_account =
      account_fixture(user, %{name: "Checking", current_balance: Decimal.new("500.00"), available_balance: Decimal.new("400.00")})

    destination_account =
      account_fixture(user, %{name: "Savings", current_balance: Decimal.new("100.00"), available_balance: Decimal.new("100.00")})

    {:ok,
     conn: authed_conn(conn, token),
     user: user,
     source_account: source_account,
     destination_account: destination_account}
  end

  test "validates insufficient funds", %{conn: conn, source_account: source, destination_account: destination} do
    {:ok, view, _html} = live(conn, ~p"/app/transfers")

    form =
      form(view, "#transfer-form",
        transfer: %{
          "source_account_id" => source.id,
          "destination_account_id" => destination.id,
          "amount" => "1000.00"
        }
      )

    html = render_submit(form)
    assert html =~ "exceeds available balance"
  end

  test "requires step-up confirmation when requested", %{conn: conn, source_account: source, destination_account: destination} do
    {:ok, view, _html} = live(conn, ~p"/app/transfers")

    view |> element("button", "Require step-up") |> render_click()

    form =
      form(view, "#transfer-form",
        transfer: %{
          "source_account_id" => source.id,
          "destination_account_id" => destination.id,
          "amount" => "50.00"
        }
      )

    html = render_submit(form)
    assert html =~ "Complete step-up verification"

    view |> element("button", "Step-up completed") |> render_click()
    html = render_submit(form)
    assert html =~ "Transfer scheduled successfully"
  end

  test "applies transfers and updates balances", %{conn: conn, source_account: source, destination_account: destination, user: user} do
    {:ok, view, _html} = live(conn, ~p"/app/transfers")

    form =
      form(view, "#transfer-form",
        transfer: %{
          "source_account_id" => source.id,
          "destination_account_id" => destination.id,
          "amount" => "75.50",
          "memo" => "Monthly savings"
        }
      )

    html = render_submit(form)
    assert html =~ "Transfer scheduled successfully"

    updated_source = Repo.get!(Account, source.id)
    updated_destination = Repo.get!(Account, destination.id)

    assert Decimal.equal?(updated_source.current_balance, Decimal.new("424.50"))
    assert Decimal.equal?(updated_destination.current_balance, Decimal.new("175.50"))

    assert render(view) =~ "Monthly savings"
    assert render(view) =~ "Checking"
    assert render(view) =~ "Savings"
  end

  defp authed_conn(conn, token) do
    cookie_name = Auth.session_cookie_name()

    conn
    |> recycle()
    |> init_test_session(%{user_token: token})
    |> put_req_cookie(cookie_name, token)
  end
end
