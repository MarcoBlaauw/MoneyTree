defmodule MoneyTreeWeb.ObligationController do
  use MoneyTreeWeb, :controller

  alias Ecto.Association.NotLoaded
  alias Ecto.Changeset
  alias MoneyTree.Obligations
  alias MoneyTree.Obligations.Obligation

  def index(%{assigns: %{current_user: current_user}} = conn, _params) do
    obligations =
      current_user
      |> Obligations.list_obligations()
      |> Enum.map(&serialize_obligation/1)

    json(conn, %{data: obligations})
  end

  def show(%{assigns: %{current_user: current_user}} = conn, %{"id" => id}) do
    case Obligations.fetch_obligation(current_user, id) do
      {:ok, obligation} ->
        json(conn, %{data: serialize_obligation(obligation)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "obligation not found"})
    end
  end

  def create(%{assigns: %{current_user: current_user}} = conn, params) do
    case Obligations.create_obligation(current_user, params) do
      {:ok, obligation} ->
        {:ok, obligation} = Obligations.fetch_obligation(current_user, obligation.id)

        conn
        |> put_status(:created)
        |> json(%{data: serialize_obligation(obligation)})

      {:error, :linked_funding_account_required} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{linked_funding_account_id: ["is required"]}})

      {:error, :unauthorized} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "funding account not found"})

      {:error, %Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Changeset.traverse_errors(changeset, &translate_error/1)})
    end
  end

  def update(%{assigns: %{current_user: current_user}} = conn, %{"id" => id} = params) do
    case Obligations.update_obligation(current_user, id, Map.delete(params, "id")) do
      {:ok, obligation} ->
        {:ok, obligation} = Obligations.fetch_obligation(current_user, obligation.id)
        json(conn, %{data: serialize_obligation(obligation)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "obligation not found"})

      {:error, :unauthorized} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "funding account not found"})

      {:error, %Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Changeset.traverse_errors(changeset, &translate_error/1)})
    end
  end

  def delete(%{assigns: %{current_user: current_user}} = conn, %{"id" => id}) do
    case Obligations.delete_obligation(current_user, id) do
      {:ok, _obligation} ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "obligation not found"})
    end
  end

  defp serialize_obligation(%Obligation{} = obligation) do
    funding_account = obligation.linked_funding_account

    %{
      id: obligation.id,
      creditor_payee: obligation.creditor_payee,
      due_day: obligation.due_day,
      due_rule: obligation.due_rule,
      minimum_due_amount: obligation.minimum_due_amount,
      currency: obligation.currency,
      grace_period_days: obligation.grace_period_days,
      alert_preferences: obligation.alert_preferences,
      active: obligation.active,
      linked_funding_account_id: obligation.linked_funding_account_id,
      linked_funding_account:
        if(is_struct(funding_account, NotLoaded),
          do: nil,
          else:
            if funding_account do
              %{
                id: funding_account.id,
                name: funding_account.name,
                currency: funding_account.currency,
                type: funding_account.type,
                subtype: funding_account.subtype
              }
            else
              nil
            end
        ),
      inserted_at: obligation.inserted_at,
      updated_at: obligation.updated_at
    }
  end

  defp translate_error({msg, opts}) do
    Gettext.dgettext(MoneyTreeWeb.Gettext, "errors", msg, opts)
  end

  defp translate_error(msg) when is_binary(msg), do: msg
end
