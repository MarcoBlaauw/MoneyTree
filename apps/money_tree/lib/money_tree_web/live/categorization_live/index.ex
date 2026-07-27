defmodule MoneyTreeWeb.CategorizationLive.Index do
  use MoneyTreeWeb, :live_view

  alias MoneyTree.AI
  alias MoneyTree.Categorization
  alias MoneyTree.Transactions

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: user}} = socket) do
    {:ok, load(socket, user)}
  end

  @impl true
  def handle_event(
        "recategorize",
        %{"transaction_id" => transaction_id, "category" => category},
        %{assigns: %{current_user: user}} = socket
      ) do
    case Categorization.recategorize_transaction(user, transaction_id, category) do
      {:ok, _} ->
        {:noreply, socket |> load(user) |> put_flash(:info, "Transaction recategorized")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Unable to recategorize transaction")}
    end
  end

  def handle_event("create-rule", %{"rule" => params}, %{assigns: %{current_user: user}} = socket) do
    params =
      params
      |> Map.update("description_keywords", [], &split_csv/1)
      |> Map.update("account_types", [], &split_csv/1)

    case Categorization.create_rule(user, params) do
      {:ok, _} -> {:noreply, socket |> load(user) |> put_flash(:info, "Rule created")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not create rule")}
    end
  end

  def handle_event("delete-rule", %{"id" => id}, %{assigns: %{current_user: user}} = socket) do
    _ = Categorization.delete_rule(user, id)
    {:noreply, load(socket, user)}
  end

  def handle_event("clear-rules", _params, %{assigns: %{current_user: user}} = socket) do
    count = Categorization.clear_rules(user)

    {:noreply,
     socket
     |> load(user)
     |> put_flash(:info, "Cleared #{count} user rules.")}
  end

  def handle_event(
        "create-category",
        %{"category" => params},
        %{assigns: %{current_user: user}} = socket
      ) do
    case Categorization.create_category(user, params) do
      {:ok, _category} ->
        {:noreply, socket |> load(user) |> put_flash(:info, "Category saved")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save category")}
    end
  end

  def handle_event("delete-category", %{"id" => id}, %{assigns: %{current_user: user}} = socket) do
    _ = Categorization.delete_category(user, id)
    {:noreply, load(socket, user)}
  end

  def handle_event(
        "run-ai",
        %{"transaction_id" => transaction_id},
        %{assigns: %{current_user: user}} = socket
      ) do
    case AI.create_categorization_run(user, %{"limit" => 1, "transaction_id" => transaction_id}) do
      {:ok, _run} ->
        {:noreply,
         socket |> load(user) |> put_flash(:info, "AI categorization queued for transaction")}

      {:error, :no_transactions} ->
        {:noreply, put_flash(socket, :info, "No uncategorized transactions found")}

      {:error, :disabled_for_user} ->
        {:noreply,
         put_flash(socket, :error, "Enable local AI in settings before running categorization")}

      {:error, :categorization_disabled} ->
        {:noreply, put_flash(socket, :error, "AI categorization is disabled in settings")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "AI categorization failed: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle-ai-status", _params, socket) do
    {:noreply, assign(socket, :ai_status_open?, !socket.assigns.ai_status_open?)}
  end

  def handle_event("accept-suggestion", %{"id" => id}, %{assigns: %{current_user: user}} = socket) do
    case AI.accept_suggestion(user, id) do
      {:ok, _suggestion} ->
        {:noreply, socket |> load(user) |> put_flash(:info, "Suggestion accepted")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Unable to accept suggestion")}
    end
  end

  def handle_event("reject-suggestion", %{"id" => id}, %{assigns: %{current_user: user}} = socket) do
    case AI.reject_suggestion(user, id) do
      {:ok, _suggestion} ->
        {:noreply, socket |> load(user) |> put_flash(:info, "Suggestion rejected")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Unable to reject suggestion")}
    end
  end

  def handle_event(
        "apply-suggestion",
        %{"suggestion_id" => id, "category" => category},
        %{assigns: %{current_user: user}} = socket
      ) do
    case AI.apply_edited_suggestion(user, id, %{"category" => category}) do
      {:ok, _suggestion} ->
        {:noreply, socket |> load(user) |> put_flash(:info, "Edited suggestion applied")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Unable to apply edited suggestion")}
    end
  end

  defp split_csv(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp load(socket, user) do
    txns =
      Transactions.paginate_for_user(user, page: 1, per_page: 20, uncategorized_only: true).entries

    ai_runs = AI.list_runs(user, feature: "categorization", limit: 25)
    ai_status_open? = Map.get(socket.assigns, :ai_status_open?, false)

    assign(socket,
      page_title: "Transactions",
      transactions: txns,
      rules: Categorization.list_rules(user),
      categories: Categorization.list_categories(user),
      category_names: Categorization.category_names(user),
      category_options: Categorization.category_options(user),
      ai_settings: AI.settings_snapshot(user),
      ai_runs: ai_runs,
      visible_ai_runs: Enum.take(ai_runs, 5),
      ai_run_summary: ai_run_summary(ai_runs),
      ai_status_open?: ai_status_open?,
      emoji_options: emoji_options(),
      pending_suggestions:
        AI.list_suggestions(user, status: "pending", target_type: "transaction")
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-6">
      <.header title="Categorization rules" subtitle="Manage transaction categorization rules under Transactions.">
        <:actions>
          <.link navigate={~p"/app/transactions"} class="btn btn-outline">Back to transactions</.link>
        </:actions>
      </.header>

      <div class="grid gap-6 xl:grid-cols-[minmax(0,1.2fr)_minmax(0,1fr)]">
        <div class="rounded-xl border border-zinc-200 bg-white p-4">
          <div class="flex items-center justify-between gap-3">
            <div>
              <h2 class="text-sm font-semibold text-zinc-800">AI suggestions</h2>
              <p class="text-xs text-zinc-500">
                Auto-applies at confidence 0.85 or higher. Lower confidence suggestions stay here for review.
              </p>
            </div>
            <span class="text-xs text-zinc-500"><%= @ai_settings.default_model || "No model selected" %></span>
          </div>

          <ul class="mt-3 space-y-2">
            <li :for={suggestion <- @pending_suggestions} class="rounded border border-zinc-100 p-3">
              <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                <div>
                  <p class="text-sm font-medium"><%= suggestion.payload["category"] %></p>
                  <p class="text-xs text-zinc-500">
                    confidence <%= suggestion.confidence || "n/a" %>
                    <%= if suggestion.payload["transaction_kind"] do %>
                      • <%= suggestion.payload["transaction_kind"] %>
                    <% end %>
                    <%= if suggestion.payload["recurring_candidate"] do %>
                      • recurring candidate
                    <% end %>
                  </p>
                  <p class="mt-1 text-xs text-zinc-600"><%= suggestion.reason || suggestion.payload["reason"] %></p>
                </div>
                <div class="flex flex-wrap gap-2">
                  <button class="btn btn-xs" type="button" phx-click="accept-suggestion" phx-value-id={suggestion.id}>Accept</button>
                  <button class="btn btn-outline btn-xs" type="button" phx-click="reject-suggestion" phx-value-id={suggestion.id}>Reject</button>
                </div>
              </div>
              <.form for={%{}} phx-submit="apply-suggestion" class="mt-3 flex items-center gap-2">
                <input type="hidden" name="suggestion_id" value={suggestion.id} />
                <input type="text" name="category" value={suggestion.payload["category"] || ""} class="input input-bordered input-sm" />
                <button type="submit" class="btn btn-outline btn-xs">Apply edited</button>
              </.form>
            </li>
            <li :if={Enum.empty?(@pending_suggestions)} class="rounded border border-dashed border-zinc-200 p-4 text-sm text-zinc-500">
              No pending AI suggestions.
            </li>
          </ul>
        </div>

        <div class="rounded-xl border border-zinc-200 bg-white p-4">
          <div class="flex items-center justify-between gap-3">
            <h2 class="text-sm font-semibold text-zinc-800">AI run status</h2>
            <button type="button"
                    class="btn btn-outline btn-xs"
                    phx-click="toggle-ai-status">
              <%= if @ai_status_open?, do: "Hide details", else: "Show details" %>
            </button>
          </div>
          <dl class="mt-3 grid grid-cols-2 gap-2 text-sm">
            <div class="rounded border border-zinc-100 bg-zinc-50 p-2">
              <dt class="text-xs uppercase tracking-wide text-zinc-500">Completed batches</dt>
              <dd class="mt-1 font-semibold text-zinc-900">
                <%= @ai_run_summary.completed %> / <%= @ai_run_summary.total %>
              </dd>
            </div>
            <div class="rounded border border-zinc-100 bg-zinc-50 p-2">
              <dt class="text-xs uppercase tracking-wide text-zinc-500">Failed batches</dt>
              <dd class="mt-1 font-semibold text-zinc-900"><%= @ai_run_summary.failed %></dd>
            </div>
            <div class="rounded border border-zinc-100 bg-zinc-50 p-2">
              <dt class="text-xs uppercase tracking-wide text-zinc-500">Active batches</dt>
              <dd class="mt-1 font-semibold text-zinc-900"><%= @ai_run_summary.active %></dd>
            </div>
            <div class="rounded border border-zinc-100 bg-zinc-50 p-2">
              <dt class="text-xs uppercase tracking-wide text-zinc-500">Transactions attempted</dt>
              <dd class="mt-1 font-semibold text-zinc-900"><%= @ai_run_summary.transactions %></dd>
            </div>
          </dl>
          <div :if={@ai_status_open?}>
            <p :if={length(@ai_runs) > 5} class="mt-3 text-xs text-zinc-500">
              Showing latest 5 of <%= length(@ai_runs) %> batches.
            </p>
            <ul class="mt-3 space-y-2">
              <li :for={run <- @visible_ai_runs} class="rounded border border-zinc-100 p-3">
                <div class="flex items-start justify-between gap-3">
                  <div>
                    <p class="text-sm font-medium">
                      <%= run_status_label(run.status) %>
                      <span class="text-xs font-normal text-zinc-500">
                        <%= run.input_scope["transaction_count"] || 0 %> transactions
                      </span>
                    </p>
                    <p class="mt-1 text-xs text-zinc-500">
                      <%= format_datetime(run.inserted_at) %>
                      <%= if run.model do %>
                        • <%= run.model %>
                      <% end %>
                    </p>
                    <p :if={run.error_code} class="mt-1 text-xs text-rose-700">
                      <%= run.error_code %><%= if run.error_message_safe && run.error_message_safe != run.error_code, do: ": #{run.error_message_safe}" %>
                    </p>
                  </div>
                  <span class={run_status_badge_class(run.status)}><%= run.status %></span>
                </div>
                <p class="mt-2 text-xs text-zinc-500">
                  Started <%= format_datetime(run.started_at) %> • Completed <%= format_datetime(run.completed_at) %>
                  <%= if run.duration_ms do %>
                    • <%= run.duration_ms %> ms
                  <% end %>
                </p>
              </li>
              <li :if={Enum.empty?(@ai_runs)} class="rounded border border-dashed border-zinc-200 p-4 text-sm text-zinc-500">
                No AI categorization runs yet.
              </li>
            </ul>
          </div>
        </div>

        <div class="rounded-xl border border-zinc-200 bg-white p-4">
          <h2 class="text-sm font-semibold text-zinc-800">Categories</h2>
          <.form for={%{}} as={:category} phx-submit="create-category" class="mt-3 grid gap-2 md:grid-cols-[auto_1fr_auto]">
            <select name="category[emoji]" class="input input-bordered input-sm" aria-label="Category emoji">
              <option :for={option <- @emoji_options} value={option.emoji}>
                <%= option.emoji %> <%= option.label %>
              </option>
            </select>
            <input name="category[name]" placeholder="Category name" class="input input-bordered input-sm" required />
            <select name="category[kind]" class="input input-bordered input-sm">
              <option value="expense">Expense</option>
              <option value="income">Income</option>
              <option value="transfer">Transfer</option>
              <option value="other">Other</option>
            </select>
            <button type="submit" class="btn btn-sm md:col-span-3">Save category</button>
          </.form>

          <ul class="mt-4 space-y-2">
            <li :for={category <- @categories} class="flex items-center justify-between rounded border border-zinc-100 p-2">
              <p class="text-sm"><span class="mr-1"><%= category.emoji %></span><%= category.name %> <span class="text-xs text-zinc-500"><%= category.kind %></span></p>
              <button phx-click="delete-category" phx-value-id={category.id} class="btn btn-outline btn-xs">Hide</button>
            </li>
            <li :if={Enum.empty?(@categories)} class="rounded border border-dashed border-zinc-200 p-3 text-sm text-zinc-500">
              No managed categories yet.
            </li>
          </ul>
        </div>
      </div>

      <div class="rounded-xl border border-zinc-200 bg-white p-4">
        <h2 class="text-sm font-semibold text-zinc-800">Uncategorized transactions</h2>
        <ul class="mt-3 space-y-2">
          <li :for={transaction <- @transactions} class="flex flex-col gap-3 rounded border border-zinc-100 p-2 md:flex-row md:items-center md:justify-between">
            <div class="min-w-0">
              <p class="text-sm font-medium"><%= transaction.description %></p>
              <p class="text-xs text-zinc-500"><%= transaction.account.name %> • <%= transaction.currency %></p>
            </div>
            <div class="flex w-full flex-col gap-2 sm:w-auto sm:flex-row sm:items-center sm:justify-end">
              <button :if={uncategorized?(transaction)}
                      type="button"
                      class="btn btn-outline btn-sm sm:order-none"
                      phx-click="run-ai"
                      phx-value-transaction_id={transaction.id}>
                AI
              </button>
              <.form for={%{}}
                     phx-submit="recategorize"
                     class="flex w-full items-center justify-end gap-2 sm:w-auto">
                <input type="hidden" name="transaction_id" value={transaction.id} />
                <select name="category" class="input input-bordered input-sm min-w-48 sm:w-56">
                  <option value="Uncategorized">🏷️ Uncategorized</option>
                  <option :for={category <- @category_options}
                          value={category.name}
                          selected={category.name == Map.get(transaction, :category)}>
                    <%= category.emoji %> <%= category.name %>
                  </option>
                </select>
                <button type="submit" class="btn btn-sm">Save</button>
              </.form>
            </div>
          </li>
        </ul>
      </div>

      <div class="rounded-xl border border-zinc-200 bg-white p-4">
        <div class="flex items-center justify-between gap-3">
          <h2 class="text-sm font-semibold text-zinc-800">Rules</h2>
          <button type="button"
                  class="btn btn-outline btn-xs"
                  phx-click="clear-rules"
                  data-confirm="Clear all user-created categorization rules? Manual overrides and system rules are kept.">
            Clear all rules
          </button>
        </div>
        <.form for={%{}} as={:rule} phx-submit="create-rule" class="mt-3 grid gap-2 md:grid-cols-3">
          <select name="rule[category]" class="input input-bordered input-sm" required>
            <option value="">Category</option>
            <option :for={category <- @category_options} value={category.name}>
              <%= category.emoji %> <%= category.name %>
            </option>
          </select>
          <input name="rule[merchant_regex]" placeholder="Merchant regex" class="input input-bordered input-sm" />
          <input name="rule[description_keywords]" placeholder="Keywords csv" class="input input-bordered input-sm" />
          <input name="rule[account_types]" placeholder="Account types csv" class="input input-bordered input-sm" />
          <input name="rule[min_amount]" placeholder="Min amount" class="input input-bordered input-sm" />
          <input name="rule[max_amount]" placeholder="Max amount" class="input input-bordered input-sm" />
          <input name="rule[priority]" value="100" class="input input-bordered input-sm" />
          <button type="submit" class="btn btn-sm md:col-span-3">Create rule</button>
        </.form>

        <ul class="mt-4 space-y-2">
          <li :for={rule <- @rules} class="flex items-center justify-between rounded border border-zinc-100 p-2">
            <p class="text-sm"><%= rule.category %> <span class="text-xs text-zinc-500">prio <%= rule.priority %></span></p>
            <button phx-click="delete-rule" phx-value-id={rule.id} class="btn btn-outline btn-xs">Delete</button>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  defp run_status_label("queued"), do: "Queued"
  defp run_status_label("running"), do: "Running"
  defp run_status_label("completed"), do: "Completed"
  defp run_status_label("failed"), do: "Failed"
  defp run_status_label("cancelled"), do: "Cancelled"
  defp run_status_label("completed_with_warnings"), do: "Completed with warnings"
  defp run_status_label(status), do: status

  defp run_status_badge_class(status) when status in ["queued", "running"] do
    "rounded-full bg-sky-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-sky-700"
  end

  defp run_status_badge_class("completed") do
    "rounded-full bg-emerald-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-emerald-700"
  end

  defp run_status_badge_class("failed") do
    "rounded-full bg-rose-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-rose-700"
  end

  defp run_status_badge_class(_status) do
    "rounded-full bg-zinc-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-zinc-700"
  end

  defp format_datetime(nil), do: "--"

  defp format_datetime(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp uncategorized?(transaction) do
    category = Map.get(transaction, :category)
    is_nil(category) or category == "" or category == "Uncategorized"
  end

  defp ai_run_summary(runs) do
    Enum.reduce(
      runs,
      %{total: 0, completed: 0, failed: 0, active: 0, transactions: 0},
      fn run, acc ->
        transaction_count = run.input_scope["transaction_count"] || 0

        acc =
          acc
          |> Map.update!(:total, &(&1 + 1))
          |> Map.update!(:transactions, &(&1 + transaction_count))

        case run.status do
          "completed" -> Map.update!(acc, :completed, &(&1 + 1))
          "completed_with_warnings" -> Map.update!(acc, :completed, &(&1 + 1))
          "failed" -> Map.update!(acc, :failed, &(&1 + 1))
          status when status in ["queued", "running"] -> Map.update!(acc, :active, &(&1 + 1))
          _status -> acc
        end
      end
    )
  end

  defp emoji_options do
    [
      %{emoji: "🏷️", label: "General"},
      %{emoji: "🛒", label: "Groceries"},
      %{emoji: "🍽️", label: "Dining"},
      %{emoji: "☕", label: "Coffee"},
      %{emoji: "⛽", label: "Fuel"},
      %{emoji: "💡", label: "Utilities"},
      %{emoji: "🏠", label: "Home"},
      %{emoji: "🏥", label: "Medical"},
      %{emoji: "💊", label: "Pharmacy"},
      %{emoji: "🛡️", label: "Insurance"},
      %{emoji: "🚗", label: "Auto"},
      %{emoji: "✈️", label: "Travel"},
      %{emoji: "🎬", label: "Entertainment"},
      %{emoji: "🔄", label: "Subscription"},
      %{emoji: "💳", label: "Card payment"},
      %{emoji: "🏦", label: "Loan"},
      %{emoji: "🔁", label: "Transfer"},
      %{emoji: "💵", label: "Income"},
      %{emoji: "🧾", label: "Fees"},
      %{emoji: "🎁", label: "Gifts"}
    ]
  end
end
