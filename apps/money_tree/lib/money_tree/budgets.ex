defmodule MoneyTree.Budgets do
  @moduledoc """
  Budget aggregation helpers used by the dashboard experience.

  The implementation favours deterministic, testable behaviour so the LiveView can
  render meaningful placeholders even when only a handful of transactions exist.
  """

  import Ecto.Query, warn: false

  alias Decimal
  alias MoneyTree.Accounts
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction
  alias MoneyTree.Users.User

  @type budget_entry :: %{
          name: String.t(),
          period: String.t(),
          currency: String.t(),
          allocated: String.t(),
          allocated_masked: String.t(),
          spent: String.t(),
          spent_masked: String.t(),
          remaining: String.t(),
          remaining_masked: String.t(),
          status: :under | :approaching | :over
        }

  @default_budgets [
    %{name: "Housing", allocation: Decimal.new("2500.00"), period: "Monthly"},
    %{name: "Groceries", allocation: Decimal.new("600.00"), period: "Monthly"},
    %{name: "Transportation", allocation: Decimal.new("300.00"), period: "Monthly"},
    %{name: "Lifestyle", allocation: Decimal.new("400.00"), period: "Monthly"}
  ]

  @doc """
  Builds per-category budget totals using recent transaction activity.
  """
  @spec aggregate_totals(User.t() | binary(), keyword()) :: [budget_entry()]
  def aggregate_totals(user, opts \\ []) do
    budgets = Keyword.get(opts, :budgets, @default_budgets)
    since = Keyword.get(opts, :since, default_since())
    default_currency = Keyword.get(opts, :currency) || derive_currency(user, budgets)

    totals = spending_by_category(user, since)

    Enum.map(budgets, fn budget ->
      build_budget_entry(budget, totals, default_currency, opts)
    end)
  end

  defp build_budget_entry(%{name: name} = budget, totals, default_currency, opts) do
    key = String.downcase(name)
    info = Map.get(totals, key, %{currency: default_currency, total: Decimal.new("0")})

    allocation = cast_decimal(Map.get(budget, :allocation, Decimal.new("0")))
    spend = info.total
    currency = Map.get(budget, :currency) || info.currency || default_currency
    remaining = Decimal.sub(allocation, spend)

    %{
      name: name,
      period: Map.get(budget, :period, "Monthly"),
      currency: currency,
      allocated: Accounts.format_money(allocation, currency, opts),
      allocated_masked: Accounts.mask_money(allocation, currency, opts),
      spent: Accounts.format_money(spend, currency, opts),
      spent_masked: Accounts.mask_money(spend, currency, opts),
      remaining: Accounts.format_money(remaining, currency, opts),
      remaining_masked: Accounts.mask_money(remaining, currency, opts),
      status: budget_status(allocation, spend)
    }
  end

  defp spending_by_category(user, since) do
    from(transaction in Transaction,
      join: account in subquery(Accounts.accessible_accounts_query(user)),
      on: transaction.account_id == account.id,
      where: is_nil(^since) or is_nil(transaction.posted_at) or transaction.posted_at >= ^since,
      group_by: [transaction.category, transaction.currency],
      select:
        {coalesce(transaction.category, "Uncategorized"), transaction.currency,
         sum(fragment("ABS(?)", transaction.amount))}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {category, currency, total}, acc ->
      key = category |> to_string() |> String.downcase()
      currency = currency || "USD"
      total = cast_decimal(total)

      Map.update(acc, key, %{currency: currency, total: total}, fn existing ->
        %{
          existing
          | total: Decimal.add(existing.total, total),
            currency: existing.currency || currency
        }
      end)
    end)
  end

  defp budget_status(allocation, spend) do
    cond do
      Decimal.compare(spend, allocation) == :gt -> :over
      Decimal.compare(allocation, Decimal.new("0")) == :eq -> :under
      Decimal.compare(spend, Decimal.mult(allocation, Decimal.new("0.9"))) == :gt -> :approaching
      true -> :under
    end
  end

  defp cast_decimal(%Decimal{} = value), do: value

  defp cast_decimal(value) do
    case Decimal.cast(value) do
      {:ok, decimal} -> decimal
      :error -> Decimal.new("0")
    end
  end

  defp derive_currency(user, budgets) do
    budgets
    |> Enum.find_value(& &1[:currency])
    |> case do
      nil ->
        user
        |> Accounts.list_accessible_accounts(order_by: [{:asc, :inserted_at}])
        |> List.first()
        |> case do
          nil -> "USD"
          account -> account.currency || "USD"
        end

      currency ->
        currency
    end
  end

  defp default_since do
    Date.utc_today()
    |> Date.beginning_of_month()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end
end
