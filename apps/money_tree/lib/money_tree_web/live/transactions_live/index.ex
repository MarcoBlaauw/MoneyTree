defmodule MoneyTreeWeb.TransactionsLive.Index do
  @moduledoc """
  LiveView for browsing recent transactions and making lightweight category corrections.
  """

  use MoneyTreeWeb, :live_view

  alias MoneyTree.Categorization
  alias MoneyTree.Transactions

  @per_page 20

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: current_user}} = socket) do
    {:ok,
     socket
     |> assign(page_title: "Transactions", page: 1)
     |> load_page(current_user)}
  end

  @impl true
  def handle_event(
        "change-page",
        %{"page" => page},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    page =
      case Integer.parse(page) do
        {value, _} when value > 0 -> value
        _ -> 1
      end

    {:noreply,
     socket
     |> assign(page: page)
     |> load_page(current_user)}
  end

  def handle_event(
        "recategorize",
        %{"transaction_id" => transaction_id, "category" => category},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    case Categorization.recategorize_transaction(current_user, transaction_id, category) do
      {:ok, _transaction} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> put_flash(:info, "Transaction recategorized.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Unable to recategorize transaction.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-6">
      <.header title="Transactions" subtitle="Review account activity, inspect categories, and correct entries as needed.">
        <:actions>
          <.link navigate={~p"/app/transactions/categorization"} class="btn btn-outline">
            Open rules
          </.link>
        </:actions>
      </.header>

      <div class="grid gap-4 lg:grid-cols-3">
        <div class="rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Visible entries</p>
          <p class="mt-1 text-2xl font-semibold text-zinc-900"><%= length(@transactions.entries) %></p>
          <p class="text-xs text-zinc-500">Transactions on the current page</p>
        </div>

        <div class="rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Current page</p>
          <p class="mt-1 text-2xl font-semibold text-zinc-900"><%= @transactions.metadata.page %></p>
          <p class="text-xs text-zinc-500">Viewing <%= @transactions.metadata.per_page %> items per page</p>
        </div>

        <div class="rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Total transactions</p>
          <p class="mt-1 text-2xl font-semibold text-zinc-900"><%= @transactions.metadata.total_entries %></p>
          <p class="text-xs text-zinc-500">Across all accessible accounts</p>
        </div>
      </div>

      <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
        <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <h2 class="text-lg font-semibold text-zinc-900">Recent transactions</h2>
            <p class="text-sm text-zinc-500">Inline recategorization is available for quick cleanup.</p>
          </div>

          <div class="flex items-center gap-2">
            <button type="button"
                    class="btn btn-outline"
                    phx-click="change-page"
                    phx-value-page={max(@transactions.metadata.page - 1, 1)}
                    disabled={!@transactions.metadata.has_prev?}>
              Previous
            </button>
            <button type="button"
                    class="btn btn-outline"
                    phx-click="change-page"
                    phx-value-page={@transactions.metadata.page + 1}
                    disabled={!@transactions.metadata.has_next?}>
              Next
            </button>
          </div>
        </div>

        <ul class="space-y-3">
          <li :for={transaction <- @transactions.entries} class="space-y-3 rounded-xl border border-zinc-100 bg-zinc-50 p-4">
            <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <p class="font-semibold text-zinc-900"><%= transaction.description %></p>
                  <span class={status_badge_class(transaction.status)}><%= transaction.status %></span>
                </div>
                <p class="mt-1 text-xs text-zinc-500">
                  <%= transaction.account.name %>
                  • <%= transaction.account.type %>
                  • <%= format_datetime(transaction.posted_at) %>
                </p>
              </div>

              <div class="text-right">
                <p class="font-semibold text-zinc-900"><%= transaction.amount %></p>
                <p class="text-xs text-zinc-500"><%= transaction.currency %></p>
              </div>
            </div>

            <div class="grid gap-3 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-end">
              <.form for={%{}} phx-submit="recategorize" class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_auto]">
                <input type="hidden" name="transaction_id" value={transaction.id} />
                <div>
                  <label class="text-sm font-medium text-zinc-700" for={"category-#{transaction.id}"}>Category</label>
                  <input id={"category-#{transaction.id}"}
                         type="text"
                         name="category"
                         value={transaction.category || ""}
                         class="input"
                         placeholder="Uncategorized" />
                </div>
                <button type="submit" class="btn">Save</button>
              </.form>

              <div class="rounded-lg bg-white px-3 py-2 text-sm text-zinc-600">
                Status: <span class="font-medium text-zinc-800"><%= transaction.status %></span>
              </div>
            </div>
          </li>

          <li :if={Enum.empty?(@transactions.entries)} class="rounded-xl border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
            No transactions recorded yet.
          </li>
        </ul>
      </div>
    </section>
    """
  end

  defp load_page(socket, current_user) do
    transactions =
      Transactions.paginate_for_user(current_user, page: socket.assigns.page, per_page: @per_page)

    assign(socket, transactions: transactions)
  end

  defp status_badge_class("pending"),
    do:
      "rounded-full bg-amber-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-amber-700"

  defp status_badge_class("posted"),
    do:
      "rounded-full bg-emerald-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-emerald-700"

  defp status_badge_class(_status),
    do:
      "rounded-full bg-zinc-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-zinc-600"

  defp format_datetime(nil), do: "Pending date"

  defp format_datetime(%DateTime{} = value) do
    Calendar.strftime(value, "%b %-d, %Y")
  end

  defp format_datetime(_value), do: "Unknown"
end
