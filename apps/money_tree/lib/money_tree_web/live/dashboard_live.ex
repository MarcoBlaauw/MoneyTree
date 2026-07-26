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
  alias MoneyTree.Evaluations
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
    <section class="space-y-6">
      <.header title="Dashboard" subtitle="Monitor balances and recent activity.">
        <:actions>
          <.link navigate={~p"/app/notifications"}
                 class="relative inline-flex h-9 w-9 items-center justify-center rounded-lg border border-zinc-200 bg-white text-zinc-700 shadow-sm hover:bg-zinc-100"
                 aria-label="Open notifications"
                 title="Open notifications">
            <.notification_bell_icon />
            <span :if={length(@metrics.notifications) > 0}
                  class="absolute -right-1 -top-1 inline-flex h-5 min-w-5 items-center justify-center rounded-full bg-emerald-500 px-1 text-[11px] font-semibold text-white">
              <%= length(@metrics.notifications) %>
            </span>
          </.link>
        </:actions>
      </.header>

      <.dashboard_toolbar locked?={@locked?} show_balances?={@show_balances?} />

      <.kpi_strip
        show_balances?={@show_balances?}
        metrics={@metrics}
        summary={@summary}
        asset_summary={@asset_summary}
      />

      <div class="grid gap-6 xl:grid-cols-[minmax(0,2.1fr)_minmax(22rem,0.95fr)] xl:items-start">
        <div class="min-w-0 space-y-6">
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

          <.account_category_snapshot_panel
            metrics={@metrics}
            asset_summary={@asset_summary}
            show_balances?={@show_balances?}
          />
        </div>

        <div class="min-w-0 space-y-6 xl:sticky xl:top-4">
          <.needs_attention_panel items={dashboard_attention_items(@metrics)} />

          <.subscriptions_panel
            subscription={@metrics.subscription}
            show_balances?={@show_balances?}
          />

          <.evaluation_status_panel evaluation_summary={@metrics.evaluation_summary} />
        </div>
      </div>

      <div class="grid gap-6 lg:grid-cols-2">
        <.recent_activity_panel
          transactions={recent_dashboard_transactions(@metrics)}
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
      evaluation_summary: Evaluations.status_summary(current_user),
      category_rollups: Transactions.category_rollups(current_user),
      recent_transactions: Transactions.recent_with_color(current_user, limit: 5),
      notifications: Notifications.pending(current_user, budget_opts)
    }
  end

  defp recent_dashboard_transactions(%{recent_transactions: transactions})
       when is_list(transactions) do
    Enum.take(transactions, 5)
  end

  defp recent_dashboard_transactions(_metrics), do: []

  defp dashboard_attention_items(metrics) do
    metrics
    |> notification_attention_items()
    |> Kernel.++(evaluation_attention_items(metrics))
    |> Enum.take(5)
  end

  defp notification_attention_items(%{notifications: notifications})
       when is_list(notifications) do
    Enum.map(notifications, fn notification ->
      %{
        source: :notification,
        source_label: "Notification",
        title:
          Map.get(notification, :title) || Map.get(notification, :message) ||
            "Notification needs review",
        summary: notification_summary(notification),
        severity: Map.get(notification, :severity) || "info",
        action: Map.get(notification, :action) || "Open",
        route: ~p"/app/notifications"
      }
    end)
  end

  defp notification_attention_items(_metrics), do: []

  defp notification_summary(%{title: title, message: message}) when is_binary(title), do: message
  defp notification_summary(_notification), do: nil

  defp evaluation_attention_items(%{evaluation_summary: %{items: items}}) when is_list(items) do
    Enum.map(items, fn item ->
      %{
        source: :evaluation,
        source_label: "Evaluation",
        title: Map.get(item, :title) || "Evaluation needs review",
        summary: Map.get(item, :summary),
        severity: Map.get(item, :severity) || "info",
        action: "Review",
        route: "/app/evaluations"
      }
    end)
  end

  defp evaluation_attention_items(_metrics), do: []

  defp dashboard_snapshot_cards(show_balances?, metrics, _summary, _asset_summary) do
    [
      %{
        label: "Net worth",
        value:
          visible_value(
            show_balances?,
            metrics.net_worth.net_worth,
            metrics.net_worth.net_worth_masked
          ),
        hint: "Household balance snapshot"
      },
      %{
        label: "Cash & savings",
        value:
          visible_value(
            show_balances?,
            metrics.savings.combined_total,
            metrics.savings.combined_total_masked
          ),
        hint: "Savings and investment reserves"
      },
      %{
        label: "Budget status",
        value: budget_snapshot_value(metrics.budgets),
        hint: budget_snapshot_hint(metrics.budgets)
      },
      %{
        label: "Credit cards",
        value: credit_card_snapshot_value(metrics.card_balances),
        hint: credit_card_snapshot_hint(metrics.card_balances)
      },
      %{
        label: "Due soon",
        value: upcoming_due_count(metrics.loans),
        hint: "Loan payments due in 7 days"
      },
      %{
        label: "Needs review",
        value: needs_review_count(metrics),
        hint: "Alerts and evaluation prompts"
      }
    ]
  end

  defp budget_snapshot_value(budgets) when is_list(budgets) do
    budgets
    |> budget_summary_status()
    |> budget_status_label()
  end

  defp budget_snapshot_value(_budgets), do: "No budgets"

  defp budget_snapshot_hint(budgets) when is_list(budgets) do
    watched = length(budgets)
    over = Enum.count(budgets, &(&1.status == :over))
    approaching = Enum.count(budgets, &(&1.status == :approaching))

    cond do
      watched == 0 -> "Create budgets to track spend"
      over > 0 -> "#{over} over budget"
      approaching > 0 -> "#{approaching} near limit"
      true -> "#{watched} categories watched"
    end
  end

  defp budget_snapshot_hint(_budgets), do: "Create budgets to track spend"

  defp budget_dashboard_summary(budgets, show_balances?) when is_list(budgets) do
    currency = budgets |> List.first() |> then(&(&1 && &1.currency)) || "USD"
    allocated = sum_budget_decimal(budgets, :allocated_decimal)
    spent = sum_budget_decimal(budgets, :spent_decimal)
    remaining = sum_budget_decimal(budgets, :remaining_decimal)

    %{
      allocated:
        visible_value(
          show_balances?,
          Accounts.format_money(allocated, currency, []),
          Accounts.mask_money(allocated, currency, [])
        ),
      spent:
        visible_value(
          show_balances?,
          Accounts.format_money(spent, currency, []),
          Accounts.mask_money(spent, currency, [])
        ),
      remaining:
        visible_value(
          show_balances?,
          Accounts.format_money(remaining, currency, []),
          Accounts.mask_money(remaining, currency, [])
        ),
      remaining_decimal: remaining,
      watch_count: budgets |> budget_watchlist() |> length(),
      status: budget_summary_status(budgets)
    }
  end

  defp budget_dashboard_summary(_budgets, show_balances?) do
    budget_dashboard_summary([], show_balances?)
  end

  defp budget_watchlist(budgets) when is_list(budgets) do
    budgets
    |> Enum.filter(&(&1.status in [:over, :approaching]))
    |> Enum.take(3)
  end

  defp budget_watchlist(_budgets), do: []

  defp budget_summary_status([]), do: :none

  defp budget_summary_status(budgets) do
    cond do
      Enum.any?(budgets, &(&1.status == :over)) -> :over
      Enum.any?(budgets, &(&1.status == :approaching)) -> :approaching
      true -> :healthy
    end
  end

  defp sum_budget_decimal(budgets, field) do
    Enum.reduce(budgets, Decimal.new("0"), fn budget, total ->
      case Map.get(budget, field) do
        %Decimal{} = value -> Decimal.add(total, value)
        _ -> total
      end
    end)
  end

  defp credit_card_snapshot_value(card_balances) when is_list(card_balances) do
    card_balances
    |> Enum.map(& &1.utilization_percent)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        length(card_balances)

      utilization_values ->
        utilization_values
        |> Enum.reduce(Decimal.new("0"), &Decimal.max/2)
        |> format_percent()
    end
  end

  defp credit_card_snapshot_value(_card_balances), do: 0

  defp credit_card_snapshot_hint(card_balances) when is_list(card_balances) do
    case card_balances do
      [] -> "No active cards detected"
      [_single] -> "Highest utilization"
      _many -> "Highest utilization across cards"
    end
  end

  defp credit_card_snapshot_hint(_card_balances), do: "No active cards detected"

  defp needs_review_count(metrics) do
    length(notification_attention_items(metrics)) +
      evaluation_action_count(metrics.evaluation_summary)
  end

  defp dashboard_asset_summary(asset_summary) do
    asset_count = Map.get(asset_summary, :total_count, 0)
    assets = Map.get(asset_summary, :assets, [])

    %{
      empty: Enum.empty?(assets),
      count_label: "#{asset_count} assets tracked"
    }
  end

  defp account_category_rows(metrics, asset_summary, show_balances?) do
    [
      %{
        label: "Cash & reserves",
        value:
          visible_value(
            show_balances?,
            metrics.savings.combined_total,
            metrics.savings.combined_total_masked
          ),
        detail: account_count_label(savings_account_count(metrics.savings), "account"),
        route: ~p"/app/accounts"
      },
      %{
        label: "Credit cards",
        value: credit_card_snapshot_value(metrics.card_balances),
        detail: account_count_label(length(metrics.card_balances), "card"),
        route: ~p"/app/accounts"
      },
      %{
        label: "Loans",
        value: account_count_label(length(metrics.loans), "loan"),
        detail: "Balances and autopay live in Loan Center",
        route: ~p"/app/loans"
      },
      %{
        label: "Tangible assets",
        value: account_count_label(Map.get(asset_summary, :total_count, 0), "asset"),
        detail: asset_total_summary(asset_summary, show_balances?),
        route: ~p"/app/assets"
      }
    ]
  end

  defp savings_account_count(savings) do
    length(Map.get(savings, :savings_accounts, [])) +
      length(Map.get(savings, :investment_accounts, []))
  end

  defp account_count_label(1, singular), do: "1 #{singular}"
  defp account_count_label(count, singular) when is_integer(count), do: "#{count} #{singular}s"
  defp account_count_label(_count, singular), do: "0 #{singular}s"

  defp asset_total_summary(%{totals: [total | _totals]}, show_balances?) do
    visible_value(show_balances?, total.valuation, total.valuation_masked)
  end

  defp asset_total_summary(_asset_summary, _show_balances?), do: "No asset values tracked"

  attr :locked?, :boolean, required: true
  attr :show_balances?, :boolean, required: true

  defp dashboard_toolbar(assigns) do
    ~H"""
    <div class="rounded-xl border border-zinc-200 bg-white p-3 shadow-sm">
      <div class="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
        <div class="flex flex-wrap items-center gap-2">
          <p class="text-xs font-semibold uppercase tracking-wide text-zinc-500">Controls</p>
          <span class={toolbar_status_badge_class(if(@locked?, do: :locked, else: :active))}>
            <%= if @locked?, do: "Locked", else: "Active session" %>
          </span>
          <span class={toolbar_status_badge_class(if(@show_balances?, do: :visible, else: :masked))}>
            <%= if @show_balances?, do: "Balances visible", else: "Balances masked" %>
          </span>
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
    assigns =
      assign(
        assigns,
        :cards,
        dashboard_snapshot_cards(
          assigns.show_balances?,
          assigns.metrics,
          assigns.summary,
          assigns.asset_summary
        )
      )

    ~H"""
    <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-6">
      <.kpi_card
        :for={card <- @cards}
        label={card.label}
        value={card.value}
        hint={card.hint}
      />
    </div>
    """
  end

  attr :items, :list, required: true

  defp needs_attention_panel(assigns) do
    ~H"""
    <section class="space-y-3 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
      <div class="flex items-start justify-between gap-3">
        <div>
          <h3 class="text-lg font-semibold text-zinc-900">Needs attention</h3>
          <p class="text-xs text-zinc-500">Notifications and review prompts</p>
        </div>
        <span class="rounded-full bg-zinc-100 px-2 py-1 text-[11px] font-semibold uppercase tracking-wide text-zinc-500">
          <%= length(@items) %> shown
        </span>
      </div>

      <ul class="space-y-2">
        <li :for={item <- @items}
            class="rounded-lg border border-zinc-100 bg-zinc-50 p-3">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">
                <%= item.source_label %>
              </p>
              <p class="mt-1 font-medium text-zinc-900"><%= item.title %></p>
              <p :if={item.summary} class="mt-1 text-xs text-zinc-500"><%= item.summary %></p>
            </div>
            <span class={attention_severity_badge_class(item.severity)}>
              <%= item.severity %>
            </span>
          </div>

          <div class="mt-3 flex justify-end">
            <.link navigate={item.route} class="text-xs font-semibold text-emerald-700 hover:text-emerald-800">
              <%= item.action %>
            </.link>
          </div>
        </li>
        <li :if={Enum.empty?(@items)}
            class="rounded-lg border border-dashed border-zinc-200 p-3 text-sm text-zinc-500">
          Nothing needs attention right now.
        </li>
      </ul>
    </section>
    """
  end

  attr :evaluation_summary, :map, required: true

  defp evaluation_status_panel(assigns) do
    ~H"""
    <section class="space-y-4 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
      <div class="flex items-start justify-between gap-3">
        <div>
          <h3 class="text-lg font-semibold text-zinc-900">Evaluation status</h3>
          <p class="text-xs text-zinc-500">Missing facts, stale data, review queues, and expiring items</p>
        </div>
        <.link navigate="/app/evaluations" class="btn btn-outline">
          Open
        </.link>
      </div>

      <div class="grid gap-2 sm:grid-cols-2">
        <div :for={status <- evaluation_count_order()}
             class="rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-2">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">
            <%= evaluation_status_label(status) %>
          </p>
          <p class="mt-1 text-xl font-semibold text-zinc-900">
            <%= Map.get(@evaluation_summary.counts, status, 0) %>
          </p>
        </div>
      </div>

      <ul class="space-y-2">
        <li :for={item <- Enum.take(@evaluation_summary.items, 3)}
            class="rounded-lg border border-zinc-100 bg-zinc-50 p-3">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="font-medium text-zinc-900"><%= item.title %></p>
              <p class="mt-1 text-xs text-zinc-500"><%= item.summary %></p>
            </div>
            <span class={evaluation_severity_badge_class(item.severity)}>
              <%= item.severity %>
            </span>
          </div>
        </li>
        <li :if={Enum.empty?(@evaluation_summary.items)}
            class="rounded-lg border border-dashed border-zinc-200 p-3 text-sm text-zinc-500">
          No evaluation items need attention right now.
        </li>
      </ul>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, required: true

  defp kpi_card(assigns) do
    ~H"""
    <div class="flex min-h-[7rem] flex-col justify-between rounded-xl border border-zinc-200 bg-white p-3 shadow-sm">
      <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500"><%= @label %></p>
      <p class="mt-2 text-xl font-semibold text-zinc-900"><%= @value %></p>
      <p class="mt-1 text-xs leading-5 text-zinc-500"><%= @hint %></p>
    </div>
    """
  end

  attr :metrics, :map, required: true
  attr :asset_summary, :map, required: true
  attr :show_balances?, :boolean, required: true

  defp account_category_snapshot_panel(assigns) do
    assigns =
      assign(
        assigns,
        :rows,
        account_category_rows(assigns.metrics, assigns.asset_summary, assigns.show_balances?)
      )

    ~H"""
    <section class="space-y-4 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
      <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h3 class="text-lg font-semibold text-zinc-900">Account snapshot</h3>
          <p class="text-xs text-zinc-500">Category-level account composition</p>
        </div>
        <.link navigate={~p"/app/accounts"} class="btn btn-outline">
          Open accounts
        </.link>
      </div>

      <div class="grid gap-3 sm:grid-cols-2">
        <div :for={row <- @rows}
             class="rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-2.5">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="text-sm font-semibold text-zinc-900"><%= row.label %></p>
              <p class="mt-1 text-xs text-zinc-500"><%= row.detail %></p>
            </div>
            <.link navigate={row.route} class="text-xs font-semibold text-emerald-700 hover:text-emerald-800">
              Open
            </.link>
          </div>
          <p class="mt-2 text-lg font-semibold text-zinc-900"><%= row.value %></p>
        </div>
      </div>
    </section>
    """
  end

  defp notification_bell_icon(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24"
         class="h-4 w-4"
         fill="none"
         stroke="currentColor"
         stroke-width="2"
         stroke-linecap="round"
         stroke-linejoin="round"
         aria-hidden="true">
      <path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9" />
      <path d="M13.73 21a2 2 0 0 1-3.46 0" />
    </svg>
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
        <.link navigate={~p"/app/transactions"} class="text-xs font-semibold text-emerald-700 hover:text-emerald-800">
          View all transactions
        </.link>
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

  attr :asset_summary, :map, required: true
  attr :asset_accounts, :list, required: true
  attr :asset_form_open?, :boolean, required: true
  attr :asset_form_mode, :atom, required: true
  attr :asset_changeset, :any, required: true
  attr :asset_editing_asset, :any, required: true
  attr :show_balances?, :boolean, required: true

  defp assets_panel(assigns) do
    assigns = assign(assigns, :asset_view, dashboard_asset_summary(assigns.asset_summary))

    ~H"""
    <div :if={@asset_view.empty and not @asset_form_open?}
         class="rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h3 class="text-lg font-semibold text-zinc-900">Tangible assets</h3>
          <p class="text-xs text-zinc-500">
            No tangible assets are tracked yet.
          </p>
        </div>
        <.link navigate={~p"/app/assets"} class="btn btn-outline">
          Open assets
        </.link>
      </div>
    </div>

    <div :if={not @asset_view.empty or @asset_form_open?}
         class="space-y-4 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
      <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h3 class="text-lg font-semibold text-zinc-900">Tangible assets</h3>
          <p class="text-xs text-zinc-500">
            Track real estate, vehicles, collectibles, and other tangible holdings.
          </p>
        </div>
        <div class="flex items-center gap-2">
          <span class="text-xs text-zinc-500"><%= @asset_view.count_label %></span>
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

  attr :budgets, :list, required: true
  attr :planner_recommendations, :list, required: true
  attr :budget_rollups, :map, required: true
  attr :budget_period, :atom, required: true
  attr :show_balances?, :boolean, required: true

  defp budget_pulse_panel(assigns) do
    assigns =
      assigns
      |> assign(
        :budget_summary,
        budget_dashboard_summary(assigns.budgets, assigns.show_balances?)
      )
      |> assign(:budget_watchlist, budget_watchlist(assigns.budgets))

    ~H"""
    <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
      <div class="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
        <div>
          <h3 class="text-lg font-semibold text-zinc-900">Budget pulse</h3>
          <p class="text-xs text-zinc-500"><%= budget_period_label(@budget_period) %> overview</p>
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

      <div class="grid gap-3 md:grid-cols-4">
        <div class="min-h-[5.5rem] rounded-lg border border-zinc-100 bg-zinc-50 p-3">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Planned</p>
          <p class="mt-1 text-lg font-semibold text-zinc-900"><%= @budget_summary.allocated %></p>
        </div>
        <div class="min-h-[5.5rem] rounded-lg border border-zinc-100 bg-zinc-50 p-3">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Actual</p>
          <p class="mt-1 text-lg font-semibold text-zinc-900"><%= @budget_summary.spent %></p>
        </div>
        <div class="min-h-[5.5rem] rounded-lg border border-zinc-100 bg-zinc-50 p-3">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Remaining</p>
          <p class={["mt-1 text-lg font-semibold", variance_class(@budget_summary.remaining_decimal)]}>
            <%= @budget_summary.remaining %>
          </p>
        </div>
        <div class="min-h-[5.5rem] rounded-lg border border-zinc-100 bg-zinc-50 p-3">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Watchlist</p>
          <p class="mt-1 text-lg font-semibold text-zinc-900"><%= @budget_summary.watch_count %></p>
        </div>
      </div>

      <div class="grid gap-3 lg:grid-cols-[minmax(0,1fr)_minmax(16rem,0.45fr)]">
        <div class="rounded-lg border border-zinc-100 bg-zinc-50 p-3">
          <div class="flex items-center justify-between gap-3">
            <div>
              <h4 class="text-sm font-semibold text-zinc-800">Budget watchlist</h4>
              <p class="text-xs text-zinc-500">Categories near or over limit</p>
            </div>
            <span class={budget_badge_class(@budget_summary.status)}>
              <%= budget_status_label(@budget_summary.status) %>
            </span>
          </div>

          <ul class="mt-3 space-y-2">
            <li :for={budget <- @budget_watchlist}
                class="flex items-center justify-between gap-3 rounded-md bg-white px-3 py-2 text-sm">
              <span class="font-medium text-zinc-900"><%= budget.name %></span>
              <span class={budget_badge_class(budget.status)}><%= budget_status_label(budget.status) %></span>
            </li>
            <li :if={Enum.empty?(@budget_watchlist)} class="text-sm text-zinc-500">
              No categories need attention.
            </li>
          </ul>
        </div>

        <div class="rounded-lg border border-emerald-100 bg-emerald-50 p-3">
          <div class="flex items-start justify-between gap-3">
            <div>
              <h4 class="text-sm font-semibold text-emerald-900">Planner</h4>
              <p class="text-xs text-emerald-800">
                <%= length(@planner_recommendations) %> recommendations available.
              </p>
            </div>
            <.link navigate={~p"/app/budgets"} class="text-xs font-semibold text-emerald-800 hover:text-emerald-900">
              Open budgets
            </.link>
          </div>
        </div>
      </div>

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
              <p class="text-xs text-zinc-500">Actual, projection, and variance</p>
            </div>
            <span class="shrink-0 text-xs text-zinc-500"><%= format_percent(rollup.utilization_percent) %> utilised</span>
          </div>

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
            <div class="flex items-center justify-between rounded-md bg-zinc-50 px-3 py-2 sm:col-span-2">
              <dt class="text-zinc-500">Variance</dt>
              <dd class={["font-medium", variance_class(rollup.variance_decimal)]}>
                <%= visible_value(@show_balances?, rollup.variance, rollup.variance_masked) %>
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

  defp rollup_entries(nil, _order), do: []

  defp rollup_entries(rollups, order) do
    order
    |> Enum.map(&Map.get(rollups, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp rollup_progress_width(%Decimal{} = percent), do: clamp_percent(percent)
  defp rollup_progress_width(_), do: 0

  defp clamp_percent(%Decimal{} = percent) do
    percent
    |> Decimal.max(Decimal.new("0"))
    |> Decimal.min(Decimal.new("100"))
    |> Decimal.round(0)
    |> Decimal.to_integer()
  end

  defp rollup_progress_bar_class(%Decimal{} = value) do
    case Decimal.compare(value, Decimal.new("0")) do
      :lt -> "h-full rounded-full bg-rose-500 transition-all"
      :gt -> "h-full rounded-full bg-emerald-500 transition-all"
      _ -> "h-full rounded-full bg-zinc-400 transition-all"
    end
  end

  defp rollup_progress_bar_class(_), do: "h-full rounded-full bg-zinc-400 transition-all"

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

  defp evaluation_count_order do
    ["needs_review", "incomplete", "stale", "expiring", "opportunity"]
  end

  defp evaluation_action_count(%{counts: counts}) when is_map(counts) do
    counts
    |> Map.take(evaluation_count_order())
    |> Map.values()
    |> Enum.sum()
  end

  defp evaluation_action_count(_summary), do: 0

  defp evaluation_status_label("needs_review"), do: "Needs review"

  defp evaluation_status_label(status) when is_binary(status) do
    status
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp evaluation_severity_badge_class("critical") do
    "shrink-0 rounded-full bg-rose-100 px-2 py-1 text-[11px] font-semibold uppercase tracking-wide text-rose-700"
  end

  defp evaluation_severity_badge_class("warning") do
    "shrink-0 rounded-full bg-amber-100 px-2 py-1 text-[11px] font-semibold uppercase tracking-wide text-amber-700"
  end

  defp evaluation_severity_badge_class(_severity) do
    "shrink-0 rounded-full bg-sky-100 px-2 py-1 text-[11px] font-semibold uppercase tracking-wide text-sky-700"
  end

  defp attention_severity_badge_class(severity), do: evaluation_severity_badge_class(severity)

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

  defp format_date(%Date{} = date) do
    Calendar.strftime(date, "%b %d, %Y")
  end

  defp budget_badge_class(:over),
    do:
      "inline-flex items-center rounded bg-rose-100 px-2 py-0.5 text-xs font-semibold text-rose-700"

  defp budget_badge_class(:approaching),
    do:
      "inline-flex items-center rounded bg-amber-100 px-2 py-0.5 text-xs font-semibold text-amber-700"

  defp budget_badge_class(:none),
    do:
      "inline-flex items-center rounded bg-zinc-100 px-2 py-0.5 text-xs font-semibold text-zinc-600"

  defp budget_badge_class(_),
    do:
      "inline-flex items-center rounded bg-emerald-100 px-2 py-0.5 text-xs font-semibold text-emerald-700"

  defp budget_status_label(:none), do: "No budgets"
  defp budget_status_label(:over), do: "Over"
  defp budget_status_label(:approaching), do: "Near limit"
  defp budget_status_label(_), do: "Healthy"
end
