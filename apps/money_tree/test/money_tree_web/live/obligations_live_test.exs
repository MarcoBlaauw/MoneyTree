defmodule MoneyTreeWeb.ObligationsLiveTest do
  use MoneyTreeWeb.ConnCase, async: true

  import MoneyTree.AccountsFixtures
  import MoneyTree.ObligationsFixtures
  import Phoenix.LiveViewTest

  alias MoneyTree.Notifications

  setup :register_and_log_in_user

  test "renders durable alert history and selected event details", %{conn: conn, user: user} do
    obligation = obligation_fixture(user, %{creditor_payee: "Travel Card"})

    {:ok, older_event} =
      Notifications.record_event(%{
        user_id: user.id,
        obligation_id: obligation.id,
        kind: "payment_obligation",
        status: "upcoming",
        severity: "info",
        title: "Travel Card due soon",
        message: "Travel Card payment is due soon.",
        action: "Schedule payment",
        event_date: ~D[2026-04-05],
        occurred_at: ~U[2026-04-02 08:00:00Z],
        metadata: %{},
        dedupe_key: "obligations-live-history-older-#{obligation.id}"
      })

    {:ok, selected_event} =
      Notifications.record_event(%{
        user_id: user.id,
        obligation_id: obligation.id,
        kind: "payment_obligation",
        status: "overdue",
        severity: "critical",
        title: "Travel Card overdue",
        message: "Travel Card payment is now overdue.",
        action: "Verify payment",
        event_date: ~D[2026-04-03],
        occurred_at: ~U[2026-04-03 09:00:00Z],
        metadata: %{},
        dedupe_key: "obligations-live-history-selected-#{obligation.id}"
      })

    {:ok, _view, html} = live(conn, ~p"/app/obligations?event=#{selected_event.id}")

    assert html =~ "Recent alert history"
    assert html =~ "Travel Card overdue"
    assert html =~ "Travel Card due soon"
    assert html =~ "Alert details"
    assert html =~ "Verify payment"
    assert html =~ "Overdue"
    assert html =~ "Obligation"
    assert html =~ "Travel Card"

    assert String.contains?(html, selected_event.id)
    assert String.contains?(html, older_event.id)
  end

  test "ignores an unknown event id and shows the empty detail state", %{conn: conn, user: user} do
    obligation = obligation_fixture(user, %{creditor_payee: "Utilities"})

    {:ok, _event} =
      Notifications.record_event(%{
        user_id: user.id,
        obligation_id: obligation.id,
        kind: "payment_obligation",
        status: "due_today",
        severity: "warning",
        title: "Utilities due today",
        message: "Utilities are due today.",
        action: "Pay now",
        event_date: ~D[2026-04-03],
        occurred_at: ~U[2026-04-03 10:00:00Z],
        metadata: %{},
        dedupe_key: "obligations-live-history-empty-detail-#{obligation.id}"
      })

    {:ok, _view, html} = live(conn, ~p"/app/obligations?event=missing-event-id")

    assert html =~ "Recent alert history"
    assert html =~ "Utilities due today"
    assert html =~ "Select an event from history to inspect details."
  end

  test "creates an obligation from the live form", %{conn: conn, user: user} do
    funding_account =
      account_fixture(user, %{name: "Primary Checking", type: "depository", subtype: "checking"})

    {:ok, view, _html} = live(conn, ~p"/app/obligations")

    view
    |> element("button[phx-click='new-obligation']")
    |> render_click()

    view
    |> form("#obligation-form",
      obligation: %{
        "creditor_payee" => "Gym Membership",
        "linked_funding_account_id" => funding_account.id,
        "due_rule" => "calendar_day",
        "due_day" => "12",
        "minimum_due_amount" => "55.25",
        "grace_period_days" => "3"
      }
    )
    |> render_submit()

    html = render(view)
    assert html =~ "Gym Membership"
    assert html =~ "on day 12"
  end

  test "edits and deletes an obligation from the list", %{conn: conn, user: user} do
    obligation = obligation_fixture(user, %{creditor_payee: "Phone Bill"})
    replacement_account = account_fixture(user, %{name: "Secondary Checking"})

    {:ok, view, _html} = live(conn, ~p"/app/obligations")

    view
    |> element("button[phx-click='edit-obligation'][phx-value-id='#{obligation.id}']")
    |> render_click()

    view
    |> form("#obligation-form",
      obligation: %{
        "creditor_payee" => "Updated Phone Bill",
        "linked_funding_account_id" => replacement_account.id,
        "due_rule" => "last_day_of_month",
        "due_day" => "",
        "minimum_due_amount" => "64.10",
        "grace_period_days" => "1"
      }
    )
    |> render_submit()

    assert render(view) =~ "Updated Phone Bill"

    view
    |> element("button[phx-click='delete-obligation'][phx-value-id='#{obligation.id}']")
    |> render_click()

    refute render(view) =~ "Updated Phone Bill"
  end
end
