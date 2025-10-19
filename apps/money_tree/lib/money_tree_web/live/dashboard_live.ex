defmodule MoneyTreeWeb.DashboardLive do
  @moduledoc """
  Account overview LiveView with masked balance toggling and inactivity locking.
  """

  use MoneyTreeWeb, :live_view

  alias MoneyTree.Accounts
  alias MoneyTree.Transactions

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: current_user}} = socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Dashboard",
       show_balances?: false,
       locked?: false
     )
     |> load_dashboard(current_user)}
  end

  @impl true
  def handle_event("toggle-balances", _params, %{assigns: %{locked?: true}} = socket) do
    {:noreply, put_flash(socket, :error, "Unlock the dashboard to reveal balances.")}
  end

  def handle_event("toggle-balances", _params, socket) do
    {:noreply, update(socket, :show_balances?, &(!&1))}
  end

  def handle_event("lock-interface", _params, socket) do
    {:noreply,
     socket
     |> assign(locked?: true, show_balances?: false)
     |> put_flash(:info, "Dashboard locked due to inactivity.")}
  end

  def handle_event("unlock-interface", _params, %{assigns: %{current_user: current_user}} = socket) do
    {:noreply,
     socket
     |> assign(locked?: false)
     |> load_dashboard(current_user)
     |> put_flash(:info, "Dashboard unlocked.")}
  end

  def handle_event("refresh-transactions", _params, %{assigns: %{current_user: current_user}} = socket) do
    {:noreply, assign_transactions(socket, current_user)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-6">
      <.header title="Dashboard" subtitle="Monitor balances and recent activity." />

      <div class="flex flex-wrap items-center gap-2">
        <button id="toggle-balances"
                phx-click="toggle-balances"
                type="button"
                class="btn btn-secondary">
          <%= if @show_balances?, do: "Hide balances", else: "Show balances" %>
        </button>

        <button id="lock-dashboard"
                phx-click="lock-interface"
                type="button"
                class="btn btn-outline">
          Lock
        </button>

        <button :if={@locked?}
                id="unlock-dashboard"
                phx-click="unlock-interface"
                type="button"
                class="btn">
          Unlock
        </button>

        <button phx-click="refresh-transactions"
                type="button"
                class="btn btn-outline">
          Refresh activity
        </button>
      </div>

      <div class="grid gap-4 lg:grid-cols-2">
        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
          <h2 class="text-lg font-semibold text-zinc-900">Accounts</h2>
          <p class="text-sm text-zinc-500">
            Balances are masked until you choose to reveal them.
          </p>

          <ul class="space-y-3">
            <li :for={summary <- @summary.accounts}
                class="flex flex-col gap-1 rounded-lg border border-zinc-100 bg-zinc-50 p-3">
              <div class="flex items-center justify-between">
                <span class="font-medium text-zinc-900"><%= summary.account.name %></span>
                <span class="text-xs uppercase text-zinc-500"><%= summary.account.type %></span>
              </div>

              <div class="flex items-center justify-between text-sm">
                <span class="text-zinc-600">Current balance</span>
                <span class="font-semibold text-zinc-800">
                  <%= if @show_balances?, do: summary.current_balance, else: summary.current_balance_masked %>
                </span>
              </div>

              <div class="flex items-center justify-between text-sm">
                <span class="text-zinc-600">Available</span>
                <span class="text-zinc-700">
                  <%= if @show_balances?, do: summary.available_balance, else: summary.available_balance_masked %>
                </span>
              </div>
            </li>
          </ul>

          <div class="mt-4 space-y-2 rounded-lg border border-zinc-100 bg-zinc-50 p-3">
            <h3 class="text-sm font-semibold text-zinc-700">Totals</h3>
            <dl class="space-y-2">
              <div :for={total <- @summary.totals} class="flex items-center justify-between text-sm">
                <dt class="text-zinc-600"><%= total.currency %> • <%= total.account_count %> accounts</dt>
                <dd class="font-semibold text-zinc-800">
                  <%= if @show_balances?, do: total.current_balance, else: total.current_balance_masked %>
                </dd>
              </div>
            </dl>
          </div>
        </div>

        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
          <div class="flex items-center justify-between">
            <h2 class="text-lg font-semibold text-zinc-900">Recent activity</h2>
            <span class="text-xs text-zinc-500">
              Page <%= @transactions.metadata.page %> of <%= @transactions.metadata.total_pages %>
            </span>
          </div>

          <ul class="divide-y divide-zinc-100 rounded-lg border border-zinc-100">
            <li :for={transaction <- @transactions.entries} class="flex items-center justify-between gap-4 p-3">
              <div>
                <p class="text-sm font-medium text-zinc-900"><%= transaction.description %></p>
                <p class="text-xs text-zinc-500">
                  <%= transaction.account.name %> • <%= format_timestamp(transaction.posted_at) %>
                </p>
              </div>
              <div class="text-right text-sm font-semibold text-zinc-800">
                <%= if @show_balances?, do: transaction.amount, else: transaction.amount_masked %>
              </div>
            </li>
            <li :if={Enum.empty?(@transactions.entries)} class="p-4 text-center text-sm text-zinc-500">
              No transactions recorded yet.
            </li>
          </ul>
        </div>
      </div>
    </section>
    """
  end

  defp load_dashboard(socket, current_user) do
    socket
    |> assign(:summary, Accounts.dashboard_summary(current_user))
    |> assign_transactions(current_user)
  end

  defp assign_transactions(socket, current_user) do
    assign(socket, :transactions, Transactions.paginate_for_user(current_user))
  end

  defp format_timestamp(nil), do: "Pending"

  defp format_timestamp(%DateTime{} = datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%b %d, %Y %H:%M UTC")
  rescue
    _ -> DateTime.to_string(datetime)
  end
end
