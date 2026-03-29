defmodule MoneyTreeWeb.CategorizationController do
  use MoneyTreeWeb, :controller

  alias Ecto.Changeset
  alias MoneyTree.Categorization

  def list_rules(%{assigns: %{current_user: current_user}} = conn, _params) do
    rules = current_user |> Categorization.list_rules() |> Enum.map(&serialize_rule/1)
    json(conn, %{data: rules})
  end

  def create_rule(%{assigns: %{current_user: current_user}} = conn, params) do
    case Categorization.create_rule(current_user, params) do
      {:ok, rule} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_rule(rule)})

      {:error, %Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Changeset.traverse_errors(changeset, &translate_error/1)})
    end
  end

  def delete_rule(%{assigns: %{current_user: current_user}} = conn, %{"id" => id}) do
    case Categorization.delete_rule(current_user, id) do
      {:ok, _} -> send_resp(conn, :no_content, "")
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "rule not found"})
    end
  end

  def recategorize(%{assigns: %{current_user: current_user}} = conn, %{
        "transaction_id" => transaction_id,
        "category" => category
      }) do
    case Categorization.recategorize_transaction(current_user, transaction_id, category) do
      {:ok, transaction} -> json(conn, %{data: serialize_transaction(transaction)})
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "transaction not found"})
      {:error, %Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Changeset.traverse_errors(changeset, &translate_error/1)})
    end
  end

  def recategorize(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "transaction_id and category are required"})
  end
  defp serialize_rule(rule) do
    %{
      id: rule.id,
      category: rule.category,
      merchant_regex: rule.merchant_regex,
      description_keywords: rule.description_keywords,
      min_amount: rule.min_amount,
      max_amount: rule.max_amount,
      account_types: rule.account_types,
      priority: rule.priority,
      confidence: rule.confidence,
      source: rule.source
    }
  end

  defp serialize_transaction(transaction) do
    %{
      id: transaction.id,
      category: transaction.category,
      categorization_source: transaction.categorization_source,
      categorization_confidence: transaction.categorization_confidence
    }
  end
end
