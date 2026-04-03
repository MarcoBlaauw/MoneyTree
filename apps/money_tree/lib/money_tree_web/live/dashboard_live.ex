defmodule MoneyTreeWeb.DashboardLive do
  @moduledoc """
  Account overview LiveView with masked balance toggling and inactivity locking.
  """

  use MoneyTreeWeb, :live_view

  alias Decimal
  alias MoneyTree.Accounts
  alias MoneyTree.Assets
  alias MoneyTree.Assets.Asset
  alias MoneyTree.Budgets
  alias MoneyTree.Loans
  alias MoneyTree.Notifications
  alias MoneyTree.Subscriptions
  alias MoneyTree.Transactions
  alias MoneyTreeWeb.CoreComponents

  @budget_periods [:weekly, :monthly, :yearly]

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: current_user}} = socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Dashboard",
       show_balances?: false,
       locked?: false,
       asset_form_open?: false,
       asset_form_mode: :new,
       asset_editing_asset: nil,
       asset_changeset: Assets.change_asset(%Asset{}),
       asset_accounts: [],
       budget_period: :monthly
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
     |> clear_flash()
     |> load_dashboard(current_user)
     |> put_flash(:info, "Dashboard unlocked.")}
  end

  def handle_event(
        "refresh-transactions",
        _params,
        %{assigns: %{current_user: current_user, budget_period: period}} = socket
      ) do
    {:noreply, assign_metrics(socket, current_user, period: period)}
  end

  def handle_event(
        "change-budget-period",
        %{"period" => period_param},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    with {:ok, period} <- parse_budget_period(period_param) do
      {:noreply,
       socket
       |> assign(:budget_period, period)
       |> assign_metrics(current_user, period: period)}
    else
      :error -> {:noreply, socket}
    end
  end

  def handle_event(
        "resolve-notification",
        %{"id" => event_id},
        %{assigns: %{current_user: current_user, budget_period: period}} = socket
      ) do
    case Notifications.resolve_event(current_user, event_id) do
      {:ok, _event} ->
        {:noreply,
         socket
         |> assign_metrics(current_user, period: period)
         |> put_flash(:info, "Notification dismissed.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Notification not found or already dismissed.")}

      {:error, :already_resolved} ->
        {:noreply,
         socket
         |> assign_metrics(current_user, period: period)
         |> put_flash(:info, "Notification already dismissed.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Unable to dismiss the notification right now.")}
    end
  end

  def handle_event("new-asset", _params, socket) do
    {:noreply,
     socket
     |> assign(
       asset_form_open?: true,
       asset_form_mode: :new,
       asset_editing_asset: nil,
       asset_changeset: Assets.change_asset(%Asset{})
     )}
  end

  def handle_event("cancel-asset", _params, socket) do
    {:noreply, reset_asset_form(socket)}
  end

  def handle_event(
        "edit-asset",
        %{"id" => asset_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    case Assets.fetch_asset(current_user, asset_id, preload: [:account]) do
      {:ok, asset} ->
        changeset = Assets.change_asset(asset)

        {:noreply,
         socket
         |> assign(
           asset_form_open?: true,
           asset_form_mode: :edit,
           asset_editing_asset: asset,
           asset_changeset: changeset
         )}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Asset not found or no longer accessible.")}
    end
  end

  def handle_event("validate-asset", %{"asset" => params}, socket) do
    base_asset = socket.assigns.asset_editing_asset || %Asset{}

    changeset =
      base_asset
      |> Assets.change_asset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, asset_changeset: changeset, asset_form_open?: true)}
  end

  def handle_event(
        "save-asset",
        %{"asset" => params},
        %{assigns: %{current_user: current_user, asset_form_mode: :new}} = socket
      ) do
    case Assets.create_asset(current_user, params, preload: [:account]) do
      {:ok, _asset} ->
        {:noreply,
         socket
         |> assign_asset_data(current_user)
         |> reset_asset_form()
         |> put_flash(:info, "Asset added successfully.")}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> assign(asset_form_open?: true)
         |> put_flash(:error, "You do not have permission to use that account.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           asset_form_open?: true,
           asset_changeset: Map.put(changeset, :action, :validate)
         )}
    end
  end

  def handle_event(
        "save-asset",
        %{"asset" => params},
        %{
          assigns: %{
            current_user: current_user,
            asset_form_mode: :edit,
            asset_editing_asset: %Asset{} = asset
          }
        } =
          socket
      ) do
    case Assets.update_asset(current_user, asset, params, preload: [:account]) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> assign_asset_data(current_user)
         |> reset_asset_form()
         |> put_flash(:info, "Asset updated successfully.")}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> assign(asset_form_open?: true)
         |> put_flash(:error, "You do not have permission to update that asset.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           asset_form_open?: true,
           asset_changeset: Map.put(changeset, :action, :validate)
         )}
    end
  end

  def handle_event(
        "delete-asset",
        %{"id" => asset_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    with {:ok, asset} <- Assets.fetch_asset(current_user, asset_id),
         {:ok, _deleted} <- Assets.delete_asset(current_user, asset) do
      {:noreply,
       socket
       |> assign_asset_data(current_user)
       |> maybe_reset_form_for_deleted(asset_id)
       |> put_flash(:info, "Asset removed successfully.")}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Asset not found or already removed.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to modify that asset.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Unable to remove the asset right now.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-8">
      <.header title="Dashboard" subtitle="Monitor balances and recent activity." />

      <.dashboard_toolbar locked?={@locked?} show_balances?={@show_balances?} />

      <.kpi_strip
        show_balances?={@show_balances?}
        metrics={@metrics}
        summary={@summary}
        asset_summary={@asset_summary}
      />

      <div class="grid gap-6 xl:grid-cols-[minmax(0,2.1fr)_minmax(22rem,0.95fr)] xl:items-start">
        <div class="min-w-0 space-y-6">
          <.accounts_panel summary={@summary} show_balances?={@show_balances?} />

          <.assets_panel
            asset_summary={@asset_summary}
            asset_accounts={@asset_accounts}
            asset_form_open?={@asset_form_open?}
            asset_form_mode={@asset_form_mode}
            asset_changeset={@asset_changeset}
            asset_editing_asset={@asset_editing_asset}
            show_balances?={@show_balances?}
          />

          <.budget_pulse_panel
            budgets={@metrics.budgets}
            planner_recommendations={@metrics.planner_recommendations}
            budget_rollups={@metrics.budget_rollups}
            budget_period={@budget_period}
            show_balances?={@show_balances?}
          />

          <div class="grid gap-6 lg:grid-cols-2">
            <.net_worth_panel net_worth={@metrics.net_worth} show_balances?={@show_balances?} />
            <.savings_panel savings={@metrics.savings} show_balances?={@show_balances?} />
          </div>

          <div class="grid gap-6 lg:grid-cols-2">
            <.active_cards_panel
              card_balances={@metrics.card_balances}
              show_balances?={@show_balances?}
            />

            <.loans_panel loans={@metrics.loans} show_balances?={@show_balances?} />
          </div>
        </div>

        <div class="min-w-0 space-y-6 xl:sticky xl:top-4">
          <.notifications_panel notifications={@metrics.notifications} />

          <.subscriptions_panel
            subscription={@metrics.subscription}
            show_balances?={@show_balances?}
          />

          <.fico_insights_panel />
        </div>
      </div>

      <div class="grid gap-6 lg:grid-cols-2">
        <.recent_activity_panel
          transactions={@metrics.recent_transactions}
          show_balances?={@show_balances?}
        />

        <.category_rollups_panel
          rollups={@metrics.category_rollups}
          show_balances?={@show_balances?}
        />
      </div>
    </section>
    """
  end

  defp load_dashboard(socket, current_user) do
    period = socket.assigns[:budget_period] || :monthly

    socket
    |> assign(:summary, Accounts.dashboard_summary(current_user))
    |> assign_metrics(current_user, period: period)
    |> assign_asset_data(current_user)
  end

  defp assign_asset_data(socket, current_user) do
    summary = Assets.dashboard_summary(current_user, preload: [:account])
    accounts = Accounts.list_accessible_accounts(current_user, order_by: {:asc, :name})

    assign(socket, asset_summary: summary, asset_accounts: accounts)
  end

  defp assign_metrics(socket, current_user, opts) do
    period = Keyword.get(opts, :period, socket.assigns[:budget_period] || :monthly)
    metrics = build_metrics(current_user, Keyword.put(opts, :period, period))

    assign(socket, :metrics, metrics)
  end

  defp build_metrics(current_user, opts) do
    period = Keyword.get(opts, :period, :monthly)
    budget_opts = Keyword.put(opts, :period, period)
    budgets = Budgets.aggregate_totals(current_user, budget_opts)
    entry_rollups = Budgets.rollup_by_entry_type(current_user, budget_opts)
    variability_rollups = Budgets.rollup_by_variability(current_user, budget_opts)

    %{
      net_worth: Accounts.net_worth_snapshot(current_user),
      savings: Accounts.savings_and_investments_summary(current_user),
      card_balances: Accounts.running_card_balances(current_user),
      loans: Loans.overview(current_user),
      budgets: budgets,
      planner_recommendations: Budgets.planner_recommendations(current_user),
      budget_rollups: %{entry_type: entry_rollups, variability: variability_rollups},
      subscription: Subscriptions.spend_summary(current_user),
      category_rollups: Transactions.category_rollups(current_user),
      recent_transactions: Transactions.recent_with_color(current_user),
      notifications: Notifications.pending(current_user, budget_opts)
    }
  end

  attr :locked?, :boolean, required: true
  attr :show_balances?, :boolean, required: true

  defp dashboard_toolbar(assigns) do
    ~H"""
    <div class="rounded-2xl border border-zinc-200 bg-gradient-to-r from-white via-emerald-50/40 to-white p-4 shadow-sm">
      <div class="flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
        <div class="space-y-2">
          <p class="text-[11px] font-semibold uppercase tracking-[0.18em] text-zinc-500">
            Dashboard controls
          </p>
          <div class="flex flex-wrap items-center gap-2 text-xs">
            <span class={toolbar_status_badge_class(if(@locked?, do: :locked, else: :active))}>
              <%= if @locked?, do: "Locked", else: "Active session" %>
            </span>
            <span class={toolbar_status_badge_class(if(@show_balances?, do: :visible, else: :masked))}>
              <%= if @show_balances?, do: "Balances visible", else: "Balances masked" %>
            </span>
          </div>
          <p class="text-sm text-zinc-600">
            Reveal values only when needed, lock the session when you step away, and refresh the latest activity without leaving the dashboard.
          </p>
        </div>

        <div class="flex flex-wrap items-center gap-2 lg:justify-end">
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
      </div>
    </div>
    """
  end

  attr :show_balances?, :boolean, required: true
  attr :metrics, :map, required: true
  attr :summary, :map, required: true
  attr :asset_summary, :map, required: true

  defp kpi_strip(assigns) do
    ~H"""
    <div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-6">
      <.kpi_card
        label="Net worth"
        value={visible_value(@show_balances?, @metrics.net_worth.net_worth, @metrics.net_worth.net_worth_masked)}
        hint="Household balance snapshot"
      />
      <.kpi_card
        label="Accounts"
        value={connected_account_count(@summary)}
        hint="Connected financial accounts"
      />
      <.kpi_card
        label="Active alerts"
        value={length(@metrics.notifications)}
        hint="Open dashboard notifications"
      />
      <.kpi_card
        label="Upcoming due"
        value={upcoming_due_count(@metrics.loans)}
        hint="Loan payments due in 7 days"
      />
      <.kpi_card
        label="Subscriptions"
        value={visible_value(@show_balances?, @metrics.subscription.monthly_total, @metrics.subscription.monthly_total_masked)}
        hint="Monthly recurring spend"
      />
      <.kpi_card
        label="Tracked assets"
        value={@asset_summary.total_count}
        hint="Tangible asset records"
      />
    </div>
    """
  end

  defp fico_insights_panel(assigns) do
    ~H"""
    <div class="space-y-4 rounded-xl border border-dashed border-zinc-300 bg-gradient-to-br from-zinc-50 via-white to-sky-50 p-4 shadow-sm">
      <div class="flex items-start justify-between gap-3">
        <div>
          <h3 class="text-lg font-semibold text-zinc-900">FICO &amp; insights</h3>
          <p class="text-xs text-zinc-500">Reserved for score trends and credit health signals</p>
        </div>
        <span class="rounded-full bg-white/80 px-2 py-1 text-[11px] font-semibold uppercase tracking-wide text-zinc-500">
          Placeholder
        </span>
      </div>

      <div class="space-y-3 rounded-lg border border-white/80 bg-white/80 p-3">
        <div class="flex items-end justify-between gap-3">
          <div>
            <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Score band</p>
            <p class="mt-1 text-2xl font-semibold text-zinc-900">Coming soon</p>
          </div>
          <span class="rounded-full bg-zinc-100 px-2 py-1 text-[11px] font-semibold uppercase tracking-wide text-zinc-500">
            No bureau data
          </span>
        </div>

        <.progress_meter
          width={0}
          bar_class="h-full rounded-full bg-zinc-300 transition-all"
          label="Credit insights availability"
        />

        <div class="grid gap-2 text-xs sm:grid-cols-2">
          <div class="rounded-md bg-zinc-50 px-3 py-2 text-zinc-600">
            Historical score charts will fit here once longitudinal data is available.
          </div>
          <div class="rounded-md bg-zinc-50 px-3 py-2 text-zinc-600">
            Credit-utilization, inquiry, and on-time payment signals can plug into this rail later.
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, required: true

  defp kpi_card(assigns) do
    ~H"""
    <div class="space-y-1 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
      <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500"><%= @label %></p>
      <p class="text-2xl font-semibold text-zinc-900"><%= @value %></p>
      <p class="text-xs text-zinc-500"><%= @hint %></p>
    </div>
    """
  end

  attr :notifications, :list, required: true

  defp notifications_panel(assigns) do
    ~H"""
    <div class="space-y-3 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
      <div class="flex items-start justify-between gap-3">
        <div>
          <h3 class="text-lg font-semibold text-zinc-900">Notifications</h3>
          <p class="text-xs text-zinc-500">Automated insights and actionable alerts</p>
        </div>
        <span class="rounded-full bg-zinc-100 px-2 py-1 text-[11px] font-semibold uppercase tracking-wide text-zinc-500">
          <%= length(@notifications) %> open
        </span>
      </div>

      <ul class="space-y-2 text-sm">
        <li :for={notification <- @notifications}
            class="space-y-3 rounded-lg border border-zinc-100 bg-zinc-50 p-3">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="font-medium text-zinc-900"><%= notification.message %></p>
              <p :if={notification.action} class="mt-1 text-xs text-emerald-600"><%= notification.action %></p>
            </div>
            <span class={notification_severity_badge_class(notification.severity)}>
              <%= Atom.to_string(notification.severity) %>
            </span>
          </div>

          <div class="flex items-center justify-between gap-3 text-xs">
            <span class="text-zinc-500">
              <%= if notification.durable, do: "Durable event", else: "Computed advisory" %>
            </span>
            <button :if={notification.durable && notification.event_id}
                    type="button"
                    class="btn btn-ghost shrink-0 text-xs text-zinc-600"
                    phx-click="resolve-notification"
                    phx-value-id={notification.event_id}>
              Dismiss
            </button>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  attr :transactions, :list, required: true
  attr :show_balances?, :boolean, required: true

  defp recent_activity_panel(assigns) do
    ~H"""
    <div class="space-y-3 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
      <div class="flex items-start justify-between gap-3">
        <div>
          <h3 class="text-lg font-semibold text-zinc-900">Recent activity</h3>
          <p class="text-xs text-zinc-500">Latest posted and pending transactions</p>
        </div>
        <span class="rounded-full bg-zinc-100 px-2 py-1 text-[11px] font-semibold uppercase tracking-wide text-zinc-500">
          Latest transactions
        </span>
      </div>

      <ul class="space-y-2">
        <li :for={transaction <- @transactions}
            class="rounded-lg border border-zinc-100 bg-zinc-50 p-3">
          <div class="flex items-start justify-between gap-4">
            <div class="min-w-0">
              <p class="text-sm font-medium text-zinc-900"><%= transaction.description %></p>
              <p class="mt-1 text-xs text-zinc-500">
                <span class="inline-block rounded-full bg-white px-2 py-1 font-semibold uppercase tracking-wide text-zinc-500">
                  <%= transaction.account.name %>
                </span>
              </p>
              <p class="mt-2 text-xs text-zinc-500">
                Posted <%= format_timestamp(transaction.posted_at) %>
              </p>
            </div>
            <div class="text-right">
              <div class={["text-sm font-semibold", transaction.color_class]}>
                <%= visible_value(@show_balances?, transaction.amount, transaction.amount_masked) %>
              </div>
            </div>
          </div>
        </li>
        <li :if={Enum.empty?(@transactions)} class="rounded-lg border border-dashed border-zinc-200 p-4 text-center text-sm text-zinc-500">
          No transactions recorded yet.
        </li>
      </ul>
    </div>
    """
  end

  attr :rollups, :list, required: true
  attr :show_balances?, :boolean, required: true

  defp category_rollups_panel(assigns) do
    ~H"""
    <div class="space-y-3 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
      <div class="flex items-center justify-between">
        <h3 class="text-lg font-semibold text-zinc-900">Category rollups</h3>
        <span class="text-xs text-zinc-500">Current month</span>
      </div>

      <ul class="space-y-2 text-sm">
        <li :for={rollup <- @rollups}
            class="space-y-2 rounded-lg border border-zinc-100 bg-zinc-50 p-3">
          <div class="flex items-center justify-between gap-3">
            <span class="font-medium text-zinc-900"><%= rollup.category %></span>
            <span class="shrink-0 text-xs text-zinc-500"><%= format_percent(rollup.percent) %></span>
          </div>

          <.progress_meter
            width={rollup_progress_width(rollup.percent)}
            bar_class="h-full rounded-full bg-emerald-500 transition-all"
            label={"#{rollup.category} share of spending"}
          />

          <div class="text-sm font-medium text-zinc-700">
            <%= visible_value(@show_balances?, rollup.total, rollup.total_masked) %>
          </div>
        </li>
        <li :if={Enum.empty?(@rollups)} class="text-xs text-zinc-500">Not enough activity yet.</li>
      </ul>
    </div>
    """
  end

  attr :summary, :map, required: true
  attr :show_balances?, :boolean, required: true

  defp accounts_panel(assigns) do
    ~H"""
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

          <div class="grid gap-1 text-xs text-zinc-500 sm:grid-cols-2">
            <div :if={summary.apr} class="flex items-center justify-between">
              <span>APR</span>
              <span class="text-zinc-700"><%= summary.apr %></span>
            </div>

            <div :if={summary.minimum_balance} class="flex items-center justify-between">
              <span>Min balance</span>
              <span class="text-zinc-700">
                <%= visible_value(@show_balances?, summary.minimum_balance, summary.minimum_balance_masked) %>
              </span>
            </div>

            <div :if={summary.maximum_balance} class="flex items-center justify-between">
              <span>Max balance</span>
              <span class="text-zinc-700">
                <%= visible_value(@show_balances?, summary.maximum_balance, summary.maximum_balance_masked) %>
              </span>
            </div>
          </div>

          <p :if={summary.fee_schedule} class="text-xs text-zinc-500">
            <span class="font-medium text-zinc-600">Fees:</span>
            <span class="text-zinc-700"><%= summary.fee_schedule %></span>
          </p>
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
    """
  end

  attr :asset_summary, :map, required: true
  attr :asset_accounts, :list, required: true
  attr :asset_form_open?, :boolean, required: true
  attr :asset_form_mode, :atom, required: true
  attr :asset_changeset, :any, required: true
  attr :asset_editing_asset, :any, required: true
  attr :show_balances?, :boolean, required: true

  defp assets_panel(assigns) do
    ~H"""
    <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
      <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h3 class="text-lg font-semibold text-zinc-900">Tangible assets</h3>
          <p class="text-xs text-zinc-500">
            Track real estate, vehicles, collectibles, and other tangible holdings.
          </p>
        </div>
        <div class="flex items-center gap-2">
          <span class="text-xs text-zinc-500"><%= @asset_summary.total_count %> assets tracked</span>
          <button id="new-asset" phx-click="new-asset" type="button" class="btn btn-outline">
            Add asset
          </button>
        </div>
      </div>

      <ul class="space-y-3">
        <li :for={summary <- @asset_summary.assets}
            id={"asset-#{summary.asset.id}"}
            class="space-y-2 rounded-lg border border-zinc-100 bg-zinc-50 p-3">
          <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <p class="font-medium text-zinc-900"><%= summary.asset.name %></p>
              <p class="text-xs text-zinc-500">
                <%= summary.asset.asset_type %> • <%= summary.asset.account.name %>
              </p>
            </div>
            <div class="text-right">
              <p class="text-sm font-semibold text-zinc-900">
                <%= visible_value(@show_balances?, summary.valuation, summary.valuation_masked) %>
              </p>
              <p class="text-xs text-zinc-500">
                <%= summary.asset.ownership_type %>
                <%= if summary.asset.location do %>
                  • <%= summary.asset.location %>
                <% end %>
              </p>
            </div>
          </div>

          <div class="flex flex-wrap gap-3 text-xs text-zinc-500">
            <span :if={summary.asset.acquired_on}>
              Acquired <%= format_date(summary.asset.acquired_on) %>
            </span>
            <span :if={summary.asset.last_valued_on}>
              Last valued <%= format_date(summary.asset.last_valued_on) %>
            </span>
          </div>

          <p :if={summary.asset.notes} class="text-xs text-zinc-500"><%= summary.asset.notes %></p>

          <p :if={not Enum.empty?(summary.asset.document_refs)} class="text-xs text-zinc-500">
            Documents: <%= Enum.join(summary.asset.document_refs, ", ") %>
          </p>

          <div class="flex justify-end gap-2">
            <button type="button"
                    class="btn btn-outline"
                    phx-click="edit-asset"
                    phx-value-id={summary.asset.id}>
              Edit
            </button>
            <button type="button"
                    class="btn btn-ghost text-rose-600"
                    phx-click="delete-asset"
                    phx-value-id={summary.asset.id}
                    data-confirm="Are you sure you want to remove this asset?">
              Remove
            </button>
          </div>
        </li>

        <li :if={Enum.empty?(@asset_summary.assets)}
            class="rounded-lg border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
          Record tangible assets to include their valuations in your dashboard metrics.
        </li>
      </ul>

      <div class="grid gap-2 rounded-lg border border-zinc-100 bg-zinc-50 p-3 sm:grid-cols-2">
        <div :for={total <- @asset_summary.totals} class="flex items-center justify-between text-sm">
          <span class="text-zinc-600"><%= total.currency %> • <%= total.asset_count %> assets</span>
          <span class="font-semibold text-zinc-800">
            <%= visible_value(@show_balances?, total.valuation, total.valuation_masked) %>
          </span>
        </div>
        <div :if={Enum.empty?(@asset_summary.totals)} class="text-sm text-zinc-500">
          Totals appear after at least one asset valuation is recorded.
        </div>
      </div>

      <.asset_form_panel
        :if={@asset_form_open?}
        asset_changeset={@asset_changeset}
        asset_accounts={@asset_accounts}
        asset_editing_asset={@asset_editing_asset}
        asset_form_mode={@asset_form_mode}
      />
    </div>
    """
  end

  attr :asset_changeset, :any, required: true
  attr :asset_accounts, :list, required: true
  attr :asset_editing_asset, :any, required: true
  attr :asset_form_mode, :atom, required: true

  defp asset_form_panel(assigns) do
    ~H"""
    <div class="space-y-3 rounded-lg border border-zinc-100 bg-white p-4">
      <h4 class="text-base font-semibold text-zinc-900">
        <%= if @asset_form_mode == :edit, do: "Edit asset", else: "Add asset" %>
      </h4>

      <.simple_form for={@asset_changeset}
                    id="asset-form"
                    phx-change="validate-asset"
                    phx-submit="save-asset"
                    :let={f}>
        <div class="grid gap-4 md:grid-cols-2">
          <div class="md:col-span-2">
            <label class="text-sm font-medium text-zinc-700" for="asset_account_id">Account</label>
            <select id="asset_account_id" name="asset[account_id]" class="input">
              <%= Phoenix.HTML.Form.options_for_select(asset_account_options(@asset_accounts), f[:account_id].value ||
                (@asset_editing_asset && @asset_editing_asset.account_id)) %>
            </select>
            <p :for={error <- errors_on(@asset_changeset, :account_id)} class="text-sm text-red-600"><%= error %></p>
          </div>

          <.input field={f[:name]} label="Name" />
          <.input field={f[:asset_type]} label="Type" />
          <.input field={f[:category]} label="Category" />
          <.input field={f[:valuation_amount]} label="Valuation amount" type={:number} step="0.01" min="0" />
          <.input field={f[:valuation_currency]} label="Currency" />
          <.input field={f[:ownership_type]} label="Ownership type" />
          <.input field={f[:ownership_details]} label="Ownership details" type={:textarea} />
          <.input field={f[:location]} label="Location" />
          <.input field={f[:notes]} label="Notes" type={:textarea} />

          <div>
            <label class="text-sm font-medium text-zinc-700" for="asset_acquired_on">Acquired on</label>
            <input id="asset_acquired_on"
                   name="asset[acquired_on]"
                   type="date"
                   value={format_input_date(f[:acquired_on].value)}
                   class="input" />
            <p :for={error <- errors_on(@asset_changeset, :acquired_on)} class="text-sm text-red-600"><%= error %></p>
          </div>

          <div>
            <label class="text-sm font-medium text-zinc-700" for="asset_last_valued_on">Last valued on</label>
            <input id="asset_last_valued_on"
                   name="asset[last_valued_on]"
                   type="date"
                   value={format_input_date(f[:last_valued_on].value)}
                   class="input" />
            <p :for={error <- errors_on(@asset_changeset, :last_valued_on)} class="text-sm text-red-600"><%= error %></p>
          </div>

          <div class="md:col-span-2">
            <.input field={f[:documents_text]}
                    label="Document references"
                    type={:textarea}
                    placeholder="Enter document references separated by commas or new lines" />
          </div>
        </div>

        <div class="flex justify-end gap-2">
          <button type="button" class="btn btn-outline" phx-click="cancel-asset">Cancel</button>
          <button type="submit" class="btn">
            <%= if @asset_form_mode == :edit, do: "Save changes", else: "Add asset" %>
          </button>
        </div>
      </.simple_form>
    </div>
    """
  end

  attr :net_worth, :map, required: true
  attr :show_balances?, :boolean, required: true

  defp net_worth_panel(assigns) do
    ~H"""
    <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
      <div>
        <h3 class="text-lg font-semibold text-zinc-900">Household net worth</h3>
        <p class="text-xs text-zinc-500">High-level balance sheet snapshot</p>
      </div>

      <div class="grid gap-4 lg:grid-cols-[minmax(0,12rem)_minmax(0,1fr)] lg:items-center">
        <.composition_donut
          segments={net_worth_segments(@net_worth)}
          total_label={visible_value(@show_balances?, @net_worth.net_worth, @net_worth.net_worth_masked)}
          subtitle="Net worth"
        />

        <div class="space-y-2">
          <div class="flex items-center justify-between rounded-md bg-zinc-50 px-3 py-2 text-sm">
            <span class="flex items-center gap-2 text-zinc-600">
              <span class="h-2.5 w-2.5 rounded-full bg-emerald-500"></span>
              Assets
            </span>
            <span class="font-medium text-emerald-700">
              <%= visible_value(@show_balances?, @net_worth.assets, @net_worth.assets_masked) %>
            </span>
          </div>

          <div class="flex items-center justify-between rounded-md bg-zinc-50 px-3 py-2 text-sm">
            <span class="flex items-center gap-2 text-zinc-600">
              <span class="h-2.5 w-2.5 rounded-full bg-rose-500"></span>
              Liabilities
            </span>
            <span class="font-medium text-rose-600">
              <%= visible_value(@show_balances?, @net_worth.liabilities, @net_worth.liabilities_masked) %>
            </span>
          </div>
        </div>
      </div>

      <div class="rounded-lg border border-zinc-100 bg-zinc-50 p-4">
        <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Net worth</p>
        <p class="mt-1 text-2xl font-semibold text-zinc-900">
          <%= visible_value(@show_balances?, @net_worth.net_worth, @net_worth.net_worth_masked) %>
        </p>
      </div>

      <dl class="grid gap-3 text-sm sm:grid-cols-2">
        <div class="space-y-1 rounded-lg border border-zinc-100 bg-zinc-50 p-3">
          <dt class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Assets</dt>
          <dd class="text-base font-medium text-emerald-700">
            <%= visible_value(@show_balances?, @net_worth.assets, @net_worth.assets_masked) %>
          </dd>
        </div>

        <div class="space-y-1 rounded-lg border border-zinc-100 bg-zinc-50 p-3">
          <dt class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Liabilities</dt>
          <dd class="text-base font-medium text-rose-600">
            <%= visible_value(@show_balances?, @net_worth.liabilities, @net_worth.liabilities_masked) %>
          </dd>
        </div>
      </dl>

      <div class="space-y-2">
        <h4 class="text-xs font-semibold uppercase tracking-wide text-zinc-500">Breakdown</h4>
        <ul class="space-y-2 text-sm">
          <li :for={item <- @net_worth.breakdown.assets}
              class="flex items-center justify-between rounded-md bg-zinc-50 px-3 py-2">
            <span class="text-zinc-600"><%= item.label %></span>
            <span class="font-medium text-emerald-700">
              <%= visible_value(@show_balances?, item.total, item.total_masked) %>
            </span>
          </li>
          <li :for={item <- @net_worth.breakdown.liabilities}
              class="flex items-center justify-between rounded-md bg-zinc-50 px-3 py-2">
            <span class="text-zinc-600"><%= item.label %></span>
            <span class="font-medium text-rose-600">
              <%= visible_value(@show_balances?, item.total, item.total_masked) %>
            </span>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :savings, :map, required: true
  attr :show_balances?, :boolean, required: true

  defp savings_panel(assigns) do
    ~H"""
    <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
      <div>
        <h3 class="text-lg font-semibold text-zinc-900">Savings &amp; investments</h3>
        <p class="text-xs text-zinc-500">Long-term reserves and growth accounts</p>
      </div>

      <div class="space-y-3 rounded-lg border border-zinc-100 bg-zinc-50 p-4">
        <div class="flex items-center justify-between">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Allocation mix</p>
          <p class="text-xs text-zinc-500">Current allocation</p>
        </div>

        <.stacked_bar
          segments={savings_segments(@savings)}
          label="Savings and investments allocation"
        />

        <div class="grid gap-2 text-xs sm:grid-cols-2">
          <div class="flex items-center justify-between rounded-md bg-white px-3 py-2">
            <span class="flex items-center gap-2 text-zinc-600">
              <span class="h-2.5 w-2.5 rounded-full bg-emerald-500"></span>
              Savings
            </span>
            <span class="font-medium text-zinc-700">
              <%= visible_value(@show_balances?, @savings.savings_total, @savings.savings_total_masked) %>
            </span>
          </div>
          <div class="flex items-center justify-between rounded-md bg-white px-3 py-2">
            <span class="flex items-center gap-2 text-zinc-600">
              <span class="h-2.5 w-2.5 rounded-full bg-sky-500"></span>
              Investments
            </span>
            <span class="font-medium text-zinc-700">
              <%= visible_value(@show_balances?, @savings.investment_total, @savings.investment_total_masked) %>
            </span>
          </div>
        </div>
      </div>

      <div class="rounded-lg border border-zinc-100 bg-zinc-50 p-4">
        <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Combined</p>
        <p class="mt-1 text-2xl font-semibold text-emerald-700">
          <%= visible_value(@show_balances?, @savings.combined_total, @savings.combined_total_masked) %>
        </p>
      </div>

      <dl class="grid gap-3 text-sm sm:grid-cols-2">
        <div class="space-y-1 rounded-lg border border-zinc-100 bg-zinc-50 p-3">
          <dt class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Total saved</dt>
          <dd class="text-base font-medium text-zinc-900">
            <%= visible_value(@show_balances?, @savings.savings_total, @savings.savings_total_masked) %>
          </dd>
        </div>

        <div class="space-y-1 rounded-lg border border-zinc-100 bg-zinc-50 p-3">
          <dt class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Invested</dt>
          <dd class="text-base font-medium text-zinc-900">
            <%= visible_value(@show_balances?, @savings.investment_total, @savings.investment_total_masked) %>
          </dd>
        </div>
      </dl>

      <div class="grid gap-3 text-sm md:grid-cols-2">
        <div class="space-y-2 rounded-lg border border-zinc-100 bg-zinc-50 p-3">
          <h4 class="text-xs font-semibold uppercase tracking-wide text-zinc-500">Savings</h4>
          <ul class="space-y-1">
            <li :for={account <- @savings.savings_accounts}
                class="flex items-center justify-between rounded-md bg-white px-3 py-2">
              <span class="text-zinc-600"><%= account.name %></span>
              <span class="text-zinc-700">
                <%= visible_value(@show_balances?, account.balance, account.balance_masked) %>
              </span>
            </li>
            <li :if={Enum.empty?(@savings.savings_accounts)} class="text-xs text-zinc-500">No savings accounts.</li>
          </ul>
        </div>

        <div class="space-y-2 rounded-lg border border-zinc-100 bg-zinc-50 p-3">
          <h4 class="text-xs font-semibold uppercase tracking-wide text-zinc-500">Investments</h4>
          <ul class="space-y-1">
            <li :for={account <- @savings.investment_accounts}
                class="flex items-center justify-between rounded-md bg-white px-3 py-2">
              <span class="text-zinc-600"><%= account.name %></span>
              <span class="text-zinc-700">
                <%= visible_value(@show_balances?, account.balance, account.balance_masked) %>
              </span>
            </li>
            <li :if={Enum.empty?(@savings.investment_accounts)} class="text-xs text-zinc-500">No investment accounts.</li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  attr :segments, :list, required: true
  attr :total_label, :string, required: true
  attr :subtitle, :string, required: true

  defp composition_donut(assigns) do
    segments =
      assigns.segments
      |> Enum.map_reduce(0, fn segment, offset ->
        segment =
          segment
          |> Map.put(:offset, offset)
          |> Map.put(:remainder, max(0, 100 - segment.percent))

        {segment, offset + segment.percent}
      end)
      |> elem(0)

    assigns = assign(assigns, :segments_with_offsets, segments)

    ~H"""
    <div class="mx-auto flex w-full max-w-[12rem] flex-col items-center gap-3">
      <svg viewBox="0 0 120 120" class="h-44 w-44" role="img" aria-label={@subtitle}>
        <circle cx="60" cy="60" r="36" fill="none" stroke="#e4e4e7" stroke-width="12" />
        <circle :for={segment <- @segments_with_offsets}
                cx="60"
                cy="60"
                r="36"
                fill="none"
                stroke={segment.color}
                stroke-width="12"
                stroke-linecap="round"
                pathLength="100"
                stroke-dasharray={"#{segment.percent} #{segment.remainder}"}
                stroke-dashoffset={-segment.offset}
                transform="rotate(-90 60 60)" />
        <text x="60" y="56" text-anchor="middle" class="fill-zinc-500 text-[9px] font-semibold uppercase tracking-[0.18em]">
          <%= @subtitle %>
        </text>
        <text x="60" y="72" text-anchor="middle" class="fill-zinc-900 text-[11px] font-semibold">
          <%= @total_label %>
        </text>
      </svg>
    </div>
    """
  end

  attr :segments, :list, required: true
  attr :label, :string, required: true

  defp stacked_bar(assigns) do
    ~H"""
    <div class="space-y-2">
      <div class="flex h-3 overflow-hidden rounded-full bg-zinc-200" role="img" aria-label={@label}>
        <div :for={segment <- @segments}
             class="h-full transition-all"
             style={"width: #{segment.percent}%; background-color: #{segment.color};"} />
      </div>
      <div class="flex flex-wrap gap-2 text-[11px] text-zinc-500">
        <span :for={segment <- @segments} class="inline-flex items-center gap-1">
          <span class="h-2.5 w-2.5 rounded-full" style={"background-color: #{segment.color};"}></span>
          <span><%= segment.label %> <%= segment.percent %>%</span>
        </span>
      </div>
    </div>
    """
  end

  attr :card_balances, :list, required: true
  attr :show_balances?, :boolean, required: true

  defp active_cards_panel(assigns) do
    ~H"""
    <div class="space-y-3 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
      <div class="flex items-start justify-between gap-3">
        <div>
          <h3 class="text-lg font-semibold text-zinc-900">Active cards</h3>
          <p class="text-xs text-zinc-500">Utilization and recent activity</p>
        </div>
        <span class="rounded-full bg-zinc-100 px-2 py-1 text-[11px] font-semibold uppercase tracking-wide text-zinc-500">
          Last 30 days
        </span>
      </div>

      <ul class="space-y-3 text-sm">
        <li :for={balance <- @card_balances}
            class="space-y-3 rounded-lg border border-zinc-100 bg-zinc-50 p-4">
          <div class="flex items-center justify-between gap-3">
            <div class="min-w-0">
              <p class="font-medium text-zinc-900"><%= balance.account.name %></p>
              <p class="text-xs text-zinc-500">Card utilization snapshot</p>
            </div>
            <span class={card_utilization_badge_class(balance.utilization_percent)}>
              <%= format_percent(balance.utilization_percent) %>
            </span>
          </div>

          <div class="space-y-2">
            <div class="flex items-center justify-between text-xs">
              <span class="font-medium text-zinc-600">Utilization</span>
              <span class="text-zinc-500"><%= format_percent(balance.utilization_percent) %></span>
            </div>
            <.progress_meter
              width={rollup_progress_width(balance.utilization_percent)}
              bar_class={card_utilization_bar_class(balance.utilization_percent)}
              label={"#{balance.account.name} utilization"}
            />
          </div>

          <dl class="grid gap-2 text-xs sm:grid-cols-2">
            <div class="space-y-1 rounded-md bg-white px-3 py-2">
              <dt class="font-semibold uppercase tracking-wide text-zinc-500">Current</dt>
              <dd class="text-sm font-medium text-zinc-800">
                <%= visible_value(@show_balances?, balance.current_balance, balance.current_balance_masked) %>
              </dd>
            </div>

            <div class="space-y-1 rounded-md bg-white px-3 py-2">
              <dt class="font-semibold uppercase tracking-wide text-zinc-500">Available</dt>
              <dd class="text-sm font-medium text-zinc-700">
                <%= visible_value(@show_balances?, balance.available_credit, balance.available_credit_masked) %>
              </dd>
            </div>

            <div class="flex items-center justify-between rounded-md bg-white px-3 py-2 sm:col-span-2">
              <dt class="text-zinc-500">Recent activity</dt>
              <dd class={["font-medium", trend_color(balance.trend_direction)]}>
                <%= visible_value(@show_balances?, balance.trend_amount, balance.trend_amount_masked) %>
              </dd>
            </div>
          </dl>
        </li>

        <li :if={Enum.empty?(@card_balances)} class="text-xs text-zinc-500">No active cards detected.</li>
      </ul>
    </div>
    """
  end

  attr :loans, :list, required: true
  attr :show_balances?, :boolean, required: true

  defp loans_panel(assigns) do
    ~H"""
    <div class="space-y-3 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
      <div class="flex items-start justify-between gap-3">
        <div>
          <h3 class="text-lg font-semibold text-zinc-900">Loans &amp; autopay</h3>
          <p class="text-xs text-zinc-500">Upcoming due dates and autopay state</p>
        </div>
        <span class="rounded-full bg-zinc-100 px-2 py-1 text-[11px] font-semibold uppercase tracking-wide text-zinc-500">
          Autopay overview
        </span>
      </div>

      <ul class="space-y-3 text-sm">
        <li :for={loan <- @loans}
            class="space-y-3 rounded-lg border border-zinc-100 bg-zinc-50 p-4">
          <div class="flex items-center justify-between gap-3">
            <div class="min-w-0">
              <p class="font-medium text-zinc-900"><%= loan.account.name %></p>
              <p class="text-xs text-zinc-500">Next due <%= format_date(loan.next_due_date) %></p>
            </div>
            <span class={autopay_badge_class(loan.autopay.enabled?)}>
              <%= if loan.autopay.enabled?, do: "Autopay on", else: "Autopay off" %>
            </span>
          </div>

          <dl class="grid gap-2 text-xs sm:grid-cols-2">
            <div class="space-y-1 rounded-md bg-white px-3 py-2">
              <dt class="font-semibold uppercase tracking-wide text-zinc-500">Balance</dt>
              <dd class="text-sm font-medium text-zinc-800">
                <%= visible_value(@show_balances?, loan.current_balance, loan.current_balance_masked) %>
              </dd>
            </div>

            <div class="space-y-1 rounded-md bg-white px-3 py-2">
              <dt class="font-semibold uppercase tracking-wide text-zinc-500">Last payment</dt>
              <dd class="text-sm font-medium text-zinc-700">
                <%= visible_value(@show_balances?, loan.last_payment, loan.last_payment_masked) %>
              </dd>
            </div>
          </dl>

          <div class="space-y-2 rounded-lg border border-zinc-200 bg-white p-3">
            <div class="flex items-center justify-between gap-3">
              <div>
                <p class="text-xs font-semibold uppercase tracking-wide text-zinc-500">Autopay</p>
                <p class="text-xs text-zinc-500">Next run <%= format_date(loan.autopay.next_run_on) %></p>
              </div>
              <p class={["text-sm font-medium", if(loan.autopay.enabled?, do: "text-emerald-600", else: "text-rose-600")]}>
                <%= if loan.autopay.enabled?, do: "Enabled", else: "Disabled" %>
              </p>
            </div>

            <.progress_meter
              width={if loan.autopay.enabled?, do: 100, else: 24}
              bar_class={autopay_bar_class(loan.autopay.enabled?)}
              label={"#{loan.account.name} autopay status"}
            />

            <div class="flex items-center justify-between text-xs">
              <span class="text-zinc-500">Payment amount</span>
              <span class="font-medium text-zinc-700">
                <%= visible_value(@show_balances?, loan.autopay.payment_amount, loan.autopay.payment_amount_masked) %>
              </span>
            </div>
          </div>
        </li>

        <li :if={Enum.empty?(@loans)} class="text-xs text-zinc-500">No loans linked yet.</li>
      </ul>
    </div>
    """
  end

  attr :budgets, :list, required: true
  attr :planner_recommendations, :list, required: true
  attr :budget_rollups, :map, required: true
  attr :budget_period, :atom, required: true
  attr :show_balances?, :boolean, required: true

  defp budget_pulse_panel(assigns) do
    ~H"""
    <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
      <div class="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
        <div>
          <h3 class="text-lg font-semibold text-zinc-900">Budget pulse</h3>
          <p class="text-xs text-zinc-500"><%= budget_period_label(@budget_period) %> insights</p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <button :for={period <- budget_periods()}
                  type="button"
                  class={budget_period_button_class(period, @budget_period)}
                  phx-click="change-budget-period"
                  phx-value-period={budget_period_value(period)}>
            <%= budget_period_label(period) %>
          </button>
        </div>
      </div>

      <ul class="grid gap-3 xl:grid-cols-2">
        <li :for={suggestion <- @planner_recommendations}
            class="rounded-lg border border-emerald-100 bg-emerald-50 p-3 xl:col-span-2">
          <div class="flex items-center justify-between gap-3">
            <span class="font-medium text-emerald-900"><%= suggestion.budget_name %></span>
            <span class={["shrink-0", trend_color(suggestion.direction)]}><%= Decimal.to_string(suggestion.delta, :normal) %></span>
          </div>
          <p class="mt-1 text-xs text-emerald-800"><%= suggestion.explanation %></p>
        </li>

        <li :for={budget <- @budgets}
            class="space-y-3 rounded-lg border border-zinc-100 bg-zinc-50 p-4">
          <div class="flex items-center justify-between gap-3">
            <div class="min-w-0">
              <p class="font-medium text-zinc-900"><%= budget.name %></p>
              <p class="text-xs text-zinc-500">Budget status</p>
            </div>
            <span class={["shrink-0", budget_badge_class(budget.status)]}><%= budget_status_label(budget.status) %></span>
          </div>

          <div class="grid gap-3 sm:grid-cols-3">
            <div class="space-y-1">
              <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Spent</p>
              <p class="text-lg font-semibold text-zinc-900">
                <%= visible_value(@show_balances?, budget.spent, budget.spent_masked) %>
              </p>
            </div>
            <div class="space-y-1">
              <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Allocated</p>
              <p class="text-sm font-medium text-zinc-700">
                <%= visible_value(@show_balances?, budget.allocated, budget.allocated_masked) %>
              </p>
            </div>
            <div class="space-y-1">
              <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Remaining</p>
              <p class="text-sm font-medium text-emerald-700">
                <%= visible_value(@show_balances?, budget.remaining, budget.remaining_masked) %>
              </p>
            </div>
          </div>

          <div class="space-y-2">
            <div class="flex items-center justify-between text-xs">
              <span class="font-medium text-zinc-600">Utilization</span>
              <span class="text-zinc-500"><%= format_percent(budget_progress_percent(budget)) %></span>
            </div>
            <.progress_meter
              width={budget_progress_width(budget)}
              bar_class={budget_progress_bar_class(budget.status)}
              label={"#{budget.name} budget utilization"}
            />
          </div>
        </li>

        <li :if={Enum.empty?(@budgets)}
            class="rounded-lg border border-dashed border-zinc-200 p-6 text-center text-xs text-zinc-500 xl:col-span-2">
          Not enough activity yet.
        </li>
      </ul>

      <div class="grid gap-4 xl:grid-cols-2">
        <.budget_rollup_card
          title="Income vs. expenses"
          subtitle={"#{budget_period_label(@budget_period)} totals"}
          rollups={rollup_entries(@budget_rollups.entry_type, [:income, :expense])}
          show_balances?={@show_balances?}
          empty_message="Not enough activity yet."
        />

        <.budget_rollup_card
          title="Fixed vs. variable"
          subtitle={"#{budget_period_label(@budget_period)} mix"}
          rollups={rollup_entries(@budget_rollups.variability, [:fixed, :variable])}
          show_balances?={@show_balances?}
          empty_message="No variability insights yet."
        />
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  attr :rollups, :list, required: true
  attr :show_balances?, :boolean, required: true
  attr :empty_message, :string, required: true

  defp budget_rollup_card(assigns) do
    ~H"""
    <div class="space-y-3 rounded-lg border border-zinc-100 bg-zinc-50 p-4">
      <div class="flex items-center justify-between">
        <h4 class="text-sm font-semibold text-zinc-800"><%= @title %></h4>
        <span class="text-xs text-zinc-500"><%= @subtitle %></span>
      </div>

      <ul class="space-y-2 text-sm">
        <li :for={rollup <- @rollups}
            class="space-y-3 rounded-lg border border-zinc-200 bg-white p-3">
          <div class="flex items-center justify-between gap-3">
            <div class="min-w-0">
              <span class="font-medium text-zinc-900"><%= rollup.label %></span>
              <p class="text-xs text-zinc-500">Allocated vs actual vs projection</p>
            </div>
            <span class="shrink-0 text-xs text-zinc-500"><%= format_percent(rollup.utilization_percent) %> utilised</span>
          </div>

          <.comparison_bars
            allocated={rollup.allocated_decimal}
            actual={rollup.actual_decimal}
            projection={rollup.projection_decimal}
            label={rollup.label}
          />

          <div class="space-y-2">
            <.progress_meter
              width={rollup_progress_width(rollup.utilization_percent)}
              bar_class={rollup_progress_bar_class(rollup.variance_decimal)}
              label={"#{rollup.label} utilization"}
            />
            <p class={["text-xs font-medium", variance_class(rollup.variance_decimal)]}>
              Variance <%= visible_value(@show_balances?, rollup.variance, rollup.variance_masked) %>
            </p>
          </div>

          <dl class="grid gap-2 text-xs sm:grid-cols-2">
            <div class="flex items-center justify-between rounded-md bg-zinc-50 px-3 py-2">
              <dt class="text-zinc-500">Allocated</dt>
              <dd class="text-zinc-700">
                <%= visible_value(@show_balances?, rollup.allocated, rollup.allocated_masked) %>
              </dd>
            </div>
            <div class="flex items-center justify-between rounded-md bg-zinc-50 px-3 py-2">
              <dt class="text-zinc-500">Actual</dt>
              <dd class="text-zinc-700">
                <%= visible_value(@show_balances?, rollup.actual, rollup.actual_masked) %>
              </dd>
            </div>
            <div class="flex items-center justify-between rounded-md bg-zinc-50 px-3 py-2 sm:col-span-2">
              <dt class="text-zinc-500">Projection</dt>
              <dd class="text-zinc-700">
                <%= visible_value(@show_balances?, rollup.projection, rollup.projection_masked) %>
              </dd>
            </div>
          </dl>
        </li>

        <li :if={Enum.empty?(@rollups)} class="text-xs text-zinc-500"><%= @empty_message %></li>
      </ul>
    </div>
    """
  end

  attr :subscription, :map, required: true
  attr :show_balances?, :boolean, required: true

  defp subscriptions_panel(assigns) do
    ~H"""
    <div class="space-y-3 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
      <div class="flex items-start justify-between gap-3">
        <div>
          <h3 class="text-lg font-semibold text-zinc-900">Subscriptions</h3>
          <p class="text-xs text-zinc-500">30-day recurring-spend summary</p>
        </div>
        <span class="rounded-full bg-zinc-100 px-2 py-1 text-[11px] font-semibold uppercase tracking-wide text-zinc-500">
          30-day lookback
        </span>
      </div>

      <dl class="grid gap-3 text-sm">
        <div class="space-y-1 rounded-lg border border-zinc-100 bg-zinc-50 p-3">
          <dt class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Monthly total</dt>
          <dd class="text-lg font-semibold text-zinc-900">
            <%= visible_value(@show_balances?, @subscription.monthly_total, @subscription.monthly_total_masked) %>
          </dd>
        </div>
        <div class="space-y-1 rounded-lg border border-zinc-100 bg-zinc-50 p-3">
          <dt class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Annual projection</dt>
          <dd class="text-base font-medium text-zinc-700">
            <%= visible_value(@show_balances?, @subscription.annual_projection, @subscription.annual_projection_masked) %>
          </dd>
        </div>
      </dl>

      <div class="space-y-2">
        <h4 class="text-xs font-semibold uppercase tracking-wide text-zinc-500">Top merchants</h4>
        <ul class="space-y-1 text-sm">
          <li :for={merchant <- @subscription.top_merchants}
              class="flex items-center justify-between rounded-md bg-zinc-50 px-3 py-2">
            <span class="text-zinc-600"><%= merchant.merchant %></span>
            <span class="text-zinc-700">
              <%= visible_value(@show_balances?, merchant.spend, merchant.spend_masked) %>
            </span>
          </li>
          <li :if={Enum.empty?(@subscription.top_merchants)} class="text-xs text-zinc-500">No recurring spend detected.</li>
        </ul>
      </div>
    </div>
    """
  end

  attr :allocated, :any, required: true
  attr :actual, :any, required: true
  attr :projection, :any, required: true
  attr :label, :string, required: true

  defp comparison_bars(assigns) do
    max_value = max_decimal([assigns.allocated, assigns.actual, assigns.projection])

    assigns =
      assigns
      |> assign(:allocated_width, decimal_width(assigns.allocated, max_value))
      |> assign(:actual_width, decimal_width(assigns.actual, max_value))
      |> assign(:projection_width, decimal_width(assigns.projection, max_value))

    ~H"""
    <div class="space-y-2">
      <div class="space-y-1">
        <div class="flex items-center justify-between text-[11px] text-zinc-500">
          <span>Allocated</span>
          <span><%= @allocated_width %>%</span>
        </div>
        <.progress_meter width={@allocated_width} bar_class="h-full rounded-full bg-zinc-400 transition-all" label={"#{@label} allocated"} />
      </div>

      <div class="space-y-1">
        <div class="flex items-center justify-between text-[11px] text-zinc-500">
          <span>Actual</span>
          <span><%= @actual_width %>%</span>
        </div>
        <.progress_meter width={@actual_width} bar_class="h-full rounded-full bg-emerald-500 transition-all" label={"#{@label} actual"} />
      </div>

      <div class="space-y-1">
        <div class="flex items-center justify-between text-[11px] text-zinc-500">
          <span>Projection</span>
          <span><%= @projection_width %>%</span>
        </div>
        <.progress_meter width={@projection_width} bar_class="h-full rounded-full bg-amber-500 transition-all" label={"#{@label} projection"} />
      </div>
    </div>
    """
  end

  attr :width, :integer, required: true
  attr :bar_class, :string, required: true
  attr :label, :string, required: true

  defp progress_meter(assigns) do
    ~H"""
    <div class="h-2 overflow-hidden rounded-full bg-zinc-200">
      <div class={@bar_class}
           style={"width: #{@width}%"}
           role="progressbar"
           aria-valuemin="0"
           aria-valuemax="100"
           aria-valuenow={@width}
           aria-label={@label} />
    </div>
    """
  end

  defp visible_value(_show?, nil, _masked), do: "--"
  defp visible_value(true, value, _masked), do: value
  defp visible_value(false, _value, masked), do: masked || "••"

  defp reset_asset_form(socket) do
    assign(socket,
      asset_form_open?: false,
      asset_form_mode: :new,
      asset_editing_asset: nil,
      asset_changeset: Assets.change_asset(%Asset{})
    )
  end

  defp maybe_reset_form_for_deleted(socket, asset_id) do
    deleted_id = to_string(asset_id)

    case socket.assigns.asset_editing_asset do
      %Asset{id: ^deleted_id} -> reset_asset_form(socket)
      _ -> socket
    end
  end

  defp asset_account_options(accounts) do
    Enum.map(accounts, fn account ->
      label =
        case account.currency do
          nil -> account.name
          currency -> "#{account.name} (#{currency})"
        end

      {label, account.id}
    end)
  end

  defp format_input_date(nil), do: nil
  defp format_input_date(%Date{} = date), do: Date.to_iso8601(date)

  defp format_input_date(%NaiveDateTime{} = datetime) do
    datetime
    |> NaiveDateTime.to_date()
    |> Date.to_iso8601()
  end

  defp format_input_date(value) when is_binary(value) and value != "", do: value
  defp format_input_date(_), do: nil

  defp errors_on(%Ecto.Changeset{} = changeset, field) do
    changeset
    |> Map.get(:errors)
    |> Keyword.get_values(field)
    |> Enum.map(&CoreComponents.translate_error/1)
  end

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

  defp budget_periods, do: @budget_periods

  defp budget_period_label(period) do
    case period do
      :weekly -> "Weekly"
      :monthly -> "Monthly"
      :yearly -> "Yearly"
      other when is_binary(other) -> other |> String.replace("_", " ") |> String.capitalize()
      _ -> "Custom"
    end
  end

  defp budget_period_button_class(period, current) do
    base =
      "inline-flex items-center rounded-full border px-3 py-1 text-xs font-semibold transition-colors"

    if period == current do
      base <> " border-emerald-500 bg-emerald-500 text-white"
    else
      base <> " border-zinc-200 text-zinc-600 hover:border-emerald-400 hover:text-emerald-600"
    end
  end

  defp budget_period_value(period) when is_atom(period), do: Atom.to_string(period)
  defp budget_period_value(period), do: period

  defp connected_account_count(%{accounts: accounts}) when is_list(accounts), do: length(accounts)
  defp connected_account_count(_), do: 0

  defp upcoming_due_count(loans) when is_list(loans) do
    today = Date.utc_today()
    cutoff = Date.add(today, 7)

    Enum.count(loans, fn
      %{next_due_date: %Date{} = due_date} ->
        Date.compare(due_date, today) != :lt and Date.compare(due_date, cutoff) != :gt

      _ ->
        false
    end)
  end

  defp upcoming_due_count(_), do: 0

  defp net_worth_segments(%{
         assets_decimal: %Decimal{} = assets,
         liabilities_decimal: %Decimal{} = liabilities
       }) do
    build_segments([
      %{label: "Assets", value: assets, color: "#10b981"},
      %{label: "Liabilities", value: liabilities, color: "#f43f5e"}
    ])
  end

  defp net_worth_segments(_), do: []

  defp savings_segments(%{
         savings_total_decimal: %Decimal{} = savings,
         investment_total_decimal: %Decimal{} = investments
       }) do
    build_segments([
      %{label: "Savings", value: savings, color: "#10b981"},
      %{label: "Investments", value: investments, color: "#0ea5e9"}
    ])
  end

  defp savings_segments(_), do: []

  defp build_segments(segments) do
    total =
      segments
      |> Enum.map(&Map.fetch!(&1, :value))
      |> Enum.reduce(Decimal.new("0"), &Decimal.add/2)

    if Decimal.compare(total, Decimal.new("0")) in [:eq, :lt] do
      []
    else
      segments
      |> Enum.map(fn %{value: %Decimal{} = value} = segment ->
        Map.put(segment, :percent, decimal_width(value, total))
      end)
      |> normalize_segment_percentages()
    end
  end

  defp normalize_segment_percentages([]), do: []

  defp normalize_segment_percentages(segments) do
    sum = Enum.reduce(segments, 0, fn segment, acc -> acc + segment.percent end)

    case sum do
      100 ->
        segments

      _ when sum < 100 ->
        List.update_at(segments, 0, fn segment ->
          Map.update!(segment, :percent, &(&1 + (100 - sum)))
        end)

      _ ->
        overflow = sum - 100

        List.update_at(segments, 0, fn segment ->
          Map.update!(segment, :percent, &max(0, &1 - overflow))
        end)
    end
  end

  defp rollup_entries(nil, _order), do: []

  defp rollup_entries(rollups, order) do
    order
    |> Enum.map(&Map.get(rollups, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp budget_progress_percent(%{allocated: %Decimal{} = allocated, spent: %Decimal{} = spent}) do
    if Decimal.compare(allocated, Decimal.new("0")) in [:eq, :lt] do
      nil
    else
      spent
      |> Decimal.div(allocated)
      |> Decimal.mult(Decimal.new("100"))
      |> Decimal.round(2)
    end
  rescue
    _ -> nil
  end

  defp budget_progress_percent(_), do: nil

  defp budget_progress_width(budget) do
    budget
    |> budget_progress_percent()
    |> clamp_percent()
  end

  defp rollup_progress_width(%Decimal{} = percent), do: clamp_percent(percent)
  defp rollup_progress_width(_), do: 0

  defp max_decimal(decimals) do
    Enum.reduce(decimals, Decimal.new("0"), fn
      %Decimal{} = value, acc -> Decimal.max(value, acc)
      _, acc -> acc
    end)
  end

  defp decimal_width(%Decimal{} = value, %Decimal{} = max_value) do
    cond do
      Decimal.compare(max_value, Decimal.new("0")) in [:eq, :lt] ->
        0

      true ->
        value
        |> Decimal.div(max_value)
        |> Decimal.mult(Decimal.new("100"))
        |> clamp_percent()
    end
  rescue
    _ -> 0
  end

  defp decimal_width(_, _), do: 0

  defp clamp_percent(%Decimal{} = percent) do
    percent
    |> Decimal.max(Decimal.new("0"))
    |> Decimal.min(Decimal.new("100"))
    |> Decimal.round(0)
    |> Decimal.to_integer()
  end

  defp clamp_percent(_), do: 0

  defp budget_progress_bar_class(:over), do: "h-full rounded-full bg-rose-500 transition-all"

  defp budget_progress_bar_class(:approaching),
    do: "h-full rounded-full bg-amber-500 transition-all"

  defp budget_progress_bar_class(_), do: "h-full rounded-full bg-emerald-500 transition-all"

  defp rollup_progress_bar_class(%Decimal{} = value) do
    case Decimal.compare(value, Decimal.new("0")) do
      :lt -> "h-full rounded-full bg-rose-500 transition-all"
      :gt -> "h-full rounded-full bg-emerald-500 transition-all"
      _ -> "h-full rounded-full bg-zinc-400 transition-all"
    end
  end

  defp rollup_progress_bar_class(_), do: "h-full rounded-full bg-zinc-400 transition-all"

  defp card_utilization_bar_class(%Decimal{} = percent) do
    case Decimal.compare(percent, Decimal.new("90")) do
      :gt ->
        "h-full rounded-full bg-rose-500 transition-all"

      _ ->
        case Decimal.compare(percent, Decimal.new("70")) do
          :gt -> "h-full rounded-full bg-amber-500 transition-all"
          _ -> "h-full rounded-full bg-emerald-500 transition-all"
        end
    end
  end

  defp card_utilization_bar_class(_), do: "h-full rounded-full bg-zinc-400 transition-all"

  defp card_utilization_badge_class(%Decimal{} = percent) do
    base = "shrink-0 rounded-full px-2 py-1 text-[11px] font-semibold uppercase tracking-wide"

    case Decimal.compare(percent, Decimal.new("90")) do
      :gt ->
        base <> " bg-rose-100 text-rose-700"

      _ ->
        case Decimal.compare(percent, Decimal.new("70")) do
          :gt -> base <> " bg-amber-100 text-amber-700"
          _ -> base <> " bg-emerald-100 text-emerald-700"
        end
    end
  end

  defp card_utilization_badge_class(_),
    do:
      "shrink-0 rounded-full bg-zinc-100 px-2 py-1 text-[11px] font-semibold uppercase tracking-wide text-zinc-500"

  defp autopay_badge_class(true),
    do:
      "shrink-0 rounded-full bg-emerald-100 px-2 py-1 text-[11px] font-semibold uppercase tracking-wide text-emerald-700"

  defp autopay_badge_class(false),
    do:
      "shrink-0 rounded-full bg-rose-100 px-2 py-1 text-[11px] font-semibold uppercase tracking-wide text-rose-700"

  defp autopay_bar_class(true), do: "h-full rounded-full bg-emerald-500 transition-all"
  defp autopay_bar_class(false), do: "h-full rounded-full bg-rose-500 transition-all"

  defp notification_severity_badge_class(:warning),
    do:
      "shrink-0 rounded-full bg-amber-100 px-2 py-1 text-[11px] font-semibold uppercase tracking-wide text-amber-700"

  defp notification_severity_badge_class(:danger),
    do:
      "shrink-0 rounded-full bg-rose-100 px-2 py-1 text-[11px] font-semibold uppercase tracking-wide text-rose-700"

  defp notification_severity_badge_class(:error),
    do:
      "shrink-0 rounded-full bg-rose-100 px-2 py-1 text-[11px] font-semibold uppercase tracking-wide text-rose-700"

  defp notification_severity_badge_class(:success),
    do:
      "shrink-0 rounded-full bg-emerald-100 px-2 py-1 text-[11px] font-semibold uppercase tracking-wide text-emerald-700"

  defp notification_severity_badge_class(_),
    do:
      "shrink-0 rounded-full bg-zinc-100 px-2 py-1 text-[11px] font-semibold uppercase tracking-wide text-zinc-600"

  defp toolbar_status_badge_class(:active),
    do:
      "rounded-full bg-emerald-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-emerald-700"

  defp toolbar_status_badge_class(:locked),
    do:
      "rounded-full bg-amber-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-amber-700"

  defp toolbar_status_badge_class(:visible),
    do:
      "rounded-full bg-sky-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-sky-700"

  defp toolbar_status_badge_class(:masked),
    do:
      "rounded-full bg-zinc-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-zinc-600"

  defp variance_class(%Decimal{} = value) do
    case Decimal.compare(value, Decimal.new("0")) do
      :lt -> "text-rose-600"
      :gt -> "text-emerald-600"
      _ -> "text-zinc-600"
    end
  end

  defp variance_class(_), do: "text-zinc-600"

  defp parse_budget_period(value) when is_atom(value) do
    if value in @budget_periods do
      {:ok, value}
    else
      :error
    end
  end

  defp parse_budget_period(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    if normalized == "" do
      :error
    else
      try do
        normalized |> String.to_existing_atom() |> parse_budget_period()
      rescue
        ArgumentError -> :error
      end
    end
  end

  defp parse_budget_period(_), do: :error

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
