defmodule MoneyTreeWeb.LoanAlertRuleController do
  use MoneyTreeWeb, :controller

  alias Ecto.Changeset
  alias MoneyTree.Loans
  alias MoneyTree.Loans.AlertRule

  def index(%{assigns: %{current_user: current_user}} = conn, %{"loan_id" => loan_id}) do
    rules =
      current_user
      |> Loans.list_loan_alert_rules(loan_id)
      |> Enum.map(&serialize_rule/1)

    json(conn, %{data: rules})
  end

  def create(%{assigns: %{current_user: current_user}} = conn, %{"loan_id" => loan_id} = params) do
    attrs = Map.delete(params, "loan_id")

    case Loans.create_loan_alert_rule(current_user, loan_id, attrs) do
      {:ok, rule} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_rule(rule)})

      {:error, :not_found} ->
        loan_not_found(conn)

      {:error, %Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  def update(%{assigns: %{current_user: current_user}} = conn, %{"id" => id} = params) do
    attrs = Map.delete(params, "id")

    case Loans.update_loan_alert_rule(current_user, id, attrs) do
      {:ok, rule} ->
        json(conn, %{data: serialize_rule(rule)})

      {:error, :not_found} ->
        not_found(conn)

      {:error, %Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  def delete(%{assigns: %{current_user: current_user}} = conn, %{"id" => id}) do
    case Loans.delete_loan_alert_rule(current_user, id) do
      {:ok, _rule} -> send_resp(conn, :no_content, "")
      {:error, :not_found} -> not_found(conn)
    end
  end

  def evaluate(%{assigns: %{current_user: current_user}} = conn, %{"id" => id}) do
    case Loans.evaluate_loan_alert_rule(current_user, id) do
      {:ok, result} ->
        json(conn, %{
          data: %{
            rule: serialize_rule(result.rule),
            triggered: result.triggered?
          }
        })

      {:error, :not_found} ->
        not_found(conn)

      {:error, %Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  def evaluate_all(%{assigns: %{current_user: current_user}} = conn, %{"loan_id" => loan_id}) do
    case Loans.evaluate_loan_alert_rules(current_user, loan_id) do
      {:ok, summary} ->
        json(conn, %{data: summary})

      {:error, :not_found} ->
        loan_not_found(conn)

      {:error, %Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  defp serialize_rule(%AlertRule{} = rule) do
    %{
      id: rule.id,
      user_id: rule.user_id,
      loan_id: rule.loan_id,
      mortgage_id: rule.mortgage_id,
      name: rule.name,
      kind: rule.kind,
      active: rule.active,
      threshold_config: rule.threshold_config,
      delivery_preferences: rule.delivery_preferences,
      last_evaluated_at: rule.last_evaluated_at,
      last_triggered_at: rule.last_triggered_at,
      inserted_at: rule.inserted_at,
      updated_at: rule.updated_at
    }
  end

  defp loan_not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "loan not found"})
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "loan alert rule not found"})
  end

  defp validation_error(conn, %Changeset{} = changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: Changeset.traverse_errors(changeset, &translate_error/1)})
  end

  defp translate_error({msg, opts}) do
    Gettext.dgettext(MoneyTreeWeb.Gettext, "errors", msg, opts)
  end

  defp translate_error(msg) when is_binary(msg), do: msg
end
