defmodule MoneyTree.Budgets do
  @moduledoc """
  Budget aggregation helpers used by the dashboard experience.

  The implementation favours deterministic, testable behaviour so the LiveView can
  render meaningful placeholders even when only a handful of transactions exist.
  """

  import Ecto.Query, warn: false

  alias Decimal
  alias MoneyTree.Budgets.Budget
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
  Lists the budgets that belong to the supplied user.

  Supports optional filtering by period, entry type, or variability.
  """
  @spec list_budgets(User.t() | binary(), keyword()) :: [Budget.t()]
  def list_budgets(user, opts \\ []) do
    user_id = normalize_user_id(user)
    filters = Keyword.take(opts, [:period, :entry_type, :variability])

    Budget
    |> where([budget], budget.user_id == ^user_id)
    |> maybe_filter(:period, filters)
    |> maybe_filter(:entry_type, filters)
    |> maybe_filter(:variability, filters)
    |> order_by([budget], asc: budget.period, asc: budget.name)
    |> Repo.all()
  end

  @doc """
  Retrieves a single budget for the user, raising if it does not exist.
  """
  @spec get_budget!(User.t() | binary(), binary()) :: Budget.t()
  def get_budget!(user, budget_id) when is_binary(budget_id) do
    user_id = normalize_user_id(user)

    Repo.get_by!(Budget, id: budget_id, user_id: user_id)
  end

  @doc """
  Creates a new budget tied to the provided user.
  """
  @spec create_budget(User.t() | binary(), map()) :: {:ok, Budget.t()} | {:error, Ecto.Changeset.t()}
  def create_budget(user, attrs) when is_map(attrs) do
    user_id = normalize_user_id(user)

    %Budget{}
    |> Budget.changeset(Map.put(attrs, :user_id, user_id))
    |> Repo.insert()
  end

  @doc """
  Updates an existing budget with the supplied attributes.
  """
  @spec update_budget(Budget.t(), map()) :: {:ok, Budget.t()} | {:error, Ecto.Changeset.t()}
  def update_budget(%Budget{} = budget, attrs) when is_map(attrs) do
    budget
    |> Budget.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes the given budget.
  """
  @spec delete_budget(Budget.t()) :: {:ok, Budget.t()} | {:error, Ecto.Changeset.t()}
  def delete_budget(%Budget{} = budget) do
    Repo.delete(budget)
  end

  @doc """
  Returns a changeset for tracking budget updates.
  """
  @spec change_budget(Budget.t(), map()) :: Ecto.Changeset.t()
  def change_budget(%Budget{} = budget, attrs \\ %{}) do
    Budget.changeset(budget, attrs)
  end

  @doc """
  Formats allocation metadata for display, including masked variants.
  """
  @spec format_budget(Budget.t(), keyword()) :: map()
  def format_budget(%Budget{} = budget, opts \\ []) do
    amount = budget.allocation_amount || Decimal.new("0")
    currency = budget.currency

    %{
      id: budget.id,
      name: budget.name,
      period: humanize_period(budget.period),
      entry_type: humanize_entry_type(budget.entry_type),
      variability: humanize_variability(budget.variability),
      currency: currency,
      allocation_amount: amount,
      allocation_formatted: Accounts.format_money(amount, currency, opts),
      allocation_masked: Accounts.mask_money(amount, currency, opts)
    }
  end

  @doc """
  Formats the allocation amount for the given budget.
  """
  @spec format_allocation(Budget.t(), keyword()) :: String.t() | nil
  def format_allocation(%Budget{} = budget, opts \\ []) do
    Accounts.format_money(budget.allocation_amount, budget.currency, opts)
  end

  @doc """
  Masks the allocation amount using the configured mask character.
  """
  @spec mask_allocation(Budget.t(), keyword()) :: String.t() | nil
  def mask_allocation(%Budget{} = budget, opts \\ []) do
    Accounts.mask_money(budget.allocation_amount, budget.currency, opts)
  end

  @doc """
  Builds per-category budget totals using recent transaction activity.
  """
  @spec aggregate_totals(User.t() | binary(), keyword()) :: [budget_entry()]
  def aggregate_totals(user, opts \\ []) do
    budgets =
      opts
      |> Keyword.get_lazy(:budgets, fn -> persisted_budgets_or_defaults(user, opts) end)
    since = Keyword.get(opts, :since, default_since())
    default_currency = Keyword.get(opts, :currency) || derive_currency(user, budgets)

    totals = spending_by_category(user, since)

    Enum.map(budgets, fn budget ->
      build_budget_entry(budget, totals, default_currency, opts)
    end)
  end

  defp build_budget_entry(%Budget{} = budget, totals, default_currency, opts) do
    info =
      budget.name
      |> String.downcase()
      |> then(&Map.get(totals, &1, %{currency: default_currency, total: Decimal.new("0")}))

    allocation = cast_decimal(budget.allocation_amount)
    spend = info.total
    currency = budget.currency || info.currency || default_currency
    remaining = Decimal.sub(allocation, spend)

    %{
      name: budget.name,
      period: humanize_period(budget.period),
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

  defp build_budget_entry(%{name: name} = budget, totals, default_currency, opts) do
    key = String.downcase(name)
    info = Map.get(totals, key, %{currency: default_currency, total: Decimal.new("0")})

    allocation = cast_decimal(Map.get(budget, :allocation, Decimal.new("0")))
    spend = info.total
    currency = Map.get(budget, :currency) || info.currency || default_currency
    remaining = Decimal.sub(allocation, spend)

    %{
      name: name,
      period: humanize_period(Map.get(budget, :period, "Monthly")),
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
    |> Enum.find_value(fn
      %Budget{currency: currency} when is_binary(currency) -> currency
      budget when is_map(budget) -> budget[:currency]
      _ -> nil
    end)
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

  defp persisted_budgets_or_defaults(user, opts) do
    case list_budgets(user, Keyword.take(opts, [:period, :entry_type, :variability])) do
      [] -> @default_budgets
      budgets -> budgets
    end
  end

  defp maybe_filter(query, field, filters) do
    case normalize_enum_filter(field, Keyword.get(filters, field)) do
      nil -> query
      value -> where(query, [budget], field(budget, ^field) == ^value)
    end
  end

  defp normalize_enum_filter(_field, nil), do: nil

  defp normalize_enum_filter(field, value) do
    value
    |> case do
      v when is_atom(v) -> v
      v when is_binary(v) -> v |> String.downcase() |> String.to_existing_atom()
    end
    |> ensure_enum_value(field)
  rescue
    ArgumentError -> nil
  end

  defp ensure_enum_value(value, :period) when value in Budget.periods(), do: value
  defp ensure_enum_value(value, :entry_type) when value in Budget.entry_types(), do: value
  defp ensure_enum_value(value, :variability) when value in Budget.variabilities(), do: value
  defp ensure_enum_value(_value, _field), do: nil

  defp normalize_user_id(%User{id: id}), do: id
  defp normalize_user_id(id) when is_binary(id), do: id

  defp humanize_period(nil), do: nil
  defp humanize_period(period), do: humanize_value(period)

  defp humanize_entry_type(nil), do: nil
  defp humanize_entry_type(entry_type), do: humanize_value(entry_type)

  defp humanize_variability(nil), do: nil
  defp humanize_variability(variability), do: humanize_value(variability)

  defp humanize_value(value) when is_atom(value), do: humanize_value(Atom.to_string(value))

  defp humanize_value(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp humanize_value(value), do: value
end
