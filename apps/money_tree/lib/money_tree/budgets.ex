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
    %{
      name: "Housing",
      allocation: Decimal.new("2500.00"),
      period: :monthly,
      entry_type: :expense,
      variability: :fixed,
      currency: "USD"
    },
    %{
      name: "Groceries",
      allocation: Decimal.new("600.00"),
      period: :monthly,
      entry_type: :expense,
      variability: :variable,
      currency: "USD"
    },
    %{
      name: "Transportation",
      allocation: Decimal.new("300.00"),
      period: :monthly,
      entry_type: :expense,
      variability: :variable,
      currency: "USD"
    },
    %{
      name: "Lifestyle",
      allocation: Decimal.new("400.00"),
      period: :monthly,
      entry_type: :expense,
      variability: :variable,
      currency: "USD"
    }
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
    {entries, %{currency: currency}} = aggregate_budget_entries(user, opts)

    Enum.map(entries, &format_budget_entry(&1, currency, opts))
  end

  @doc """
  Builds rollup insights grouped by budget entry type.
  """
  @spec rollup_by_entry_type(User.t() | binary(), keyword()) :: %{optional(atom()) => map()}
  def rollup_by_entry_type(user, opts \\ []) do
    {entries, %{currency: currency}} = aggregate_budget_entries(user, opts)

    entries
    |> Enum.group_by(& &1.entry_type)
    |> Enum.into(%{}, fn {key, group} ->
      {key, build_rollup_summary(key, group, currency, opts)}
    end)
  end

  @doc """
  Builds rollup insights grouped by commitment variability.
  """
  @spec rollup_by_variability(User.t() | binary(), keyword()) :: %{optional(atom()) => map()}
  def rollup_by_variability(user, opts \\ []) do
    {entries, %{currency: currency}} = aggregate_budget_entries(user, opts)

    entries
    |> Enum.group_by(& &1.variability)
    |> Enum.into(%{}, fn {key, group} ->
      {key, build_rollup_summary(key, group, currency, opts)}
    end)
  end

  defp aggregate_budget_entries(user, opts) do
    budgets =
      opts
      |> Keyword.get_lazy(:budgets, fn -> persisted_budgets_or_defaults(user, opts) end)

    selector = normalize_period_selector(Keyword.get(opts, :period))
    window = resolve_period_window(selector, opts)
    default_currency = Keyword.get(opts, :currency) || derive_currency(user, budgets)

    totals = spending_by_category(user, window)

    entries =
      Enum.map(budgets, fn budget ->
        build_budget_entry(budget, totals, default_currency, selector, window)
      end)

    {entries, %{currency: default_currency, window: window, period: selector}}
  end

  defp build_budget_entry(budget, totals, default_currency, selector, window) do
    metadata = budget_metadata(budget)
    key = metadata.name |> String.downcase()

    info = Map.get(totals, key, %{currency: default_currency, total: Decimal.new("0")})

    currency = metadata.currency || info.currency || default_currency
    allocation = allocation_for_period(metadata, selector)
    total_signed = cast_decimal(info.total)
    total_abs = Decimal.abs(total_signed)
    remaining = Decimal.sub(allocation, total_abs)

    %{
      name: metadata.name,
      period: metadata.period,
      entry_type: metadata.entry_type,
      variability: metadata.variability,
      currency: currency,
      allocation_decimal: allocation,
      activity_decimal: total_abs,
      activity_signed: total_signed,
      remaining_decimal: remaining,
      window: window
    }
  end

  defp format_budget_entry(entry, _currency, opts) do
    %{
      name: entry.name,
      period: humanize_period(entry.period),
      period_atom: entry.period,
      entry_type: humanize_entry_type(entry.entry_type),
      entry_type_atom: entry.entry_type,
      variability: humanize_variability(entry.variability),
      variability_atom: entry.variability,
      currency: entry.currency,
      allocated: Accounts.format_money(entry.allocation_decimal, entry.currency, opts),
      allocated_masked: Accounts.mask_money(entry.allocation_decimal, entry.currency, opts),
      allocated_decimal: entry.allocation_decimal,
      spent: Accounts.format_money(entry.activity_decimal, entry.currency, opts),
      spent_masked: Accounts.mask_money(entry.activity_decimal, entry.currency, opts),
      spent_decimal: entry.activity_decimal,
      spent_signed_decimal: entry.activity_signed,
      remaining: Accounts.format_money(entry.remaining_decimal, entry.currency, opts),
      remaining_masked: Accounts.mask_money(entry.remaining_decimal, entry.currency, opts),
      remaining_decimal: entry.remaining_decimal,
      status: budget_status(entry.allocation_decimal, entry.activity_decimal)
    }
  end

  defp build_rollup_summary(key, entries, currency, opts) do
    allocated = sum_decimals(entries, & &1.allocation_decimal)
    activity_signed = sum_decimals(entries, & &1.activity_signed)
    activity_total = sum_decimals(entries, & &1.activity_decimal)
    projection = sum_decimals(entries, &projection_for_entry/1)
    variance = Decimal.sub(projection, allocated)
    utilization = compute_utilization(allocated, activity_total)

    activity_value =
      case key do
        :income -> activity_signed
        _ -> activity_total
      end

    %{
      key: key,
      label: humanize_value(key),
      currency: currency,
      allocated: Accounts.format_money(allocated, currency, opts),
      allocated_masked: Accounts.mask_money(allocated, currency, opts),
      allocated_decimal: allocated,
      actual: Accounts.format_money(activity_value, currency, opts),
      actual_masked: Accounts.mask_money(activity_value, currency, opts),
      actual_decimal: activity_value,
      projection: Accounts.format_money(projection, currency, opts),
      projection_masked: Accounts.mask_money(projection, currency, opts),
      projection_decimal: projection,
      variance: Accounts.format_money(variance, currency, opts),
      variance_masked: Accounts.mask_money(variance, currency, opts),
      variance_decimal: variance,
      utilization: utilization,
      utilization_percent:
        case utilization do
          nil -> nil
          %Decimal{} = value -> Decimal.mult(value, Decimal.new("100")) |> Decimal.round(2)
        end
    }
  end

  defp compute_utilization(allocated, activity) do
    cond do
      Decimal.compare(activity, Decimal.new("0")) == :eq -> Decimal.new("0")
      is_nil(allocated) -> nil
      Decimal.compare(allocated, Decimal.new("0")) == :eq -> nil
      true -> Decimal.div(activity, allocated) |> Decimal.round(4)
    end
  end

  defp projection_for_entry(entry) do
    case entry.variability do
      :fixed -> entry.allocation_decimal
      _ -> entry.activity_decimal
    end
  end

  defp sum_decimals(collection, fun) do
    Enum.reduce(collection, Decimal.new("0"), fn item, acc ->
      Decimal.add(acc, fun.(item))
    end)
  end

  defp budget_metadata(%Budget{} = budget) do
    %{
      name: budget.name,
      period: budget.period || :monthly,
      entry_type: budget.entry_type || :expense,
      variability: budget.variability || :variable,
      allocation_amount: cast_decimal(budget.allocation_amount),
      currency: budget.currency
    }
  end

  defp budget_metadata(%{name: name} = budget) do
    %{
      name: name,
      period: normalize_period_selector(Map.get(budget, :period)),
      entry_type: normalize_rollup_enum(:entry_type, Map.get(budget, :entry_type, :expense)),
      variability: normalize_rollup_enum(:variability, Map.get(budget, :variability, :variable)),
      allocation_amount:
        budget
        |> Map.get(:allocation_amount) || Map.get(budget, :allocation) || Decimal.new("0"),
      currency: Map.get(budget, :currency)
    }
    |> Map.update!(:allocation_amount, &cast_decimal/1)
  end

  defp normalize_rollup_enum(:entry_type, value) do
    normalize_rollup_enum(value, Budget.entry_types(), :expense)
  end

  defp normalize_rollup_enum(:variability, value) do
    normalize_rollup_enum(value, Budget.variabilities(), :variable)
  end

  defp normalize_rollup_enum(value, allowed, default) when is_atom(value) do
    if value in allowed, do: value, else: default
  end

  defp normalize_rollup_enum(value, allowed, default) when is_binary(value) do
    value
    |> String.downcase()
    |> String.to_existing_atom()
    |> normalize_rollup_enum(allowed, default)
  rescue
    ArgumentError -> default
  end

  defp normalize_rollup_enum(_value, _allowed, default), do: default

  defp allocation_for_period(metadata, selector) do
    allocation = metadata.allocation_amount

    case metadata.variability do
      :fixed -> allocation
      _ -> convert_allocation_between_periods(allocation, metadata.period, selector)
    end
  end

  defp convert_allocation_between_periods(amount, source, target) do
    source_period = normalize_period_selector(source)
    target_period = normalize_period_selector(target)

    if source_period == target_period do
      amount
    else
      to_year = periods_per_year()
      yearly = Decimal.mult(amount, Map.fetch!(to_year, source_period))
      Decimal.div(yearly, Map.fetch!(to_year, target_period))
    end
  end

  defp periods_per_year do
    %{
      weekly: Decimal.new("52"),
      monthly: Decimal.new("12"),
      yearly: Decimal.new("1")
    }
  end

  defp normalize_period_selector(nil), do: :monthly

  defp normalize_period_selector(value) when is_atom(value) do
    if value in Budget.periods(), do: value, else: :monthly
  end

  defp normalize_period_selector(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.to_existing_atom()
    |> normalize_period_selector()
  rescue
    ArgumentError -> :monthly
  end

  defp resolve_period_window(selector, opts) do
    default_window = period_window(selector, Keyword.get(opts, :anchor_date))

    since = Keyword.get(opts, :since, default_window.since)
    until = Keyword.get(opts, :until, default_window.until)

    %{since: since, until: until}
  end

  defp period_window(:weekly, anchor_date), do: weekly_window(anchor_date)
  defp period_window(:yearly, anchor_date), do: yearly_window(anchor_date)
  defp period_window(:monthly, anchor_date), do: monthly_window(anchor_date)

  defp weekly_window(anchor_date) do
    date = anchor_date || Date.utc_today()
    beginning = Date.beginning_of_week(date)
    ending = Date.end_of_week(date)

    %{
      since: DateTime.new!(beginning, ~T[00:00:00], "Etc/UTC"),
      until: DateTime.new!(ending, ~T[23:59:59], "Etc/UTC")
    }
  end

  defp monthly_window(anchor_date) do
    date = anchor_date || Date.utc_today()
    beginning = Date.beginning_of_month(date)
    ending = Date.end_of_month(date)

    %{
      since: DateTime.new!(beginning, ~T[00:00:00], "Etc/UTC"),
      until: DateTime.new!(ending, ~T[23:59:59], "Etc/UTC")
    }
  end

  defp yearly_window(anchor_date) do
    date = anchor_date || Date.utc_today()
    year = date.year
    beginning = Date.new!(year, 1, 1)
    ending = Date.new!(year, 12, 31)

    %{
      since: DateTime.new!(beginning, ~T[00:00:00], "Etc/UTC"),
      until: DateTime.new!(ending, ~T[23:59:59], "Etc/UTC")
    }
  end

  defp spending_by_category(user, %{since: since, until: until}) do
    from(transaction in Transaction,
      join: account in subquery(Accounts.accessible_accounts_query(user)),
      on: transaction.account_id == account.id
    )
    |> maybe_filter_since(since)
    |> maybe_filter_until(until)
    |> group_by([transaction], [transaction.category, transaction.currency])
    |> select([transaction], {
      coalesce(transaction.category, "Uncategorized"),
      transaction.currency,
      sum(transaction.amount)
    })
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

  defp maybe_filter_since(query, nil), do: query

  defp maybe_filter_since(query, since) do
    where(query, [transaction], is_nil(transaction.posted_at) or transaction.posted_at >= ^since)
  end

  defp maybe_filter_until(query, nil), do: query

  defp maybe_filter_until(query, until) do
    where(query, [transaction], is_nil(transaction.posted_at) or transaction.posted_at <= ^until)
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

  defp ensure_enum_value(value, field) do
    allowed =
      case field do
        :period -> Budget.periods()
        :entry_type -> Budget.entry_types()
        :variability -> Budget.variabilities()
        _ -> []
      end

    if value in allowed, do: value, else: nil
  end

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
