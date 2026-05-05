defmodule MoneyTreeWeb.ManualImportController do
  use MoneyTreeWeb, :controller

  alias Ecto.Changeset
  alias MoneyTree.ManualImports
  alias MoneyTree.ManualImports.Batch
  alias MoneyTree.ManualImports.ImportParser
  alias MoneyTree.ManualImports.Row

  def index(%{assigns: %{current_user: current_user}} = conn, _params) do
    batches =
      current_user
      |> ManualImports.list_batches()
      |> Enum.map(&serialize_batch/1)

    json(conn, %{data: batches})
  end

  def show(%{assigns: %{current_user: current_user}} = conn, %{"id" => id}) do
    case ManualImports.get_batch(current_user, id) do
      {:ok, batch} ->
        json(conn, %{data: serialize_batch(batch)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "manual import batch not found"})
    end
  end

  def create(%{assigns: %{current_user: current_user}} = conn, params) do
    attrs =
      params
      |> Map.drop(["file"])
      |> maybe_put_file_attrs(params["file"])

    case ManualImports.create_batch(current_user, attrs) do
      {:ok, batch} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_batch(batch)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "account not found"})

      {:error, %Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Changeset.traverse_errors(changeset, &translate_error/1)})
    end
  end

  def update_mapping(
        %{assigns: %{current_user: current_user}} = conn,
        %{
          "id" => id,
          "mapping_config" => mapping_config
        } = params
      )
      when is_map(mapping_config) do
    attrs = Map.take(params, ["selected_preset_key", "detected_preset_key"])

    case ManualImports.update_mapping(current_user, id, mapping_config, attrs) do
      {:ok, batch} ->
        json(conn, %{data: serialize_batch(batch)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "manual import batch not found"})

      {:error, %Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Changeset.traverse_errors(changeset, &translate_error/1)})
    end
  end

  def update_mapping(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "mapping_config is required"})
  end

  def parse(%{assigns: %{current_user: current_user}} = conn, %{"id" => id} = params) do
    with {:ok, batch} <- ManualImports.get_batch(current_user, id),
         {:ok, content, file_attrs} <- fetch_import_content(params),
         mapping_config <- params["mapping_config"] || batch.mapping_config || %{},
         {:ok, parsed} <-
           ImportParser.parse(content, mapping_config,
             file_name: Map.get(file_attrs, "file_name"),
             file_mime_type: Map.get(file_attrs, "file_mime_type")
           ),
         {:ok, _mapped_batch} <-
           ManualImports.update_mapping(current_user, batch.id, mapping_config, file_attrs),
         {:ok, %{batch: staged_batch}} <-
           ManualImports.stage_rows(current_user, batch.id, parsed.rows) do
      json(conn, %{
        data: %{
          batch: serialize_batch(staged_batch),
          rows_inserted: length(parsed.rows),
          headers: parsed.headers
        }
      })
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "manual import batch not found"})

      {:error, :missing_file} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "file or csv_content is required"})

      {:error, :file_read_failed} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "unable to read uploaded file"})

      {:error, message} when is_binary(message) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: message})

      {:error, %Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Changeset.traverse_errors(changeset, &translate_error/1)})
    end
  end

  def rows(%{assigns: %{current_user: current_user}} = conn, %{"id" => id} = params) do
    case ManualImports.get_batch(current_user, id) do
      {:ok, _batch} ->
        rows =
          current_user
          |> ManualImports.list_rows(id,
            parse_status: params["parse_status"],
            review_decision: params["review_decision"]
          )
          |> Enum.map(&serialize_row/1)

        json(conn, %{data: rows})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "manual import batch not found"})
    end
  end

  def update_rows(%{assigns: %{current_user: current_user}} = conn, %{"id" => id, "rows" => rows})
      when is_list(rows) do
    case ManualImports.update_rows(current_user, id, rows) do
      {:ok, batch} ->
        json(conn, %{data: serialize_batch(batch)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "manual import batch not found"})

      {:error, %Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Changeset.traverse_errors(changeset, &translate_error/1)})
    end
  end

  def update_rows(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "rows must be a list"})
  end

  def commit(%{assigns: %{current_user: current_user}} = conn, %{"id" => id}) do
    case ManualImports.commit_batch(current_user, id) do
      {:ok, batch} ->
        json(conn, %{data: serialize_batch(batch)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "manual import batch not found"})

      {:error, :account_required} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{account_id: ["is required before commit"]}})

      {:error, %Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Changeset.traverse_errors(changeset, &translate_error/1)})
    end
  end

  def rollback(%{assigns: %{current_user: current_user}} = conn, %{"id" => id}) do
    case ManualImports.rollback_batch(current_user, id) do
      {:ok, batch} ->
        json(conn, %{data: serialize_batch(batch)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "manual import batch not found"})

      {:error, :not_committed} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "only committed batches can be rolled back"})

      {:error, :already_rolled_back} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "batch has already been rolled back"})

      {:error, :unsafe_transfer_matches} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error:
            "rollback is blocked because this batch has transfer matches with transactions outside the batch"
        })

      {:error, %Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Changeset.traverse_errors(changeset, &translate_error/1)})
    end
  end

  defp fetch_import_content(%{"csv_content" => content}) when is_binary(content) do
    {:ok, content, %{}}
  end

  defp fetch_import_content(%{"file" => %Plug.Upload{} = upload}) do
    case File.read(upload.path) do
      {:ok, content} ->
        attrs = %{
          "file_name" => upload.filename,
          "file_mime_type" => upload.content_type,
          "file_size_bytes" => byte_size(content),
          "file_sha256" => sha256(content)
        }

        {:ok, content, attrs}

      {:error, _reason} ->
        {:error, :file_read_failed}
    end
  end

  defp fetch_import_content(_params), do: {:error, :missing_file}

  defp maybe_put_file_attrs(attrs, nil), do: attrs

  defp maybe_put_file_attrs(attrs, %Plug.Upload{} = upload) do
    attrs
    |> Map.put_new("file_name", upload.filename)
    |> Map.put_new("file_mime_type", upload.content_type)
  end

  defp serialize_batch(%Batch{} = batch) do
    %{
      id: batch.id,
      user_id: batch.user_id,
      account_id: batch.account_id,
      source_institution: batch.source_institution,
      source_account_label: batch.source_account_label,
      file_name: batch.file_name,
      file_mime_type: batch.file_mime_type,
      file_size_bytes: batch.file_size_bytes,
      file_sha256: batch.file_sha256,
      detected_preset_key: batch.detected_preset_key,
      selected_preset_key: batch.selected_preset_key,
      mapping_config: batch.mapping_config || %{},
      status: batch.status,
      row_count: batch.row_count,
      accepted_count: batch.accepted_count,
      excluded_count: batch.excluded_count,
      duplicate_count: batch.duplicate_count,
      committed_count: batch.committed_count,
      error_count: batch.error_count,
      started_at: batch.started_at,
      committed_at: batch.committed_at,
      rolled_back_at: batch.rolled_back_at,
      inserted_at: batch.inserted_at,
      updated_at: batch.updated_at
    }
  end

  defp serialize_row(%Row{} = row) do
    %{
      id: row.id,
      manual_import_batch_id: row.manual_import_batch_id,
      row_index: row.row_index,
      raw_row: row.raw_row,
      parse_status: row.parse_status,
      parse_errors: row.parse_errors,
      posted_at: row.posted_at,
      authorized_at: row.authorized_at,
      description: row.description,
      original_description: row.original_description,
      merchant_name: row.merchant_name,
      amount: row.amount,
      currency: row.currency,
      direction: row.direction,
      external_transaction_id: row.external_transaction_id,
      source_reference: row.source_reference,
      check_number: row.check_number,
      category_name_snapshot: row.category_name_snapshot,
      review_decision: row.review_decision,
      duplicate_candidate_transaction_id: row.duplicate_candidate_transaction_id,
      duplicate_confidence: row.duplicate_confidence,
      transfer_match_candidate_transaction_id: row.transfer_match_candidate_transaction_id,
      transfer_match_confidence: row.transfer_match_confidence,
      transfer_match_status: row.transfer_match_status,
      committed_transaction_id: row.committed_transaction_id,
      inserted_at: row.inserted_at,
      updated_at: row.updated_at
    }
  end

  defp sha256(content) do
    :sha256
    |> :crypto.hash(content)
    |> Base.encode16(case: :lower)
  end

  defp translate_error({msg, opts}) do
    Gettext.dgettext(MoneyTreeWeb.Gettext, "errors", msg, opts)
  end

  defp translate_error(msg) when is_binary(msg), do: msg
end
