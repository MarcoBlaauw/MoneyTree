defmodule MoneyTreeWeb.DashboardLive do
  @moduledoc """
  Account overview LiveView with masked balance toggling and inactivity locking.
  """

  use MoneyTreeWeb, :live_view

  alias Decimal
  alias MoneyTree.Accounts
  alias MoneyTree.Budgets
  alias MoneyTree.Loans
  alias MoneyTree.Notifications
  alias MoneyTree.Subscriptions
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

  def handle_event(
        "unlock-interface",
        _params,
        %{assigns: %{current_user: current_user}} = socket
      ) do
    {:noreply,
     socket
     |> assign(locked?: false)
     |> load_dashboard(current_user)
     |> put_flash(:info, "Dashboard unlocked.")}
  end

  def handle_event(
        "refresh-transactions",
        _params,
        %{assigns: %{current_user: current_user}} = socket
      ) do
    {:noreply, assign_metrics(socket, current_user)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-8">
      <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <.header title="Dashboard" subtitle="Monitor balances and recent activity." />

        <.link navigate={~p"/app/react"} class="btn btn-outline shrink-0">
          Next.js demos
        </.link>
      </div>

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

      <div class="grid gap-6 xl:grid-cols-3">
        <div class="space-y-6 xl:col-span-2">
          <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
            <div class="flex items-center justify-between">
              <h2 class="text-lg font-semibold text-zinc-900">Accounts</h2>
              <span class="text-xs text-zinc-500">Balances mask until revealed</span>
            </div>

            <ul class="space-y-3">
              <li :for={summary <- @summary.accounts}
                  class="flex flex-col gap-2 rounded-lg border border-zinc-100 bg-zinc-50 p-3">
                <div class="flex items-center justify-between">
                  <span class="font-medium text-zinc-900"><%= summary.account.name %></span>
                  <span class="text-xs uppercase text-zinc-500"><%= summary.account.type %></span>
                </div>

                <div class="flex items-center justify-between text-sm">
                  <span class="text-zinc-600">Current balance</span>
                  <span class="font-semibold text-zinc-800">
                    <%= visible_value(@show_balances?, summary.current_balance, summary.current_balance_masked) %>
                  </span>
                </div>

                <div class="flex items-center justify-between text-sm">
                  <span class="text-zinc-600">Available</span>
                  <span class="text-zinc-700">
                    <%= visible_value(@show_balances?, summary.available_balance, summary.available_balance_masked) %>
                  </span>
                </div>
              </li>

              <li :if={Enum.empty?(@summary.accounts)}
                  class="rounded-lg border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
                Connect an institution to start tracking balances.
              </li>
            </ul>

            <div class="grid gap-2 rounded-lg border border-zinc-100 bg-zinc-50 p-3 sm:grid-cols-2">
              <div :for={total <- @summary.totals} class="flex items-center justify-between text-sm">
                <dt class="text-zinc-600"><%= total.currency %> • <%= total.account_count %> accounts</dt>
                <dd class="font-semibold text-zinc-800">
                  <%= visible_value(@show_balances?, total.current_balance, total.current_balance_masked) %>
                </dd>
              </div>
            </div>
          </div>

          <div class="grid gap-6 lg:grid-cols-2">
            <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
              <h3 class="text-lg font-semibold text-zinc-900">Household net worth</h3>

              <dl class="space-y-3 text-sm">
                <div class="flex items-center justify-between">
                  <dt class="text-zinc-600">Net worth</dt>
                  <dd class="text-base font-semibold text-zinc-900">
                    <%= visible_value(@show_balances?, @metrics.net_worth.net_worth, @metrics.net_worth.net_worth_masked) %>
                  </dd>
                </div>

                <div class="flex items-center justify-between">
                  <dt class="text-zinc-600">Assets</dt>
                  <dd class="text-zinc-700">
                    <%= visible_value(@show_balances?, @metrics.net_worth.assets, @metrics.net_worth.assets_masked) %>
                  </dd>
                </div>

                <div class="flex items-center justify-between">
                  <dt class="text-zinc-600">Liabilities</dt>
                  <dd class="text-zinc-700">
                    <%= visible_value(@show_balances?, @metrics.net_worth.liabilities, @metrics.net_worth.liabilities_masked) %>
                  </dd>
                </div>
              </dl>

              <div class="space-y-2">
                <h4 class="text-xs font-semibold uppercase tracking-wide text-zinc-500">Breakdown</h4>
                <ul class="space-y-2 text-sm">
                  <li :for={item <- @metrics.net_worth.breakdown.assets}
                      class="flex items-center justify-between">
                    <span class="text-zinc-600"><%= item.label %></span>
                    <span class="font-medium text-emerald-700">
                      <%= visible_value(@show_balances?, item.total, item.total_masked) %>
                    </span>
                  </li>
                  <li :for={item <- @metrics.net_worth.breakdown.liabilities}
                      class="flex items-center justify-between">
                    <span class="text-zinc-600"><%= item.label %></span>
                    <span class="font-medium text-rose-600">
                      <%= visible_value(@show_balances?, item.total, item.total_masked) %>
                    </span>
                  </li>
                </ul>
              </div>
            </div>

            <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
              <h3 class="text-lg font-semibold text-zinc-900">Savings &amp; investments</h3>

              <dl class="space-y-3 text-sm">
                <div class="flex items-center justify-between">
                  <dt class="text-zinc-600">Total saved</dt>
                  <dd class="font-medium text-zinc-900">
                    <%= visible_value(@show_balances?, @metrics.savings.savings_total, @metrics.savings.savings_total_masked) %>
                  </dd>
                </div>

                <div class="flex items-center justify-between">
                  <dt class="text-zinc-600">Invested</dt>
                  <dd class="font-medium text-zinc-900">
                    <%= visible_value(@show_balances?, @metrics.savings.investment_total, @metrics.savings.investment_total_masked) %>
                  </dd>
                </div>

                <div class="flex items-center justify-between">
                  <dt class="text-zinc-600">Combined</dt>
                  <dd class="font-semibold text-emerald-700">
                    <%= visible_value(@show_balances?, @metrics.savings.combined_total, @metrics.savings.combined_total_masked) %>
                  </dd>
                </div>
              </dl>

              <div class="grid gap-3 text-sm md:grid-cols-2">
                <div>
                  <h4 class="text-xs font-semibold uppercase tracking-wide text-zinc-500">Savings</h4>
                  <ul class="space-y-1">
                    <li :for={account <- @metrics.savings.savings_accounts}
                        class="flex items-center justify-between">
                      <span class="text-zinc-600"><%= account.name %></span>
                      <span class="text-zinc-700">
                        <%= visible_value(@show_balances?, account.balance, account.balance_masked) %>
                      </span>
                    </li>
                    <li :if={Enum.empty?(@metrics.savings.savings_accounts)} class="text-xs text-zinc-500">No savings accounts.</li>
                  </ul>
                </div>

                <div>
                  <h4 class="text-xs font-semibold uppercase tracking-wide text-zinc-500">Investments</h4>
                  <ul class="space-y-1">
                    <li :for={account <- @metrics.savings.investment_accounts}
                        class="flex items-center justify-between">
                      <span class="text-zinc-600"><%= account.name %></span>
                      <span class="text-zinc-700">
                        <%= visible_value(@show_balances?, account.balance, account.balance_masked) %>
                      </span>
                    </li>
                    <li :if={Enum.empty?(@metrics.savings.investment_accounts)} class="text-xs text-zinc-500">No investment accounts.</li>
                  </ul>
                </div>
              </div>
            </div>
          </div>

          <div class="grid gap-6 lg:grid-cols-2">
            <div class="space-y-3 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
              <div class="flex items-center justify-between">
                <h3 class="text-lg font-semibold text-zinc-900">Active cards</h3>
                <span class="text-xs text-zinc-500">Last 30 days</span>
              </div>

              <ul class="space-y-3 text-sm">
                <li :for={balance <- @metrics.card_balances}
                    class="rounded-lg border border-zinc-100 bg-zinc-50 p-3">
                  <div class="flex items-center justify-between">
                    <span class="font-medium text-zinc-900"><%= balance.account.name %></span>
                    <span class="text-xs uppercase text-zinc-500">Utilization <%= format_percent(balance.utilization_percent) %></span>
                  </div>

                  <div class="mt-2 flex items-center justify-between">
                    <span class="text-zinc-600">Current</span>
                    <span class="font-medium text-zinc-800">
                      <%= visible_value(@show_balances?, balance.current_balance, balance.current_balance_masked) %>
                    </span>
                  </div>

                  <div class="flex items-center justify-between">
                    <span class="text-zinc-600">Available</span>
                    <span class="text-zinc-700">
                      <%= visible_value(@show_balances?, balance.available_credit, balance.available_credit_masked) %>
                    </span>
                  </div>

                  <div class="flex items-center justify-between text-xs text-zinc-500">
                    <span>Recent activity</span>
                    <span class={["font-medium", trend_color(balance.trend_direction)]}>
                      <%= visible_value(@show_balances?, balance.trend_amount, balance.trend_amount_masked) %>
                    </span>
                  </div>
                </li>

                <li :if={Enum.empty?(@metrics.card_balances)} class="text-xs text-zinc-500">No active cards detected.</li>
              </ul>
            </div>

            <div class="space-y-3 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
              <div class="flex items-center justify-between">
                <h3 class="text-lg font-semibold text-zinc-900">Loans &amp; autopay</h3>
                <span class="text-xs text-zinc-500">Autopay overview</span>
              </div>

              <ul class="space-y-3 text-sm">
                <li :for={loan <- @metrics.loans}
                    class="rounded-lg border border-zinc-100 bg-zinc-50 p-3">
                  <div class="flex items-center justify-between">
                    <span class="font-medium text-zinc-900"><%= loan.account.name %></span>
                    <span class="text-xs text-zinc-500">Due <%= format_date(loan.next_due_date) %></span>
                  </div>

                  <div class="mt-2 flex items-center justify-between">
                    <span class="text-zinc-600">Balance</span>
                    <span class="font-medium text-zinc-800">
                      <%= visible_value(@show_balances?, loan.current_balance, loan.current_balance_masked) %>
                    </span>
                  </div>

                  <div class="flex items-center justify-between text-xs text-zinc-500">
                    <span>Last payment</span>
                    <span class="text-zinc-600">
                      <%= visible_value(@show_balances?, loan.last_payment, loan.last_payment_masked) %>
                    </span>
                  </div>

                  <div class="mt-2 flex items-start justify-between rounded border border-zinc-200 bg-white p-2 text-xs">
                    <div>
                      <p class="font-medium text-zinc-700">Autopay</p>
                      <p class="text-zinc-500">Next run <%= format_date(loan.autopay.next_run_on) %></p>
                    </div>
                    <div class="text-right">
                      <p class={["font-medium", if(loan.autopay.enabled?, do: "text-emerald-600", else: "text-rose-600")]}> 
                        <%= if loan.autopay.enabled?, do: "Enabled", else: "Disabled" %>
                      </p>
                      <p>
                        <%= visible_value(@show_balances?, loan.autopay.payment_amount, loan.autopay.payment_amount_masked) %>
                      </p>
                    </div>
                  </div>
                </li>

                <li :if={Enum.empty?(@metrics.loans)} class="text-xs text-zinc-500">No loans linked yet.</li>
              </ul>
            </div>
          </div>
        </div>

        <div class="space-y-6">
          <div class="space-y-3 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
            <div class="flex items-center justify-between">
              <h3 class="text-lg font-semibold text-zinc-900">Notifications</h3>
              <span class="text-xs text-zinc-500">Automated insights</span>
            </div>

            <ul class="space-y-2 text-sm">
              <li :for={notification <- @metrics.notifications}
                  class="rounded-lg border border-zinc-100 bg-zinc-50 p-3">
                <p class="font-medium text-zinc-900"><%= notification.message %></p>
                <p class="text-xs text-zinc-500 uppercase"><%= Atom.to_string(notification.severity) %></p>
                <p :if={notification.action} class="text-xs text-emerald-600"><%= notification.action %></p>
              </li>
            </ul>
          </div>

          <div class="space-y-3 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
            <div class="flex items-center justify-between">
              <h3 class="text-lg font-semibold text-zinc-900">Budget pulse</h3>
              <span class="text-xs text-zinc-500">Current period</span>
            </div>

            <ul class="space-y-2 text-sm">
              <li :for={budget <- @metrics.budgets}
                  class="rounded-lg border border-zinc-100 bg-zinc-50 p-3">
                <div class="flex items-center justify-between">
                  <span class="font-medium text-zinc-900"><%= budget.name %></span>
                  <span class={budget_badge_class(budget.status)}><%= budget_status_label(budget.status) %></span>
                </div>

                <div class="mt-2 flex items-center justify-between">
                  <span class="text-zinc-600">Spent</span>
                  <span class="text-zinc-700">
                    <%= visible_value(@show_balances?, budget.spent, budget.spent_masked) %>
                  </span>
                </div>

                <div class="flex items-center justify-between text-xs text-zinc-500">
                  <span>Allocated</span>
                  <span>
                    <%= visible_value(@show_balances?, budget.allocated, budget.allocated_masked) %>
                  </span>
                </div>

                <div class="flex items-center justify-between text-xs text-emerald-600">
                  <span>Remaining</span>
                  <span>
                    <%= visible_value(@show_balances?, budget.remaining, budget.remaining_masked) %>
                  </span>
                </div>
              </li>
            </ul>
          </div>

          <div class="space-y-3 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
            <div class="flex items-center justify-between">
              <h3 class="text-lg font-semibold text-zinc-900">Subscriptions</h3>
              <span class="text-xs text-zinc-500">30-day lookback</span>
            </div>

            <dl class="space-y-2 text-sm">
              <div class="flex items-center justify-between">
                <dt class="text-zinc-600">Monthly total</dt>
                <dd class="font-medium text-zinc-900">
                  <%= visible_value(@show_balances?, @metrics.subscription.monthly_total, @metrics.subscription.monthly_total_masked) %>
                </dd>
              </div>
              <div class="flex items-center justify-between">
                <dt class="text-zinc-600">Annual projection</dt>
                <dd class="text-zinc-700">
                  <%= visible_value(@show_balances?, @metrics.subscription.annual_projection, @metrics.subscription.annual_projection_masked) %>
                </dd>
              </div>
            </dl>

            <div>
              <h4 class="text-xs font-semibold uppercase tracking-wide text-zinc-500">Top merchants</h4>
              <ul class="space-y-1 text-sm">
                <li :for={merchant <- @metrics.subscription.top_merchants}
                    class="flex items-center justify-between">
                  <span class="text-zinc-600"><%= merchant.merchant %></span>
                  <span class="text-zinc-700">
                    <%= visible_value(@show_balances?, merchant.spend, merchant.spend_masked) %>
                  </span>
                </li>
                <li :if={Enum.empty?(@metrics.subscription.top_merchants)} class="text-xs text-zinc-500">No recurring spend detected.</li>
              </ul>
            </div>
          </div>

          <div class="space-y-2 rounded-xl border border-dashed border-zinc-300 bg-gradient-to-br from-zinc-50 to-zinc-100 p-4 text-sm text-zinc-600">
            <h3 class="text-lg font-semibold text-zinc-900">FICO &amp; insights</h3>
            <p>Graphing and credit score modules will appear here soon. Stay tuned for longitudinal trends and score simulators.</p>
            <p class="text-xs text-zinc-500">Product &amp; design teams can hook into this placeholder.</p>
          </div>
        </div>
      </div>

      <div class="grid gap-6 lg:grid-cols-2">
        <div class="space-y-3 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
          <div class="flex items-center justify-between">
            <h3 class="text-lg font-semibold text-zinc-900">Recent activity</h3>
            <span class="text-xs text-zinc-500">Latest transactions</span>
          </div>

          <ul class="divide-y divide-zinc-100 rounded-lg border border-zinc-100">
            <li :for={transaction <- @metrics.recent_transactions} class="flex items-center justify-between gap-4 p-3">
              <div>
                <p class="text-sm font-medium text-zinc-900"><%= transaction.description %></p>
                <p class="text-xs text-zinc-500">
                  <%= transaction.account.name %> • <%= format_timestamp(transaction.posted_at) %>
                </p>
              </div>
              <div class={["text-right text-sm font-semibold", transaction.color_class]}>
                <%= visible_value(@show_balances?, transaction.amount, transaction.amount_masked) %>
              </div>
            </li>
            <li :if={Enum.empty?(@metrics.recent_transactions)} class="p-4 text-center text-sm text-zinc-500">
              No transactions recorded yet.
            </li>
          </ul>
        </div>

        <div class="space-y-3 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
          <div class="flex items-center justify-between">
            <h3 class="text-lg font-semibold text-zinc-900">Category rollups</h3>
            <span class="text-xs text-zinc-500">Current month</span>
          </div>

          <ul class="space-y-2 text-sm">
            <li :for={rollup <- @metrics.category_rollups}
                class="rounded-lg border border-zinc-100 bg-zinc-50 p-3">
              <div class="flex items-center justify-between">
                <span class="font-medium text-zinc-900"><%= rollup.category %></span>
                <span class="text-xs text-zinc-500"><%= format_percent(rollup.percent) %></span>
              </div>
              <div class="text-zinc-700">
                <%= visible_value(@show_balances?, rollup.total, rollup.total_masked) %>
              </div>
            </li>
            <li :if={Enum.empty?(@metrics.category_rollups)} class="text-xs text-zinc-500">Not enough activity yet.</li>
          </ul>
        </div>
      </div>
    </section>
    """
  end

  defp load_dashboard(socket, current_user) do
    socket
    |> assign(:summary, Accounts.dashboard_summary(current_user))
    |> assign_metrics(current_user)
  end

  defp assign_metrics(socket, current_user) do
    assign(socket, :metrics, build_metrics(current_user))
  end

  defp build_metrics(current_user) do
    %{
      net_worth: Accounts.net_worth_snapshot(current_user),
      savings: Accounts.savings_and_investments_summary(current_user),
      card_balances: Accounts.running_card_balances(current_user),
      loans: Loans.overview(current_user),
      budgets: Budgets.aggregate_totals(current_user),
      subscription: Subscriptions.spend_summary(current_user),
      category_rollups: Transactions.category_rollups(current_user),
      recent_transactions: Transactions.recent_with_color(current_user),
      notifications: Notifications.pending(current_user)
    }
  end

  defp visible_value(_show?, nil, _masked), do: "--"
  defp visible_value(true, value, _masked), do: value
  defp visible_value(false, _value, masked), do: masked || "••"

  defp format_timestamp(nil), do: "Pending"

  defp format_timestamp(%DateTime{} = datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%b %d, %Y %H:%M UTC")
  rescue
    _ -> DateTime.to_string(datetime)
  end

  defp format_timestamp(%NaiveDateTime{} = naive) do
    naive
    |> DateTime.from_naive!("Etc/UTC")
    |> format_timestamp()
  end

  defp format_percent(nil), do: "--"

  defp format_percent(%Decimal{} = percent) do
    percent
    |> Decimal.round(2)
    |> Decimal.to_string(:normal)
    |> Kernel.<>("%")
  end

  defp trend_color(:increasing), do: "text-rose-600"
  defp trend_color(:decreasing), do: "text-emerald-600"
  defp trend_color(_), do: "text-zinc-500"

  defp format_date(nil), do: "--"

  defp format_date(%Date{} = date) do
    Calendar.strftime(date, "%b %d, %Y")
  end

  defp budget_badge_class(:over),
    do:
      "inline-flex items-center rounded bg-rose-100 px-2 py-0.5 text-xs font-semibold text-rose-700"

  defp budget_badge_class(:approaching),
    do:
      "inline-flex items-center rounded bg-amber-100 px-2 py-0.5 text-xs font-semibold text-amber-700"

  defp budget_badge_class(_),
    do:
      "inline-flex items-center rounded bg-emerald-100 px-2 py-0.5 text-xs font-semibold text-emerald-700"

  defp budget_status_label(:over), do: "Over"
  defp budget_status_label(:approaching), do: "Near limit"
  defp budget_status_label(_), do: "Healthy"
end
