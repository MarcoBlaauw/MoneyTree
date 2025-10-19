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
end
