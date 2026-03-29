defmodule MoneyTree.RecurringTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures

  alias Decimal
  alias MoneyTree.Recurring
  alias MoneyTree.Recurring.Anomaly
  alias MoneyTree.Recurring.Series
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction

  describe "detect_for_user/2" do
    test "handles month-length differences as monthly cadence" do
      user = user_fixture()
      account = account_fixture(user, %{name: "Rent Account"})

      insert_tx(account, "rent-1", "-1200.00", ~U[2026-01-31 12:00:00Z], "Rent", "Housing")
      insert_tx(account, "rent-2", "-1200.00", ~U[2026-02-28 12:00:00Z], "Rent", "Housing")
      insert_tx(account, "rent-3", "-1200.00", ~U[2026-03-31 12:00:00Z], "Rent", "Housing")

      assert {:ok, %{series_updated: 1}} = Recurring.detect_for_user(user.id)

      series = Repo.one!(Series)
      assert series.cadence == "monthly"
      assert series.cadence_days == 30
      assert series.status == "active"
      assert Decimal.compare(series.confidence, Decimal.new("0.6")) in [:gt, :eq]
    end

    test "absorbs holiday shifts for weekly cadence" do
      user = user_fixture()
      account = account_fixture(user, %{name: "Payroll"})

      insert_tx(account, "pay-1", "2200.00", ~U[2025-12-05 12:00:00Z], "Payroll", "Income")
      insert_tx(account, "pay-2", "2200.00", ~U[2025-12-12 12:00:00Z], "Payroll", "Income")
      insert_tx(account, "pay-3", "2200.00", ~U[2025-12-19 12:00:00Z], "Payroll", "Income")
      insert_tx(account, "pay-4", "2200.00", ~U[2025-12-27 12:00:00Z], "Payroll", "Income")

      assert {:ok, _} = Recurring.detect_for_user(user.id)

      series = Repo.one!(Series)
      assert series.cadence == "weekly"
      assert series.expected_window_days >= 2
      assert Repo.aggregate(Anomaly, :count, :id) == 0
    end

    test "deduplicates pending/posted pairs" do
      user = user_fixture()
      account = account_fixture(user, %{name: "Subscriptions"})

      insert_tx(account, "sub-1-posted", "-15.99", ~U[2026-01-02 08:00:00Z], "Music Stream", "Subscription", "posted")

      insert_tx(
        account,
        "sub-2-pending",
        "-15.99",
        ~U[2026-02-02 08:00:00Z],
        "Music Stream",
        "Subscription",
        "pending"
      )

      insert_tx(account, "sub-2-posted", "-15.99", ~U[2026-02-03 08:00:00Z], "Music Stream", "Subscription", "posted")
      insert_tx(account, "sub-3-posted", "-15.99", ~U[2026-03-03 08:00:00Z], "Music Stream", "Subscription", "posted")

      assert {:ok, %{series_updated: 1}} = Recurring.detect_for_user(user.id)

      series = Repo.one!(Series)
      assert series.cadence == "monthly"
      assert series.last_seen_at == ~U[2026-03-03 08:00:00Z]
    end

    test "records missing-cycle and unusual-amount anomalies" do
      user = user_fixture()
      account = account_fixture(user, %{name: "Utilities"})

      insert_tx(account, "util-1", "-100.00", ~U[2025-06-01 00:00:00Z], "Power Co", "Utilities")
      insert_tx(account, "util-2", "-100.00", ~U[2025-07-01 00:00:00Z], "Power Co", "Utilities")
      insert_tx(account, "util-3", "-180.00", ~U[2025-08-01 00:00:00Z], "Power Co", "Utilities")

      assert {:ok, _} = Recurring.detect_for_user(user.id)

      types =
        Anomaly
        |> Repo.all()
        |> Enum.map(& &1.anomaly_type)

      assert "missing_cycle" in types
      assert "unusual_amount" in types
    end
  end

  defp insert_tx(account, external_id, amount, posted_at, description, category, status \\ "posted") do
    params = %{
      external_id: external_id,
      amount: Decimal.new(amount),
      currency: account.currency,
      type: "card",
      posted_at: posted_at,
      description: description,
      merchant_name: description,
      category: category,
      status: status,
      account_id: account.id
    }

    %Transaction{}
    |> Transaction.changeset(params)
    |> Repo.insert!()
  end
end
