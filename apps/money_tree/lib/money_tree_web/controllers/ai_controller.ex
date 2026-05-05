defmodule MoneyTreeWeb.AIController do
  use MoneyTreeWeb, :controller

  alias Ecto.Changeset
  alias MoneyTree.AI
  alias MoneyTree.AI.Suggestion
  alias MoneyTree.AI.SuggestionRun
  alias MoneyTree.AI.UserPreference

  def settings(%{assigns: %{current_user: current_user}} = conn, _params) do
    json(conn, %{data: AI.settings_snapshot(current_user)})
  end

  def update_settings(
        %{assigns: %{current_user: current_user}} = conn,
        %{"settings" => settings}
      )
      when is_map(settings) do
    case AI.update_settings(current_user, settings) do
      {:ok, %UserPreference{} = _preference} ->
        json(conn, %{data: AI.settings_snapshot(current_user)})

      {:error, %Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Changeset.traverse_errors(changeset, &translate_error/1)})
    end
  end

  def update_settings(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "settings map is required"})
  end

  def test_connection(%{assigns: %{current_user: current_user}} = conn, params) do
    overrides = Map.get(params, "settings", %{})

    case AI.test_connection(current_user, overrides) do
      {:ok, result} ->
        json(conn, %{data: result})

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: to_string(reason)})
    end
  end

  def models(%{assigns: %{current_user: current_user}} = conn, _params) do
    case AI.list_models(current_user) do
      {:ok, models} ->
        json(conn, %{data: %{models: models}})

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: to_string(reason)})
    end
  end

  def create_categorization_run(%{assigns: %{current_user: current_user}} = conn, params) do
    opts = Map.take(params, ["limit"])

    case AI.create_categorization_run(current_user, opts) do
      {:ok, %SuggestionRun{} = run} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_run(run)})

      {:error, :disabled_for_user} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "ai is disabled for this user"})

      {:error, :disabled_globally} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "ai is disabled globally"})

      {:error, :categorization_disabled} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "categorization suggestions are disabled"})

      {:error, :no_transactions} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "no uncategorized transactions found"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: to_string(reason)})
    end
  end

  def create_import_categorization_run(
        %{assigns: %{current_user: current_user}} = conn,
        %{"batch_id" => batch_id} = params
      )
      when is_binary(batch_id) do
    opts = Map.take(params, ["limit"])

    case AI.create_import_categorization_run(current_user, batch_id, opts) do
      {:ok, %SuggestionRun{} = run} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_run(run)})

      {:error, :disabled_for_user} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "ai is disabled for this user"})

      {:error, :disabled_globally} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "ai is disabled globally"})

      {:error, :categorization_disabled} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "categorization suggestions are disabled"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "manual import batch not found"})

      {:error, :no_import_rows} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "no reviewable import rows found"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: to_string(reason)})
    end
  end

  def create_import_categorization_run(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "batch_id is required"})
  end

  def list_runs(%{assigns: %{current_user: current_user}} = conn, params) do
    runs =
      AI.list_runs(current_user,
        feature: params["feature"],
        status: params["status"]
      )

    json(conn, %{data: Enum.map(runs, &serialize_run/1)})
  end

  def list_suggestions(%{assigns: %{current_user: current_user}} = conn, params) do
    suggestions =
      AI.list_suggestions(current_user,
        status: params["status"],
        run_id: params["run_id"],
        target_type: params["target_type"]
      )

    json(conn, %{data: Enum.map(suggestions, &serialize_suggestion/1)})
  end

  def accept_suggestion(%{assigns: %{current_user: current_user}} = conn, %{"id" => id}) do
    case AI.accept_suggestion(current_user, id) do
      {:ok, %Suggestion{} = suggestion} ->
        json(conn, %{data: serialize_suggestion(suggestion)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "suggestion not found"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: to_string(reason)})
    end
  end

  def reject_suggestion(%{assigns: %{current_user: current_user}} = conn, %{"id" => id}) do
    case AI.reject_suggestion(current_user, id) do
      {:ok, %Suggestion{} = suggestion} ->
        json(conn, %{data: serialize_suggestion(suggestion)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "suggestion not found"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: to_string(reason)})
    end
  end

  def apply_edited_suggestion(
        %{assigns: %{current_user: current_user}} = conn,
        %{"id" => id, "payload" => payload}
      )
      when is_map(payload) do
    case AI.apply_edited_suggestion(current_user, id, payload) do
      {:ok, %Suggestion{} = suggestion} ->
        json(conn, %{data: serialize_suggestion(suggestion)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "suggestion not found"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: to_string(reason)})
    end
  end

  def apply_edited_suggestion(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "payload map is required"})
  end

  defp serialize_run(%SuggestionRun{} = run) do
    %{
      id: run.id,
      user_id: run.user_id,
      provider: run.provider,
      model: run.model,
      feature: run.feature,
      status: run.status,
      input_scope: run.input_scope || %{},
      prompt_version: run.prompt_version,
      schema_version: run.schema_version,
      started_at: run.started_at,
      completed_at: run.completed_at,
      duration_ms: run.duration_ms,
      error_code: run.error_code,
      error_message_safe: run.error_message_safe,
      inserted_at: run.inserted_at,
      updated_at: run.updated_at
    }
  end

  defp serialize_suggestion(%Suggestion{} = suggestion) do
    %{
      id: suggestion.id,
      ai_suggestion_run_id: suggestion.ai_suggestion_run_id,
      user_id: suggestion.user_id,
      target_type: suggestion.target_type,
      target_id: suggestion.target_id,
      suggestion_type: suggestion.suggestion_type,
      payload: suggestion.payload || %{},
      approved_payload: suggestion.approved_payload || %{},
      confidence: suggestion.confidence,
      reason: suggestion.reason,
      evidence: suggestion.evidence || %{},
      status: suggestion.status,
      reviewed_by_user_id: suggestion.reviewed_by_user_id,
      reviewed_at: suggestion.reviewed_at,
      applied_at: suggestion.applied_at,
      inserted_at: suggestion.inserted_at,
      updated_at: suggestion.updated_at
    }
  end

  defp translate_error({msg, opts}) do
    Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
      opts
      |> Keyword.get(String.to_existing_atom(key), key)
      |> to_string()
    end)
  end

  defp translate_error(msg) when is_binary(msg), do: msg
end
