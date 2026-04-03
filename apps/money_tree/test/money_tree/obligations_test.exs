defmodule MoneyTree.ObligationsTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures
  import MoneyTree.ObligationsFixtures

  alias MoneyTree.Obligations
  alias MoneyTree.Notifications.Event
  alias MoneyTree.Repo

  describe "check_all/1" do
    test "creates upcoming and overdue durable events and resolves overdue after payment" do
      user = user_fixture()

      upcoming =
        obligation_fixture(user, %{
          creditor_payee: "Utilities",
          due_day: 31,
          grace_period_days: 0
        })

      overdue =
        obligation_fixture(user, %{
          creditor_payee: "Travel Card",
          due_day: 15,
          grace_period_days: 2
        })

      assert :ok = Obligations.check_all(~D[2026-03-29])

      assert Repo.get_by!(Event, obligation_id: upcoming.id, status: "upcoming")
      overdue_event = Repo.get_by!(Event, obligation_id: overdue.id, status: "overdue")
      assert overdue_event.resolved_at == nil

      obligation_payment_fixture(overdue.linked_funding_account, %{
        posted_at: ~U[2026-03-29 12:00:00Z],
        description: "Travel Card payment",
        merchant_name: "Travel Card"
      })

      assert :ok = Obligations.check_all(~D[2026-03-29])

      assert Repo.get_by!(Event, obligation_id: overdue.id, status: "recovered")
      assert Repo.get!(Event, overdue_event.id).resolved_at
    end
  end
end
