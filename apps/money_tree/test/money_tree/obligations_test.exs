defmodule MoneyTree.ObligationsTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures
  import MoneyTree.ObligationsFixtures

  alias Decimal
  alias MoneyTree.Obligations
  alias MoneyTree.Obligations.CheckWorker
  alias MoneyTree.Notifications.Event
  alias MoneyTree.Repo
  alias Oban.Job

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

    test "does not treat unmatched or below-minimum transactions as valid payments" do
      user = user_fixture()

      obligation =
        obligation_fixture(user, %{
          creditor_payee: "Travel Card",
          due_day: 15,
          minimum_due_amount: Decimal.new("100.00"),
          grace_period_days: 2
        })

      obligation_payment_fixture(obligation.linked_funding_account, %{
        posted_at: ~U[2026-03-16 09:00:00Z],
        amount: Decimal.new("-120.00"),
        description: "Payment to Other Card",
        merchant_name: "Other Card"
      })

      obligation_payment_fixture(obligation.linked_funding_account, %{
        posted_at: ~U[2026-03-16 11:00:00Z],
        amount: Decimal.new("-40.00"),
        description: "Travel Card autopay",
        merchant_name: "Travel Card"
      })

      assert :ok = Obligations.check_all(~D[2026-03-18])

      assert Repo.get_by!(Event,
               obligation_id: obligation.id,
               status: "overdue",
               event_date: ~D[2026-03-15]
             )
    end

    test "only marks overdue after the grace-period cutoff passes" do
      user = user_fixture()

      obligation =
        obligation_fixture(user, %{
          creditor_payee: "Utilities",
          due_day: 15,
          grace_period_days: 2
        })

      assert :ok = Obligations.check_all(~D[2026-03-17])

      refute Repo.get_by(Event,
               obligation_id: obligation.id,
               status: "overdue",
               event_date: ~D[2026-03-15]
             )

      assert :ok = Obligations.check_all(~D[2026-03-18])

      assert Repo.get_by!(Event,
               obligation_id: obligation.id,
               status: "overdue",
               event_date: ~D[2026-03-15]
             )
    end
  end

  describe "enqueue_check/1" do
    test "returns ok when scheduling the same date repeatedly" do
      target_date = ~D[2026-03-29]

      assert :ok = Obligations.enqueue_check(target_date)
      assert :ok = Obligations.enqueue_check(target_date)
    end
  end

  describe "CheckWorker.perform/1" do
    test "evaluates obligations for the provided date argument" do
      user = user_fixture()

      obligation =
        obligation_fixture(user, %{
          creditor_payee: "Utilities",
          due_day: 31,
          grace_period_days: 0
        })

      assert :ok = CheckWorker.perform(%Job{args: %{"date" => "2026-03-29"}})

      assert Repo.get_by!(Event,
               obligation_id: obligation.id,
               status: "upcoming",
               event_date: ~D[2026-03-31]
             )
    end
  end
end
