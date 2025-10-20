defmodule MoneyTree.Accounts.DashboardMetricsTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures

  alias Decimal
  alias MoneyTree.Accounts
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction

  describe "running_card_balances/2" do
    test "returns utilization and trend data for credit accounts" do
      user = user_fixture()

      card =
        account_fixture(user, %{
          name: "Rewards",
          type: "credit",
          current_balance: Decimal.new("500.00"),
          available_balance: Decimal.new("200.00"),
          limit: Decimal.new("1000.00")
        })

      insert_transaction(card, Decimal.new("100.00"))

      [entry] = Accounts.running_card_balances(user)
      assert entry.account.name == "Rewards"
      assert entry.utilization_percent == Decimal.new("50.00")
      assert entry.trend_direction == :increasing
      assert entry.current_balance_masked =~ "••"
    end
  end

  describe "net_worth_snapshot/2" do
    test "sums assets and liabilities" do
      user = user_fixture()

      account_fixture(user, %{
        name: "Checking",
        type: "depository",
        current_balance: Decimal.new("10000.00")
      })

      account_fixture(user, %{
        name: "Savings",
        type: "depository",
        current_balance: Decimal.new("5000.00")
      })

      account_fixture(user, %{
        name: "Mortgage",
        type: "loan",
        subtype: "mortgage",
        current_balance: Decimal.new("3000.00")
      })

      snapshot = Accounts.net_worth_snapshot(user)

      assert snapshot.net_worth == "USD 12000.00"
      assert snapshot.assets == "USD 15000.00"
      assert snapshot.liabilities == "USD 3000.00"
      assert [%{label: "Savings"} | _] = snapshot.breakdown.assets
    end
  end

  describe "savings_and_investments_summary/2" do
    test "returns grouped totals" do
      user = user_fixture()

      account_fixture(user, %{
        name: "Emergency",
        type: "depository",
        subtype: "savings",
        current_balance: Decimal.new("2500.00")
      })

      account_fixture(user, %{
        name: "Brokerage",
        type: "investment",
        current_balance: Decimal.new("4000.00")
      })

      summary = Accounts.savings_and_investments_summary(user)

      assert summary.savings_total == "USD 2500.00"
      assert summary.investment_total == "USD 4000.00"
      assert summary.combined_total == "USD 6500.00"
      assert Enum.any?(summary.savings_accounts, &(&1.name == "Emergency"))
      assert Enum.any?(summary.investment_accounts, &(&1.name == "Brokerage"))
    end
  end

  describe "dashboard_summary/2" do
    test "includes formatted financial metadata" do
      user = user_fixture()

      account =
        account_fixture(user, %{
          name: "Premier Savings",
          currency: "USD",
          type: "depository",
          apr: Decimal.from_float(3.25),
          minimum_balance: Decimal.new(1000),
          maximum_balance: Decimal.new(20000),
          fee_schedule: "Monthly fee waived with $1,000 minimum",
          current_balance: Decimal.new("2500.00")
        })

      summary = Accounts.dashboard_summary(user)
      [entry | _] = summary.accounts

      assert entry.account.id == account.id
      assert entry.apr == "3.25%"
      assert entry.minimum_balance == "USD 1000.00"
      assert entry.maximum_balance == "USD 20000.00"
      assert entry.minimum_balance_masked =~ "•"
      assert entry.fee_schedule =~ "Monthly fee"
    end
  end

  defp insert_transaction(%Account{} = account, amount) do
    params = %{
      external_id: System.unique_integer([:positive]) |> Integer.to_string(),
      amount: amount,
      currency: account.currency,
      type: "card",
      posted_at: DateTime.utc_now(),
      description: "Test",
      status: "posted",
      account_id: account.id
    }

    %Transaction{}
    |> Transaction.changeset(params)
    |> Repo.insert!()
  end
end
