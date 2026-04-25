defmodule MoneyTreeWeb.ImportExportController do
  use MoneyTreeWeb, :controller

  alias MoneyTree.ImportExport

  def transactions_csv(%{assigns: %{current_user: current_user}} = conn, params) do
    days = parse_days(params["days"])
    csv = ImportExport.transactions_csv(current_user, days)
    filename = "transactions-export-#{Date.utc_today()}-#{days}d.csv"

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(:ok, csv)
  end

  def budgets_csv(%{assigns: %{current_user: current_user}} = conn, _params) do
    csv = ImportExport.budgets_csv(current_user)
    filename = "budgets-export-#{Date.utc_today()}.csv"

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(:ok, csv)
  end

  defp parse_days(days) when is_binary(days) do
    case Integer.parse(days) do
      {value, ""} when value >= 1 and value <= 3650 -> value
      _ -> 365
    end
  end

  defp parse_days(_), do: 365
end
