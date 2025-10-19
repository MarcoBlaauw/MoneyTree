defmodule MoneyTreeWeb.TransfersLiveTest do
  use MoneyTreeWeb.ConnCase, async: true

  import MoneyTree.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Decimal
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Repo

  setup context do
    {:ok, context} = register_and_log_in_user(context)

    source_account =
      account_fixture(context.user, %{
        name: "Checking",
        current_balance: Decimal.new("500.00"),
        available_balance: Decimal.new("400.00")
      })

    destination_account =
      account_fixture(context.user, %{
        name: "Savings",
        current_balance: Decimal.new("100.00"),
        available_balance: Decimal.new("100.00")
      })

    {:ok,
     Map.merge(context, %{
       source_account: source_account,
       destination_account: destination_account
     })}
  end

  test "includes CSP meta tags and validates insufficient funds", %{
    conn: conn,
    source_account: source,
    destination_account: destination
  } do
    {:ok, view, html} = live(conn, ~p"/app/transfers")

    assert html =~ "<meta name=\"csp-nonce\""
    assert html =~ "<meta name=\"csp-script-src\""
    assert html =~ "<meta name=\"csp-style-src\""

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

  test "requires step-up confirmation when requested", %{
    conn: conn,
    source_account: source,
    destination_account: destination
  } do
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

  test "applies transfers and updates balances", %{
    conn: conn,
    source_account: source,
    destination_account: destination,
    user: user
  } do
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

  test "locking disables transfer confirmation until unlocked", %{
    conn: conn,
    source_account: source,
    destination_account: destination
  } do
    {:ok, view, _html} = live(conn, ~p"/app/transfers")

    view |> element("button", "Lock") |> render_click()

    form =
      form(view, "#transfer-form",
        transfer: %{
          "source_account_id" => source.id,
          "destination_account_id" => destination.id,
          "amount" => "10.00"
        }
      )

    assert render_submit(form) =~ "Unlock transfers before confirming a transfer."

    view |> element("button", "Unlock") |> render_click()

    assert render_submit(form) =~ "Transfer scheduled successfully"
  end
end
