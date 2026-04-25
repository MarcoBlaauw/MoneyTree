defmodule MoneyTreeWeb.ImportExportLive.Index do
  @moduledoc """
  LiveView for manual transaction import and user-scoped data exports.
  """

  use MoneyTreeWeb, :live_view

  alias Decimal
  alias MoneyTree.Accounts
  alias MoneyTree.ManualImports
  alias MoneyTree.ManualImports.Batch
  alias MoneyTree.ManualImports.CSVParser

  @default_export_days 365

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: current_user}} = socket) do
    accounts = Accounts.list_accessible_accounts(current_user, order_by: {:asc, :name})

    {:ok,
     socket
     |> assign(
       page_title: "Import / Export",
       accounts: accounts,
       import_form: default_import_form(accounts),
       manual_account_form: default_manual_account_form(),
       import_batch: nil,
       import_rows: [],
       import_headers: [],
       export_days: Integer.to_string(@default_export_days)
     )
     |> allow_upload(:import_file,
       accept: ~w(.csv text/csv),
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
         {:ok, upload} <- consume_uploaded_csv(socket),
         {:ok, batch} <- create_import_batch(current_user, account_id, upload),
         mapping_config <- build_mapping_config(import_form, upload.content),
         {:ok, _mapped_batch} <-
           ManualImports.update_mapping(current_user, batch.id, mapping_config),
         {:ok, parsed} <- CSVParser.parse(upload.content, mapping_config),
         {:ok, %{batch: staged_batch}} <-
           ManualImports.stage_rows(current_user, batch.id, parsed.rows) do
      rows = ManualImports.list_rows(current_user, staged_batch.id)

      {:noreply,
       socket
       |> assign(
         import_batch: staged_batch,
         import_rows: rows,
         import_headers: parsed.headers
       )
       |> put_flash(
         :info,
         "Staged #{staged_batch.row_count} rows. Review and commit when ready."
       )}
    else
      {:error, :account_required} ->
        {:noreply, put_flash(socket, :error, "Select an account before importing.")}

      {:error, :no_file} ->
        {:noreply, put_flash(socket, :error, "Upload a CSV file before staging import rows.")}

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
        <article class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
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
                  CSV file
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
                <button class="btn" type="submit" disabled={@accounts == []}>Stage CSV import</button>

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
                </tr>
              </thead>
              <tbody>
                <%= for row <- Enum.take(@import_rows, 15) do %>
                  <tr class="border-b border-zinc-100">
                    <td class="py-2 pr-3 text-zinc-700"><%= row.row_index %></td>
                    <td class="py-2 pr-3 text-zinc-700"><%= format_datetime(row.posted_at) %></td>
                    <td class="py-2 pr-3 text-zinc-900"><%= row.description || "—" %></td>
                    <td class="py-2 pr-3 text-zinc-700"><%= decimal_to_string(row.amount) %></td>
                    <td class="py-2 pr-3 text-zinc-700"><%= row.parse_status %></td>
                    <td class="py-2 text-zinc-700"><%= row.review_decision %></td>
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

  defp consume_uploaded_csv(socket) do
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
    ManualImports.create_batch(current_user, %{
      "account_id" => account_id,
      "source_institution" => "generic_csv",
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

  defp default_import_form(accounts) do
    %{
      "account_id" => accounts |> List.first() |> then(&if(&1, do: &1.id, else: "")),
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

  defp build_mapping_config(import_form, content) do
    headers = parse_headers(content)
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

  defp parse_headers(content) do
    content
    |> String.split(~r/\r\n|\n|\r/)
    |> Enum.find("", fn line -> String.trim(line) != "" end)
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp guessed_mapping(headers) do
    normalized =
      headers
      |> Enum.map(fn header -> {String.downcase(header), header} end)
      |> Map.new()

    %{
      "posted_at" => find_header(normalized, ~w(date posted_at posted date transaction date)),
      "description" => find_header(normalized, ~w(description memo name)),
      "amount" => find_header(normalized, ~w(amount signed amount)),
      "debit" => find_header(normalized, ~w(debit withdrawal)),
      "credit" => find_header(normalized, ~w(credit deposit)),
      "status" => find_header(normalized, ~w(status))
    }
  end

  defp find_header(normalized_headers, candidates) do
    Enum.find_value(candidates, fn candidate -> Map.get(normalized_headers, candidate) end)
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

  defp sha256(content) do
    :sha256
    |> :crypto.hash(content)
    |> Base.encode16(case: :lower)
  end
end
