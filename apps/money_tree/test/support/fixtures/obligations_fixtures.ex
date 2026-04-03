defmodule MoneyTree.ObligationsFixtures do
  @moduledoc """
  Helpers for creating obligations and matching transactions during tests.
  """

  alias Decimal
  alias MoneyTree.Obligations
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction

  import MoneyTree.AccountsFixtures

  def obligation_fixture(user, attrs \\ %{}) do
    attrs = Map.new(attrs)

    account =
      Map.get_lazy(attrs, :linked_funding_account, fn ->
        account_fixture(user, %{name: "Household Checking", type: "depository", subtype: "checking"})
      end)

    params =
      %{
        creditor_payee: Map.get(attrs, :creditor_payee, "Example Card"),
        due_day: Map.get(attrs, :due_day, 15),
        due_rule: Map.get(attrs, :due_rule, "calendar_day"),
        minimum_due_amount: Map.get(attrs, :minimum_due_amount, Decimal.new("75.00")),
        currency: Map.get(attrs, :currency, account.currency || "USD"),
        grace_period_days: Map.get(attrs, :grace_period_days, 2),
        alert_preferences: Map.get(attrs, :alert_preferences, %{}),
        active: Map.get(attrs, :active, true),
        linked_funding_account_id: account.id
      }

    {:ok, obligation} = Obligations.create_obligation(user, params)
    Repo.preload(obligation, [:user, :linked_funding_account])
  end

  def obligation_payment_fixture(account, attrs \\ %{}) do
    attrs = Map.new(attrs)

    params = %{
      external_id: "payment-#{System.unique_integer([:positive])}",
      amount: Map.get(attrs, :amount, Decimal.new("-80.00")),
      currency: Map.get(attrs, :currency, account.currency || "USD"),
      type: Map.get(attrs, :type, "ach"),
      posted_at:
        Map.get(attrs, :posted_at, DateTime.utc_now() |> DateTime.truncate(:second)),
      description: Map.get(attrs, :description, "Payment to Example Card"),
      merchant_name: Map.get(attrs, :merchant_name, "Example Card"),
      status: Map.get(attrs, :status, "posted"),
      account_id: account.id
    }

    %Transaction{}
    |> Transaction.changeset(params)
    |> Repo.insert!()
  end
end
