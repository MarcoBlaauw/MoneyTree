defmodule MoneyTreeWeb.ImportExportLive.Index do
  @moduledoc """
  LiveView for manual transaction import and user-scoped data exports.
  """

  use MoneyTreeWeb, :live_view

  alias Decimal
  alias MoneyTree.Accounts
  alias MoneyTree.AI
  alias MoneyTree.AI.Suggestion
  alias MoneyTree.ManualImports
  alias MoneyTree.ManualImports.Batch
  alias MoneyTree.ManualImports.ImportParser

  @default_export_days 365
  @default_import_ai_limit 80
  @ai_status_poll_interval_ms 2_500
  @restorable_batch_statuses ~w(parsed reviewed committing committed rollback_pending)

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: current_user}} = socket) do
    accounts = Accounts.list_accessible_accounts(current_user, order_by: {:asc, :name})
    {import_batch, import_rows} = restore_latest_batch(current_user)
    import_form = default_import_form(accounts, import_batch)

    socket =
      socket
      |> assign(
        page_title: "Import / Export",
        accounts: accounts,
        import_form: import_form,
        manual_account_form: default_manual_account_form(),
        import_batch: import_batch,
        import_rows: import_rows,
        import_headers: [],
        export_days: Integer.to_string(@default_export_days),
        ai_import_run_id: nil,
        ai_import_run_status: nil,
        ai_import_run_error_code: nil,
        ai_import_run_completed_at: nil,
        ai_import_suggestions: %{}
      )
      |> maybe_hydrate_import_ai_run(current_user, import_batch)
      |> maybe_schedule_ai_status_poll()

    {:ok,
     socket
     |> allow_upload(:import_file,
       accept:
         ~w(.csv .xlsx text/csv application/vnd.openxmlformats-officedocument.spreadsheetml.sheet),
       max_entries: 1,
       max_file_size: 10_000_000
     )}
  end

  @impl true
  def handle_event("update-import-form", %{"import" => params}, socket) do
    {:noreply,
     assign(socket, :import_form, merge_import_form(socket.assigns.import_form, params))}
  end

  def handle_event("update-manual-account-form", %{"manual_account" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :manual_account_form,
       merge_manual_account_form(socket.assigns.manual_account_form, params)
     )}
  end

  def handle_event(
        "create-manual-account",
        %{"manual_account" => params},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    case Accounts.create_manual_account(current_user, params) do
      {:ok, account} ->
        accounts = Accounts.list_accessible_accounts(current_user, order_by: {:asc, :name})

        {:noreply,
         socket
         |> assign(
           accounts: accounts,
           import_form: Map.put(socket.assigns.import_form, "account_id", account.id),
           manual_account_form: default_manual_account_form()
         )
         |> put_flash(:info, "Manual account created and selected for import.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Unable to create manual account: #{inspect(changeset.errors)}"
         )}
    end
  end

  def handle_event("stage-import", _params, %{assigns: %{current_user: current_user}} = socket) do
    import_form = socket.assigns.import_form

    with {:ok, account_id} <- selected_account_id(import_form),
         {:ok, upload} <- consume_uploaded_import_file(socket),
         {:ok, batch} <- create_import_batch(current_user, account_id, upload),
         {:ok, headers} <-
           ImportParser.headers(upload.content,
             file_name: upload.file_name,
             file_mime_type: upload.file_mime_type
           ),
         mapping_config <- build_mapping_config(import_form, headers),
         {:ok, parsed} <-
           ImportParser.parse(upload.content, mapping_config,
             file_name: upload.file_name,
             file_mime_type: upload.file_mime_type
           ),
         {:ok, _mapped_batch} <-
           ManualImports.update_mapping(current_user, batch.id, mapping_config),
         {:ok, %{batch: staged_batch}} <-
           ManualImports.stage_rows(current_user, batch.id, parsed.rows) do
      rows = ManualImports.list_rows(current_user, staged_batch.id)

      {:noreply,
       socket
       |> assign(
         import_batch: staged_batch,
         import_rows: rows,
         import_headers: parsed.headers,
         ai_import_run_id: nil,
         ai_import_run_status: nil,
         ai_import_run_error_code: nil,
         ai_import_run_completed_at: nil,
         ai_import_suggestions: %{}
       )
       |> put_flash(
         :info,
         "Staged #{staged_batch.row_count} rows. Review and commit when ready."
       )}
    else
      {:error, :account_required} ->
        {:noreply, put_flash(socket, :error, "Select an account before importing.")}

      {:error, :no_file} ->
        {:noreply,
         put_flash(socket, :error, "Upload a CSV or XLSX file before staging import rows.")}

      {:error, :file_read_failed} ->
        {:noreply, put_flash(socket, :error, "Unable to read uploaded CSV file.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Selected account is not accessible.")}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, "Import setup failed: #{inspect(changeset.errors)}")}
    end
  end

  def handle_event("commit-import", _params, %{assigns: %{current_user: current_user}} = socket) do
    case socket.assigns.import_batch do
      %Batch{id: batch_id} ->
        case ManualImports.commit_batch(current_user, batch_id) do
          {:ok, committed_batch} ->
            rows = ManualImports.list_rows(current_user, batch_id)

            {:noreply,
             socket
             |> assign(import_batch: committed_batch, import_rows: rows)
             |> put_flash(
               :info,
               "Import committed. #{committed_batch.committed_count} rows saved, #{committed_batch.duplicate_count} duplicates excluded."
             )}

          {:error, :account_required} ->
            {:noreply, put_flash(socket, :error, "Batch requires an account before commit.")}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Import batch was not found.")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, put_flash(socket, :error, "Commit failed: #{inspect(changeset.errors)}")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Stage an import batch before committing.")}
    end
  end

  def handle_event(
        "generate-import-ai-suggestions",
        _params,
        %{assigns: %{current_user: current_user, import_batch: %Batch{} = batch}} = socket
      ) do
    case AI.create_import_categorization_run(current_user, batch.id, %{
           "limit" => @default_import_ai_limit
         }) do
      {:ok, run} ->
        {:noreply,
         socket
         |> refresh_ai_import_run(current_user, run.id, :created)
         |> maybe_schedule_ai_status_poll()}

      {:error, :disabled_for_user} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "AI hints are disabled for this user. Enable local AI under Data & privacy settings."
         )}

      {:error, :disabled_globally} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "AI is disabled globally in runtime config (AI_ENABLED)."
         )}

      {:error, :categorization_disabled} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "AI categorization hints are disabled in your AI settings."
         )}

      {:error, :no_import_rows} ->
        {:noreply,
         put_flash(socket, :error, "No reviewable rows are available for AI categorization.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Import batch was not found.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "AI hint generation failed: #{inspect(reason)}")}
    end
  end

  def handle_event("generate-import-ai-suggestions", _params, socket) do
    {:noreply, put_flash(socket, :error, "Stage an import batch before generating AI hints.")}
  end

  def handle_event(
        "refresh-import-ai-status",
        _params,
        %{assigns: %{current_user: current_user, ai_import_run_id: run_id}} = socket
      )
      when is_binary(run_id) do
    {:noreply,
     socket
     |> refresh_ai_import_run(current_user, run_id, :refresh)
     |> maybe_schedule_ai_status_poll()}
  end

  def handle_event("refresh-import-ai-status", _params, socket) do
    {:noreply, put_flash(socket, :error, "Generate AI hints first to refresh run status.")}
  end

  def handle_event(
        "accept-import-ai-suggestion",
        %{"id" => suggestion_id},
        %{assigns: %{current_user: current_user, import_batch: %Batch{} = batch}} = socket
      ) do
    case AI.accept_suggestion(current_user, suggestion_id) do
      {:ok, _suggestion} ->
        rows = ManualImports.list_rows(current_user, batch.id)
        suggestions = ai_suggestions_for_run(current_user, socket.assigns.ai_import_run_id)

        {:noreply,
         socket
         |> assign(:import_rows, rows)
         |> assign(:ai_import_suggestions, ai_suggestions_by_row(suggestions))
         |> put_flash(:info, "AI category hint applied to staged row.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "AI suggestion was not found.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Unable to apply AI hint: #{inspect(reason)}")}
    end
  end

  def handle_event("accept-import-ai-suggestion", _params, socket) do
    {:noreply, put_flash(socket, :error, "Stage an import batch before applying AI hints.")}
  end

  def handle_event("rollback-import", _params, %{assigns: %{current_user: current_user}} = socket) do
    case socket.assigns.import_batch do
      %Batch{id: batch_id} ->
        case ManualImports.rollback_batch(current_user, batch_id) do
          {:ok, rolled_back_batch} ->
            rows = ManualImports.list_rows(current_user, batch_id)

            {:noreply,
             socket
             |> assign(import_batch: rolled_back_batch, import_rows: rows)
             |> put_flash(:info, "Import batch rolled back.")}

          {:error, :not_committed} ->
            {:noreply, put_flash(socket, :error, "Only committed batches can be rolled back.")}

          {:error, :already_rolled_back} ->
            {:noreply, put_flash(socket, :error, "Batch has already been rolled back.")}

          {:error, :unsafe_transfer_matches} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Rollback is blocked because transfer matches were created with transactions outside this batch."
             )}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Import batch was not found.")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, put_flash(socket, :error, "Rollback failed: #{inspect(changeset.errors)}")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Stage and commit an import batch before rollback.")}
    end
  end

  @impl true
  def handle_info(
        {:refresh_ai_import_status, run_id},
        %{assigns: %{current_user: current_user, ai_import_run_id: run_id}} = socket
      ) do
    {:noreply,
     socket
     |> refresh_ai_import_run(current_user, run_id, :poll)
     |> maybe_schedule_ai_status_poll()}
  end

  def handle_info({:refresh_ai_import_status, _run_id}, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-6">
      <.header title="Import / Export" subtitle="Manage data import, export, and privacy-oriented data operations.">
        <:actions>
          <.link navigate={~p"/app/settings/privacy"} class="btn btn-outline">
            Open data & privacy settings
          </.link>
        </:actions>
      </.header>

      <div class="grid gap-4 lg:grid-cols-2">
        <article class={[
          "space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm",
          if(@import_batch || @import_rows != [], do: "lg:col-span-2")
        ]}>
          <h2 class="text-base font-semibold text-zinc-900">Import transactions</h2>
          <p class="mt-2 text-sm text-zinc-600">
            Use review-first imports so extracted records can be validated before any persistence.
          </p>

          <.form for={%{}} id="import-form" phx-change="update-import-form" phx-submit="stage-import">
            <div class="space-y-4">
              <div>
                <label class="text-sm font-medium text-zinc-700" for="import-account-id">
                  Destination account
                </label>
                <select
                  id="import-account-id"
                  name="import[account_id]"
                  class="input"
                  value={@import_form["account_id"]}
                  disabled={@accounts == []}
                >
                  <option value="">Select account</option>
                  <%= for account <- @accounts do %>
                    <option value={account.id} selected={@import_form["account_id"] == account.id}>
                      <%= account.name %> (<%= account.currency %>)
                    </option>
                  <% end %>
                </select>
                <p :if={@accounts == []} class="mt-1 text-xs text-amber-700">
                  No accessible accounts yet. Create one below or connect an institution first.
                </p>
              </div>

              <div>
                <label class="text-sm font-medium text-zinc-700">
                  CSV or Excel file
                </label>
                <div class="mt-1 rounded-lg border border-zinc-200 p-3">
                  <.live_file_input upload={@uploads.import_file} class="w-full text-sm text-zinc-700" />
                </div>
              </div>

              <div class="grid gap-3 md:grid-cols-2">
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="posted-at-column">Posted date column</label>
                  <input
                    id="posted-at-column"
                    name="import[posted_at_column]"
                    class="input"
                    type="text"
                    value={@import_form["posted_at_column"]}
                    placeholder="Date"
                  />
                </div>
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="description-column">Description column</label>
                  <input
                    id="description-column"
                    name="import[description_column]"
                    class="input"
                    type="text"
                    value={@import_form["description_column"]}
                    placeholder="Description"
                  />
                </div>
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="amount-column">Amount column</label>
                  <input
                    id="amount-column"
                    name="import[amount_column]"
                    class="input"
                    type="text"
                    value={@import_form["amount_column"]}
                    placeholder="Amount"
                  />
                </div>
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="status-column">Status column (optional)</label>
                  <input
                    id="status-column"
                    name="import[status_column]"
                    class="input"
                    type="text"
                    value={@import_form["status_column"]}
                    placeholder="Status"
                  />
                </div>
              </div>

              <div class="flex flex-wrap gap-2">
                <button class="btn" type="submit" disabled={@accounts == []}>Stage import</button>

                <button
                  :if={@import_batch}
                  class="btn btn-outline"
                  type="button"
                  phx-click="generate-import-ai-suggestions"
                >
                  Generate AI category hints
                </button>

                <button
                  :if={@ai_import_run_id}
                  class="btn btn-outline"
                  type="button"
                  phx-click="refresh-import-ai-status"
                >
                  Refresh AI run status
                </button>

                <button
                  :if={@import_batch}
                  class="btn btn-outline"
                  type="button"
                  phx-click="commit-import"
                >
                  Commit staged rows
                </button>

                <button
                  :if={@import_batch && @import_batch.status == "committed"}
                  class="btn btn-outline"
                  type="button"
                  phx-click="rollback-import"
                >
                  Roll back committed batch
                </button>
              </div>
            </div>
          </.form>

          <div class="space-y-3 rounded-lg border border-zinc-100 bg-zinc-50 p-3">
            <p class="text-sm font-medium text-zinc-800">Need an account first?</p>
            <p class="text-xs text-zinc-500">
              Create a manual account so imports can run before institution linking is configured.
            </p>
            <.form
              for={%{}}
              id="manual-account-form"
              phx-change="update-manual-account-form"
              phx-submit="create-manual-account"
            >
              <div class="grid gap-3 md:grid-cols-2">
                <div class="md:col-span-2">
                  <label class="text-sm font-medium text-zinc-700" for="manual-account-name">
                    Account name
                  </label>
                  <input
                    id="manual-account-name"
                    name="manual_account[name]"
                    class="input"
                    type="text"
                    value={@manual_account_form["name"]}
                    placeholder="Manual Checking"
                    required
                  />
                </div>
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="manual-account-type">
                    Type
                  </label>
                  <select
                    id="manual-account-type"
                    name="manual_account[type]"
                    class="input"
                    value={@manual_account_form["type"]}
                  >
                    <option value="depository">depository</option>
                    <option value="credit">credit</option>
                    <option value="loan">loan</option>
                    <option value="investment">investment</option>
                    <option value="other">other</option>
                  </select>
                </div>
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="manual-account-subtype">
                    Subtype
                  </label>
                  <input
                    id="manual-account-subtype"
                    name="manual_account[subtype]"
                    class="input"
                    type="text"
                    value={@manual_account_form["subtype"]}
                    placeholder="checking"
                  />
                </div>
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="manual-account-currency">
                    Currency
                  </label>
                  <input
                    id="manual-account-currency"
                    name="manual_account[currency]"
                    class="input"
                    type="text"
                    value={@manual_account_form["currency"]}
                    placeholder="USD"
                  />
                </div>
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="manual-account-balance">
                    Starting balance
                  </label>
                  <input
                    id="manual-account-balance"
                    name="manual_account[current_balance]"
                    class="input"
                    type="number"
                    step="0.01"
                    value={@manual_account_form["current_balance"]}
                  />
                </div>
              </div>
              <div class="mt-3">
                <button class="btn btn-outline" type="submit">Create manual account</button>
              </div>
            </.form>
          </div>

          <div :if={@import_batch} class="space-y-3 rounded-lg border border-zinc-100 bg-zinc-50 p-3 text-sm text-zinc-600">
            <p class="font-medium text-zinc-800">
              Batch status: <%= @import_batch.status %>
            </p>
            <p>
              Rows: <%= @import_batch.row_count %> · Committed: <%= @import_batch.committed_count %> · Duplicates: <%= @import_batch.duplicate_count %> · Errors: <%= @import_batch.error_count %>
            </p>
            <p :if={@import_headers != []} class="text-xs text-zinc-500">
              Parsed headers: <%= Enum.join(@import_headers, ", ") %>
            </p>
          </div>

          <div
            :if={@ai_import_run_id}
            class="space-y-2 rounded-lg border border-zinc-100 bg-zinc-50 p-3 text-sm text-zinc-700"
          >
            <p class="font-medium text-zinc-800">
              AI run status: <%= @ai_import_run_status || "unknown" %>
            </p>
            <p class="text-xs text-zinc-500">Run ID: <%= @ai_import_run_id %></p>
            <p :if={@ai_import_run_error_code} class="text-xs text-rose-700">
              Error code: <%= @ai_import_run_error_code %>
            </p>
            <p :if={@ai_import_run_completed_at} class="text-xs text-zinc-500">
              Completed: <%= format_datetime(@ai_import_run_completed_at) %>
            </p>
          </div>

          <div :if={@import_rows != []} class="overflow-x-auto">
            <table class="w-full table-auto text-left text-sm" aria-label="Staged import rows">
              <thead>
                <tr class="border-b border-zinc-200 text-xs uppercase tracking-wide text-zinc-500">
                  <th class="py-2 pr-3">Row</th>
                  <th class="py-2 pr-3">Date</th>
                  <th class="py-2 pr-3">Description</th>
                  <th class="py-2 pr-3">Amount</th>
                  <th class="py-2 pr-3">Parse</th>
                  <th class="py-2">Decision</th>
                  <th class="py-2 pr-3">AI hint</th>
                  <th class="py-2">Apply</th>
                </tr>
              </thead>
              <tbody>
                <%= for row <- Enum.take(@import_rows, 15) do %>
                  <% suggestion = Map.get(@ai_import_suggestions, row.id) %>
                  <tr class="border-b border-zinc-100">
                    <td class="py-2 pr-3 text-zinc-700"><%= row.row_index %></td>
                    <td class="py-2 pr-3 text-zinc-700"><%= format_datetime(row.posted_at) %></td>
                    <td class="py-2 pr-3 text-zinc-900"><%= row.description || "—" %></td>
                    <td class="py-2 pr-3 text-zinc-700"><%= decimal_to_string(row.amount) %></td>
                    <td class="py-2 pr-3 text-zinc-700"><%= row.parse_status %></td>
                    <td class="py-2 text-zinc-700"><%= row.review_decision %></td>
                    <td class="py-2 pr-3 text-zinc-700"><%= suggestion_summary(suggestion) %></td>
                    <td class="py-2 text-zinc-700">
                      <button
                        :if={match?(%Suggestion{status: "pending"}, suggestion)}
                        class="btn btn-outline btn-sm"
                        type="button"
                        phx-click="accept-import-ai-suggestion"
                        phx-value-id={suggestion.id}
                      >
                        Apply hint
                      </button>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
            <p :if={length(@import_rows) > 15} class="mt-2 text-xs text-zinc-500">
              Showing first 15 staged rows.
            </p>
          </div>
        </article>

        <article class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <h2 class="text-base font-semibold text-zinc-900">Export data</h2>
          <p class="mt-2 text-sm text-zinc-600">
            Generate user-scoped exports for portability and backups from a dedicated surface.
          </p>

          <form id="export-transactions-form" action={~p"/app/import-export/transactions.csv"} method="get">
            <div class="space-y-3 rounded-lg border border-zinc-100 bg-zinc-50 p-3">
              <label class="text-sm font-medium text-zinc-700" for="export-days">
                Transaction export window (days)
              </label>
              <input
                id="export-days"
                class="input"
                type="number"
                min="1"
                max="3650"
                name="days"
                value={@export_days}
              />
              <button class="btn w-full sm:w-auto" type="submit">Download transactions CSV</button>
            </div>
          </form>

          <div class="rounded-lg border border-zinc-100 bg-zinc-50 p-3">
            <a class="btn btn-outline w-full sm:w-auto" href={~p"/app/import-export/budgets.csv"}>
              Download budgets CSV
            </a>
          </div>
        </article>
      </div>
    </section>
    """
  end

  defp consume_uploaded_import_file(socket) do
    entries =
      consume_uploaded_entries(socket, :import_file, fn %{path: path}, entry ->
        case File.read(path) do
          {:ok, content} ->
            {:ok,
             %{
               content: content,
               file_name: entry.client_name || "import.csv",
               file_mime_type: entry.client_type || "text/csv",
               file_size_bytes: entry.client_size || byte_size(content),
               file_sha256: sha256(content)
             }}

          {:error, _reason} ->
            {:postpone, :file_read_failed}
        end
      end)

    case entries do
      [upload] -> {:ok, upload}
      [] -> {:error, :no_file}
      _ -> {:ok, hd(entries)}
    end
  rescue
    _ -> {:error, :file_read_failed}
  end

  defp create_import_batch(current_user, account_id, upload) do
    source_institution =
      if xlsx_file_name?(upload.file_name), do: "generic_xlsx", else: "generic_csv"

    ManualImports.create_batch(current_user, %{
      "account_id" => account_id,
      "source_institution" => source_institution,
      "file_name" => upload.file_name,
      "file_mime_type" => upload.file_mime_type,
      "file_size_bytes" => upload.file_size_bytes,
      "file_sha256" => upload.file_sha256
    })
  end

  defp selected_account_id(import_form) do
    case Map.get(import_form, "account_id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :account_required}
    end
  end

  defp default_import_form(accounts, import_batch) do
    selected_account_id =
      case import_batch do
        %Batch{account_id: account_id} when is_binary(account_id) and account_id != "" ->
          account_id

        _ ->
          accounts |> List.first() |> then(&if(&1, do: &1.id, else: ""))
      end

    %{
      "account_id" => selected_account_id,
      "posted_at_column" => "",
      "description_column" => "",
      "amount_column" => "",
      "debit_column" => "",
      "credit_column" => "",
      "status_column" => ""
    }
  end

  defp default_manual_account_form do
    %{
      "name" => "",
      "type" => "depository",
      "subtype" => "checking",
      "currency" => "USD",
      "current_balance" => "0.00"
    }
  end

  defp merge_import_form(current, params) do
    Map.merge(current, %{
      "account_id" => Map.get(params, "account_id", current["account_id"]),
      "posted_at_column" => Map.get(params, "posted_at_column", current["posted_at_column"]),
      "description_column" =>
        Map.get(params, "description_column", current["description_column"]),
      "amount_column" => Map.get(params, "amount_column", current["amount_column"]),
      "debit_column" => Map.get(params, "debit_column", current["debit_column"]),
      "credit_column" => Map.get(params, "credit_column", current["credit_column"]),
      "status_column" => Map.get(params, "status_column", current["status_column"])
    })
  end

  defp merge_manual_account_form(current, params) do
    Map.merge(current, %{
      "name" => Map.get(params, "name", current["name"]),
      "type" => Map.get(params, "type", current["type"]),
      "subtype" => Map.get(params, "subtype", current["subtype"]),
      "currency" => Map.get(params, "currency", current["currency"]),
      "current_balance" => Map.get(params, "current_balance", current["current_balance"])
    })
  end

  defp build_mapping_config(import_form, headers) when is_list(headers) do
    guessed = guessed_mapping(headers)

    columns =
      %{
        "posted_at" => present_or_fallback(import_form["posted_at_column"], guessed["posted_at"]),
        "description" =>
          present_or_fallback(import_form["description_column"], guessed["description"]),
        "amount" => present_or_fallback(import_form["amount_column"], guessed["amount"]),
        "debit" => present_or_fallback(import_form["debit_column"], guessed["debit"]),
        "credit" => present_or_fallback(import_form["credit_column"], guessed["credit"]),
        "status" => present_or_fallback(import_form["status_column"], guessed["status"])
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.into(%{})

    %{"columns" => columns}
  end

  defp guessed_mapping(headers) do
    normalized =
      headers
      |> Enum.map(fn header -> {normalize_header_key(header), header} end)
      |> Enum.reject(fn {key, _header} -> key == "" end)

    %{
      "posted_at" =>
        find_header(normalized, [
          "date",
          "posted at",
          "posted date",
          "posting date",
          "transaction date",
          "post date",
          "date posted"
        ]),
      "description" =>
        find_header(normalized, [
          "description",
          "transaction description",
          "memo",
          "details",
          "name",
          "merchant",
          "payee"
        ]),
      "amount" =>
        find_header(normalized, [
          "amount",
          "signed amount",
          "transaction amount"
        ]),
      "debit" => find_header(normalized, ["debit", "debits", "withdrawal", "outflow"]),
      "credit" => find_header(normalized, ["credit", "credits", "deposit", "inflow"]),
      "status" => find_header(normalized, ["status", "transaction status"])
    }
  end

  defp find_header(normalized_headers, candidates) when is_list(normalized_headers) do
    exact_match =
      Enum.find_value(candidates, fn candidate ->
        candidate_key = normalize_header_key(candidate)

        normalized_headers
        |> Enum.find_value(fn {header_key, original} ->
          if header_key == candidate_key, do: original, else: nil
        end)
      end)

    exact_match ||
      Enum.find_value(candidates, fn candidate ->
        candidate_key = normalize_header_key(candidate)

        normalized_headers
        |> Enum.find_value(fn {header_key, original} ->
          if String.contains?(header_key, candidate_key), do: original, else: nil
        end)
      end)
  end

  defp normalize_header_key(value) when is_binary(value) do
    value
    |> String.replace_prefix("\uFEFF", "")
    |> replace_header_spaces()
    |> remove_zero_width_chars()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, " ")
    |> String.trim()
  end

  defp normalize_header_key(value), do: value |> to_string() |> normalize_header_key()

  defp replace_header_spaces(value) when is_binary(value) do
    value
    |> String.replace("\u00A0", " ")
    |> String.replace("\u2007", " ")
    |> String.replace("\u202F", " ")
  end

  defp remove_zero_width_chars(value) when is_binary(value) do
    value
    |> String.replace("\u200B", "")
    |> String.replace("\u200C", "")
    |> String.replace("\u200D", "")
    |> String.replace("\u2060", "")
  end

  defp present_or_fallback(value, fallback) do
    case value do
      nil -> fallback
      "" -> fallback
      present -> present
    end
  end

  defp format_datetime(nil), do: ""
  defp format_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_datetime(other), do: to_string(other)

  defp decimal_to_string(nil), do: ""
  defp decimal_to_string(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp decimal_to_string(other), do: to_string(other)

  defp suggestion_summary(nil), do: "—"

  defp suggestion_summary(%Suggestion{payload: payload, confidence: confidence, status: status})
       when is_map(payload) do
    category =
      case Map.get(payload, "category") do
        value when is_binary(value) and value != "" -> value
        _ -> "unknown category"
      end

    confidence_text =
      case confidence do
        %Decimal{} = value -> " (#{Decimal.to_string(value, :normal)})"
        _ -> ""
      end

    case status do
      "pending" -> "#{category}#{confidence_text}"
      "accepted" -> "Applied: #{category}"
      "edited_and_accepted" -> "Applied: #{category}"
      other when is_binary(other) -> "#{category} (#{other})"
      _ -> category
    end
  end

  defp suggestion_summary(_), do: "—"

  defp ai_suggestions_for_run(_current_user, nil), do: []

  defp ai_suggestions_for_run(current_user, run_id) do
    AI.list_suggestions(current_user, run_id: run_id, target_type: "manual_import_row")
  end

  defp maybe_hydrate_import_ai_run(socket, _current_user, nil), do: socket

  defp maybe_hydrate_import_ai_run(socket, current_user, %Batch{} = batch) do
    case latest_import_ai_run(current_user, batch.id) do
      nil -> socket
      run -> refresh_ai_import_run(socket, current_user, run.id, :hydrate)
    end
  end

  defp latest_import_ai_run(current_user, batch_id) when is_binary(batch_id) do
    current_user
    |> AI.list_runs(feature: "import_categorization", limit: 20)
    |> Enum.find(fn run -> run_scope_batch_id(run) == batch_id end)
  end

  defp latest_import_ai_run(_current_user, _batch_id), do: nil

  defp run_scope_batch_id(run) do
    scope = run.input_scope || %{}
    Map.get(scope, "batch_id") || Map.get(scope, :batch_id)
  end

  defp restore_latest_batch(current_user) do
    batch =
      current_user
      |> ManualImports.list_batches(limit: 10)
      |> Enum.find(&restorable_batch?/1)

    case batch do
      %Batch{} = value -> {value, ManualImports.list_rows(current_user, value.id)}
      _ -> {nil, []}
    end
  end

  defp restorable_batch?(%Batch{} = batch) do
    is_binary(batch.status) and batch.status in @restorable_batch_statuses and batch.row_count > 0
  end

  defp restorable_batch?(_batch), do: false

  defp refresh_ai_import_run(socket, current_user, run_id, mode) when is_binary(run_id) do
    case AI.fetch_run(current_user, run_id) do
      {:ok, run} ->
        suggestions =
          if run.status == "completed",
            do: ai_suggestions_for_run(current_user, run.id),
            else: []

        socket =
          socket
          |> assign(:ai_import_run_id, run.id)
          |> assign(:ai_import_run_status, run.status)
          |> assign(:ai_import_run_error_code, run.error_code)
          |> assign(:ai_import_run_completed_at, run.completed_at)
          |> assign(:ai_import_suggestions, ai_suggestions_by_row(suggestions))

        case ai_run_status_message(run.status, length(suggestions), mode, run.error_code) do
          message when is_binary(message) -> put_flash(socket, :info, message)
          _ -> socket
        end

      {:error, :not_found} ->
        put_flash(socket, :error, "AI run not found.")
    end
  end

  defp ai_run_status_message("completed", suggestion_count, _mode, _error_code) do
    "AI run completed. #{suggestion_count} category hints are available."
  end

  defp ai_run_status_message("failed", _suggestion_count, _mode, error_code) do
    "AI run failed.#{if is_binary(error_code), do: " Error code: #{error_code}.", else: ""}"
  end

  defp ai_run_status_message("running", _suggestion_count, mode, _error_code)
       when mode in [:poll, :hydrate] do
    nil
  end

  defp ai_run_status_message("running", _suggestion_count, _mode, _error_code) do
    "AI run is still running. Refresh status in a moment."
  end

  defp ai_run_status_message("queued", _suggestion_count, mode, _error_code)
       when mode in [:poll, :hydrate] do
    nil
  end

  defp ai_run_status_message("queued", _suggestion_count, :created, _error_code) do
    "AI run queued. Refresh AI run status in a moment."
  end

  defp ai_run_status_message("queued", _suggestion_count, _mode, _error_code) do
    "AI run is still queued. Refresh status in a moment."
  end

  defp ai_run_status_message(status, _suggestion_count, _mode, _error_code)
       when is_binary(status) do
    "AI run status: #{status}."
  end

  defp ai_run_status_message(_status, _suggestion_count, _mode, _error_code) do
    "AI run status updated."
  end

  defp ai_suggestions_by_row(suggestions) when is_list(suggestions) do
    Enum.reduce(suggestions, %{}, fn suggestion, acc ->
      target_id = suggestion.target_id

      if is_binary(target_id) and not Map.has_key?(acc, target_id) do
        Map.put(acc, target_id, suggestion)
      else
        acc
      end
    end)
  end

  defp maybe_schedule_ai_status_poll(
         %{assigns: %{ai_import_run_id: run_id, ai_import_run_status: status}} = socket
       )
       when is_binary(run_id) and status in ["queued", "running"] do
    Process.send_after(self(), {:refresh_ai_import_status, run_id}, @ai_status_poll_interval_ms)
    socket
  end

  defp maybe_schedule_ai_status_poll(socket), do: socket

  defp sha256(content) do
    :sha256
    |> :crypto.hash(content)
    |> Base.encode16(case: :lower)
  end

  defp xlsx_file_name?(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.ends_with?(".xlsx")
  end

  defp xlsx_file_name?(_name), do: false
end
