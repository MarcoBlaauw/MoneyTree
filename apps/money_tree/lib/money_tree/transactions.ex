defmodule MoneyTree.Transactions do
  @moduledoc """
  Domain helpers for working with account transactions and pagination logic.
  """

  import Ecto.Query, warn: false

  alias MoneyTree.Accounts
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction
  alias MoneyTree.Users.User
  alias Decimal

  @type page_opts :: keyword()

  @default_page 1
  @default_per_page 20
  @max_per_page 100

  @doc """
  Returns paginated transactions accessible to the user.
  """
  @spec paginate_for_user(User.t() | binary(), page_opts()) :: %{entries: list(), metadata: map()}
  def paginate_for_user(user, opts \\ []) do
    page = sanitize_page(Keyword.get(opts, :page, @default_page))
    per_page = sanitize_per_page(Keyword.get(opts, :per_page, @default_per_page))

    base_query =
      from transaction in Transaction,
        join: account in subquery(Accounts.accessible_accounts_query(user)),
        on: transaction.account_id == account.id,
        preload: [account: ^preload_account_fields()]

    total_entries = Repo.aggregate(base_query, :count, :id)

    entries =
      base_query
      |> order_by([transaction], desc: transaction.posted_at, desc: transaction.inserted_at)
      |> offset(^((page - 1) * per_page))
      |> limit(^per_page)
      |> Repo.all()
      |> Enum.map(&build_entry/1)

    %{
      entries: entries,
      metadata:
        build_metadata(
          page,
          per_page,
          total_entries
        )
    }
  end

  @doc """
  Fetches the most recent transactions for the dashboard along with UI color hints.

  Transactions are scoped to accounts the user can access and include a semantic
  direction along with Tailwind-compatible color classes for rendering.
  """
  @spec recent_with_color(User.t() | binary(), keyword()) :: [map()]
  def recent_with_color(user, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    from(transaction in Transaction,
      join: account in subquery(Accounts.accessible_accounts_query(user)),
      on: transaction.account_id == account.id
    )
    |> order_by([transaction, _account],
      desc: transaction.posted_at,
      desc: transaction.inserted_at
    )
    |> limit(^limit)
    |> preload([transaction, _account], account: ^preload_account_fields())
    |> Repo.all()
    |> Enum.map(&build_recent_entry(&1, opts))
  end

  @doc """
  Calculates the net activity for an account within the supplied lookback window.

  The result is the signed sum of posted amounts, defaulting to the last 30 days.
  """
  @spec net_activity_for_account(Account.t() | binary(), keyword()) :: Decimal.t()
  def net_activity_for_account(%Account{id: account_id}, opts),
    do: net_activity_for_account(account_id, opts)

  def net_activity_for_account(account_id, opts) when is_binary(account_id) do
    days = Keyword.get(opts, :days, 30)
    since = lookback_datetime(days)

    from(transaction in Transaction,
      where: transaction.account_id == ^account_id,
      where: is_nil(transaction.posted_at) or transaction.posted_at >= ^since,
      select: sum(transaction.amount)
    )
    |> Repo.one()
    |> case do
      nil -> Decimal.new("0")
      %Decimal{} = value -> value
      value -> Decimal.new(value)
    end
  end

  @doc """
  Builds rollups of spending by category for use on the dashboard.
  """
  @spec category_rollups(User.t() | binary(), keyword()) :: [map()]
  def category_rollups(user, opts \\ []) do
    limit = Keyword.get(opts, :limit, 6)
    since = Keyword.get(opts, :since, beginning_of_month())

    totals =
      from(transaction in Transaction,
        join: account in subquery(Accounts.accessible_accounts_query(user)),
        on: transaction.account_id == account.id,
        where: is_nil(^since) or is_nil(transaction.posted_at) or transaction.posted_at >= ^since,
        group_by: [transaction.category, transaction.currency],
        select:
          {transaction.currency, coalesce(transaction.category, "Uncategorized"),
           sum(fragment("ABS(?)", transaction.amount))}
      )
      |> Repo.all()

    totals
    |> Enum.group_by(fn {currency, _category, _total} -> currency || "USD" end)
    |> Enum.flat_map(fn {_currency, entries} ->
      total_spend =
        Enum.reduce(entries, Decimal.new("0"), fn {_currency, _category, total}, acc ->
          add_decimal(acc, total)
        end)

      entries
      |> Enum.sort_by(fn {_currency, _category, total} -> decimal_to_sortable(total) end, &>=/2)
      |> Enum.take(limit)
      |> Enum.map(fn {currency, category, total} ->
        currency = currency || "USD"

        percent =
          case Decimal.compare(total_spend, Decimal.new("0")) do
            :eq ->
              Decimal.new("0")

            _ ->
              total
              |> add_decimal(0)
              |> Decimal.div(total_spend)
              |> Decimal.mult(Decimal.new("100"))
              |> Decimal.round(2)
          end

        formatted_total = Accounts.format_money(total, currency, opts)

        %{
          category: category,
          currency: currency,
          total: formatted_total,
          total_masked: Accounts.mask_money(total, currency, opts),
          percent: percent
        }
      end)
    end)
    |> Enum.sort_by(& &1.percent, &>=/2)
  end

  @doc """
  Summarises subscription-related spending within the recent period.
  """
  @spec subscription_spend(User.t() | binary(), keyword()) :: map()
  def subscription_spend(user, opts \\ []) do
    categories = Keyword.get(opts, :categories, ["Subscription", "Streaming", "Software"])
    lookback_days = Keyword.get(opts, :lookback_days, 30)
    since = lookback_datetime(lookback_days)

    normalized_categories = Enum.map(categories, &String.downcase/1)

    query =
      from(transaction in Transaction,
        join: account in subquery(Accounts.accessible_accounts_query(user)),
        on: transaction.account_id == account.id,
        where:
          fragment("LOWER(COALESCE(?, ''))", transaction.category) in ^normalized_categories or
            fragment("LOWER(COALESCE(?, ''))", transaction.merchant_name) in ^normalized_categories or
            fragment("LOWER(COALESCE(?, '')) LIKE ?", transaction.description, ^"%subscription%"),
        where: is_nil(transaction.posted_at) or transaction.posted_at >= ^since,
        select:
          {transaction.currency, transaction.merchant_name,
           fragment("ABS(?)", transaction.amount)}
      )

    rows = Repo.all(query)

    {currency, total} =
      rows
      |> Enum.reduce({"USD", Decimal.new("0")}, fn {row_currency, _merchant, amount},
                                                   {acc_currency, acc_total} ->
        currency = row_currency || acc_currency
        {currency, add_decimal(acc_total, amount)}
      end)

    top_merchants =
      rows
      |> Enum.group_by(fn {_currency, merchant, _amount} -> merchant || "Unknown" end)
      |> Enum.map(fn {merchant, entries} ->
        spend =
          Enum.reduce(entries, Decimal.new("0"), fn {_currency, _merchant, amount}, acc ->
            add_decimal(acc, amount)
          end)

        %{
          merchant: merchant,
          spend_decimal: spend,
          spend: Accounts.format_money(spend, currency, opts),
          spend_masked: Accounts.mask_money(spend, currency, opts)
        }
      end)
      |> Enum.sort_by(&decimal_to_sortable(&1.spend_decimal), &>=/2)
      |> Enum.take(5)
      |> Enum.map(&Map.delete(&1, :spend_decimal))

    monthly_total = Accounts.format_money(total, currency, opts)
    monthly_total_masked = Accounts.mask_money(total, currency, opts)

    annual_projection = Decimal.mult(total, Decimal.new("12"))

    %{
      currency: currency,
      monthly_total: monthly_total,
      monthly_total_masked: monthly_total_masked,
      monthly_total_decimal: total,
      annual_projection: Accounts.format_money(annual_projection, currency, opts),
      annual_projection_masked: Accounts.mask_money(annual_projection, currency, opts),
      annual_projection_decimal: annual_projection,
      top_merchants: top_merchants
    }
  end

  defp build_entry(%Transaction{} = transaction) do
    account = transaction.account || %Account{}

    %{
      id: transaction.id,
      description: transaction.description,
      posted_at: transaction.posted_at,
      amount: Accounts.format_money(transaction.amount, transaction.currency, []),
      amount_masked: Accounts.mask_money(transaction.amount, transaction.currency, []),
      currency: transaction.currency,
      status: transaction.status,
      account: %{
        id: account.id,
        name: account.name,
        type: account.type
      }
    }
  end

  defp build_recent_entry(%Transaction{} = transaction, opts) do
    account = transaction.account || %Account{}
    amount = cast_decimal(transaction.amount)
    currency = transaction.currency || account.currency || "USD"
    direction = classify_direction(amount)

    %{
      id: transaction.id,
      description: transaction.description,
      posted_at: transaction.posted_at,
      amount: Accounts.format_money(amount, currency, opts),
      amount_masked: Accounts.mask_money(amount, currency, opts),
      currency: currency,
      direction: direction,
      color_class: color_class(direction),
      status: transaction.status,
      account: %{
        id: account.id,
        name: account.name,
        type: account.type
      }
    }
  end

  defp build_metadata(page, per_page, total_entries) do
    total_pages =
      total_entries
      |> Kernel./(per_page)
      |> Float.ceil()
      |> trunc()
      |> max(1)

    has_next? = page < total_pages
    has_prev? = page > 1

    %{
      page: page,
      per_page: per_page,
      total_entries: total_entries,
      total_pages: total_pages,
      has_next?: has_next?,
      has_prev?: has_prev?
    }
  end

  defp sanitize_page(page) when is_integer(page) and page > 0, do: page

  defp sanitize_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {value, _} -> sanitize_page(value)
      :error -> @default_page
    end
  end

  defp sanitize_page(_page), do: @default_page

  defp sanitize_per_page(per_page) when is_integer(per_page) and per_page > 0 do
    min(per_page, @max_per_page)
  end

  defp sanitize_per_page(per_page) when is_binary(per_page) do
    case Integer.parse(per_page) do
      {value, _} -> sanitize_per_page(value)
      :error -> @default_per_page
    end
  end

  defp sanitize_per_page(_per_page), do: @default_per_page

  defp preload_account_fields do
    [:institution]
  end

  defp lookback_datetime(days) when is_integer(days) and days > 0 do
    DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)
  end

  defp lookback_datetime(_days), do: lookback_datetime(30)

  defp beginning_of_month do
    Date.utc_today()
    |> Date.beginning_of_month()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp cast_decimal(nil), do: Decimal.new("0")
  defp cast_decimal(%Decimal{} = value), do: value

  defp cast_decimal(value) do
    case Decimal.cast(value) do
      {:ok, decimal} -> decimal
      :error -> Decimal.new("0")
    end
  end

  defp classify_direction(amount) do
    case Decimal.compare(amount, Decimal.new("0")) do
      :lt -> :credit
      :eq -> :neutral
      :gt -> :debit
    end
  end

  defp color_class(:credit), do: "text-emerald-600"
  defp color_class(:neutral), do: "text-slate-600"
  defp color_class(:debit), do: "text-rose-600"

  defp add_decimal(%Decimal{} = left, %Decimal{} = right), do: Decimal.add(left, right)
  defp add_decimal(%Decimal{} = left, value), do: add_decimal(left, cast_decimal(value))
  defp add_decimal(left, %Decimal{} = right), do: add_decimal(cast_decimal(left), right)
  defp add_decimal(left, right), do: add_decimal(cast_decimal(left), cast_decimal(right))

  defp decimal_to_sortable(nil), do: 0

  defp decimal_to_sortable(%Decimal{} = decimal) do
    decimal
    |> Decimal.to_float()
  rescue
    _ -> 0
  end
end
