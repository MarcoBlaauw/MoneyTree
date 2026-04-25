defmodule MoneyTree.ImportExport do
  @moduledoc """
  User-scoped CSV export helpers for transactions and budgets.
  """

  import Ecto.Query, warn: false

  alias Decimal
  alias MoneyTree.Accounts
  alias MoneyTree.Budgets
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction
  alias MoneyTree.Users.User

  @max_export_rows 10_000
  @default_export_days 365

  @spec transactions_csv(User.t() | binary(), integer()) :: binary()
  def transactions_csv(user, days \\ @default_export_days) do
    safe_days = normalize_days(days)

    since =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.add(-(safe_days * 86_400), :second)

    rows =
      from(transaction in Transaction,
        join: account in subquery(Accounts.accessible_accounts_query(user)),
        on: transaction.account_id == account.id,
        where: is_nil(transaction.posted_at) or transaction.posted_at >= ^since,
        order_by: [desc: transaction.posted_at, desc: transaction.inserted_at],
        limit: ^@max_export_rows,
        select: %{
          id: transaction.id,
          account_name: account.name,
          posted_at: transaction.posted_at,
          amount: transaction.amount,
          currency: transaction.currency,
          description: transaction.description,
          merchant_name: transaction.merchant_name,
          category: transaction.category,
          source: transaction.source,
          status: transaction.status,
          transaction_kind: transaction.transaction_kind,
          excluded_from_spending: transaction.excluded_from_spending,
          inserted_at: transaction.inserted_at
        }
      )
      |> Repo.all()

    csv_rows =
      Enum.map(rows, fn row ->
        [
          row.id,
          row.account_name,
          format_datetime(row.posted_at),
          decimal_to_string(row.amount),
          row.currency,
          row.description,
          row.merchant_name,
          row.category,
          row.source,
          row.status,
          row.transaction_kind,
          to_string(row.excluded_from_spending),
          format_datetime(row.inserted_at)
        ]
      end)

    encode_csv([
      [
        "transaction_id",
        "account_name",
        "posted_at",
        "amount",
        "currency",
        "description",
        "merchant_name",
        "category",
        "source",
        "status",
        "transaction_kind",
        "excluded_from_spending",
        "inserted_at"
      ]
      | csv_rows
    ])
  end

  @spec budgets_csv(User.t() | binary()) :: binary()
  def budgets_csv(user) do
    rows =
      Budgets.list_budgets(user)
      |> Enum.map(fn budget ->
        [
          budget.id,
          budget.name,
          to_string(budget.period),
          to_string(budget.entry_type),
          to_string(budget.variability),
          decimal_to_string(budget.allocation_amount),
          budget.currency,
          budget.priority,
          format_datetime(budget.inserted_at)
        ]
      end)

    encode_csv([
      [
        "budget_id",
        "name",
        "period",
        "entry_type",
        "variability",
        "allocation_amount",
        "currency",
        "priority",
        "inserted_at"
      ]
      | rows
    ])
  end

  defp normalize_days(days) when is_integer(days) and days >= 1 and days <= 3650, do: days
  defp normalize_days(_), do: @default_export_days

  defp encode_csv(rows) do
    rows
    |> Enum.map(fn row -> row |> Enum.map(&csv_escape/1) |> Enum.join(",") end)
    |> Enum.join("\n")
  end

  defp csv_escape(nil), do: ""

  defp csv_escape(value) do
    string = to_string(value)

    if String.contains?(string, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(string, "\"", "\"\"") <> "\""
    else
      string
    end
  end

  defp format_datetime(nil), do: ""
  defp format_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_datetime(other), do: to_string(other)

  defp decimal_to_string(nil), do: ""
  defp decimal_to_string(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp decimal_to_string(other), do: to_string(other)
end
