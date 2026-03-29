defmodule MoneyTree.Budgets.Planner do
  @moduledoc """
  Produces budget recommendations from rolling historical spend windows.
  """

  import Ecto.Query, warn: false

  alias Decimal
  alias MoneyTree.Accounts
  alias MoneyTree.Budgets.Budget
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction

  @months_windows [3, 6, 12]

  @type recommendation :: %{
          budget_id: binary(),
          budget_name: String.t(),
          currency: String.t(),
          expected_spend: %{optional(integer()) => Decimal.t()},
          volatility_score: Decimal.t(),
          suggested_allocation: Decimal.t(),
          delta: Decimal.t(),
          direction: :increase | :decrease | :steady,
          explanation: String.t()
        }

  @spec recommend(binary() | map(), keyword()) :: [recommendation()]
  def recommend(user, opts \\ []) do
    budgets = Keyword.get(opts, :budgets) || Keyword.get_lazy(opts, :budgets, fn -> [] end)

    resolved_budgets =
      case budgets do
        [] ->
          user
          |> MoneyTree.Budgets.list_budgets()
          |> Enum.filter(&(&1.entry_type == :expense))

        list ->
          Enum.filter(list, &(&1.entry_type == :expense))
      end

    monthly_totals = monthly_spending_by_category(user)

    Enum.map(resolved_budgets, fn budget ->
      build_recommendation(budget, monthly_totals)
    end)
  end

  defp build_recommendation(%Budget{} = budget, monthly_totals) do
    category_key = normalize_category_key(budget.name)
    history = Map.get(monthly_totals, category_key, [])

    expected =
      @months_windows
      |> Enum.map(fn window -> {window, rolling_average(history, window)} end)
      |> Map.new()

    expected_weighted = weighted_expectation(expected)
    volatility_score = volatility(history, expected[6] || expected_weighted)

    suggested =
      expected_weighted
      |> apply_target_mode(budget.target_mode, volatility_score)
      |> apply_bounds(budget.minimum_amount, budget.maximum_amount)
      |> Decimal.round(2)

    current = budget.allocation_amount || Decimal.new("0")
    delta = Decimal.sub(suggested, current)

    %{
      budget_id: budget.id,
      budget_name: budget.name,
      currency: budget.currency || "USD",
      expected_spend: expected,
      volatility_score: volatility_score,
      suggested_allocation: suggested,
      delta: delta,
      direction: direction(delta),
      explanation: explanation(budget, expected, volatility_score, delta)
    }
  end

  defp monthly_spending_by_category(user) do
    twelve_months_ago = Date.utc_today() |> Date.beginning_of_month() |> Date.add(-365)
    since = DateTime.new!(twelve_months_ago, ~T[00:00:00], "Etc/UTC")

    from(transaction in Transaction,
      join: account in subquery(Accounts.accessible_accounts_query(user)),
      on: transaction.account_id == account.id,
      where: not is_nil(transaction.posted_at) and transaction.posted_at >= ^since,
      group_by: [
        fragment("date_trunc('month', ?)", transaction.posted_at),
        transaction.category
      ],
      select: {
        transaction.category,
        fragment("date_trunc('month', ?)", transaction.posted_at),
        sum(transaction.amount)
      }
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {category, month, total}, acc ->
      key = normalize_category_key(category)
      spend = total |> cast_decimal() |> Decimal.abs()

      Map.update(acc, key, [{month, spend}], &[{month, spend} | &1])
    end)
    |> Enum.into(%{}, fn {key, spends} ->
      sorted =
        spends
        |> Enum.sort_by(fn {month, _} -> month end, {:desc, DateTime})
        |> Enum.map(fn {_month, spend} -> spend end)

      {key, sorted}
    end)
  end

  defp rolling_average(history, window) do
    history
    |> Enum.take(window)
    |> average()
  end

  defp weighted_expectation(expected) do
    three = Map.get(expected, 3, Decimal.new("0"))
    six = Map.get(expected, 6, Decimal.new("0"))
    twelve = Map.get(expected, 12, Decimal.new("0"))

    three
    |> Decimal.mult(Decimal.new("0.5"))
    |> Decimal.add(Decimal.mult(six, Decimal.new("0.3")))
    |> Decimal.add(Decimal.mult(twelve, Decimal.new("0.2")))
  end

  defp apply_target_mode(base, :strict, volatility), do: Decimal.add(base, Decimal.mult(volatility, Decimal.new("0.35")))
  defp apply_target_mode(base, :flexible, volatility), do: Decimal.add(base, Decimal.mult(volatility, Decimal.new("0.15")))
  defp apply_target_mode(base, _, _), do: base

  defp apply_bounds(value, nil, nil), do: value

  defp apply_bounds(value, min, max) do
    value
    |> apply_min(min)
    |> apply_max(max)
  end

  defp apply_min(value, nil), do: value

  defp apply_min(value, min) do
    min_dec = cast_decimal(min)

    if Decimal.compare(value, min_dec) == :lt, do: min_dec, else: value
  end

  defp apply_max(value, nil), do: value

  defp apply_max(value, max) do
    max_dec = cast_decimal(max)

    if Decimal.compare(value, max_dec) == :gt, do: max_dec, else: value
  end

  defp volatility([], _baseline), do: Decimal.new("0")

  defp volatility(history, baseline) do
    baseline = if Decimal.compare(baseline, Decimal.new("0")) == :eq, do: Decimal.new("1"), else: baseline

    history
    |> Enum.map(fn value -> Decimal.abs(Decimal.sub(value, baseline)) end)
    |> average()
    |> Decimal.div(baseline)
    |> Decimal.mult(Decimal.new("100"))
    |> Decimal.round(2)
  end

  defp average([]), do: Decimal.new("0")

  defp average(list) do
    count = Decimal.new(length(list))

    list
    |> Enum.reduce(Decimal.new("0"), &Decimal.add/2)
    |> Decimal.div(count)
    |> Decimal.round(2)
  end

  defp direction(delta) do
    case Decimal.compare(delta, Decimal.new("0")) do
      :gt -> :increase
      :lt -> :decrease
      _ -> :steady
    end
  end

  defp explanation(budget, expected, volatility_score, delta) do
    recent = Map.get(expected, 3, Decimal.new("0")) |> Decimal.to_string(:normal)
    yearly = Map.get(expected, 12, Decimal.new("0")) |> Decimal.to_string(:normal)
    move = delta |> Decimal.round(2) |> Decimal.to_string(:normal)

    "Recent 3m avg #{recent}, annual avg #{yearly}, volatility #{Decimal.to_string(volatility_score)}%. " <>
      "#{budget.target_mode |> to_string() |> String.capitalize()} mode suggests #{move} adjustment."
  end

  defp normalize_category_key(nil), do: "uncategorized"

  defp normalize_category_key(category) do
    category
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp cast_decimal(%Decimal{} = value), do: value

  defp cast_decimal(value) do
    case Decimal.cast(value) do
      {:ok, decimal} -> decimal
      :error -> Decimal.new("0")
    end
  end
end
