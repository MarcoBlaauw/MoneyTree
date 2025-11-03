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
        %{assigns: %{current_user: current_user, asset_form_mode: :edit, asset_editing_asset: %Asset{} = asset}} =
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

                <div class="grid gap-1 text-xs text-zinc-500 sm:grid-cols-2">
                  <div :if={summary.apr} class="flex items-center justify-between">
                    <span>APR</span>
                    <span class="text-zinc-700"><%= summary.apr %></span>
                  </div>

                  <div :if={summary.minimum_balance} class="flex items-center justify-between">
                    <span>Min balance</span>
                    <span class="text-zinc-700">
                      <%=
                        visible_value(
                          @show_balances?,
                          summary.minimum_balance,
                          summary.minimum_balance_masked
                        )
                      %>
                    </span>
                  </div>

                  <div :if={summary.maximum_balance} class="flex items-center justify-between">
                    <span>Max balance</span>
                    <span class="text-zinc-700">
                      <%=
                        visible_value(
                          @show_balances?,
                          summary.maximum_balance,
                          summary.maximum_balance_masked
                        )
                      %>
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
                <button id="new-asset"
                        phx-click="new-asset"
                        type="button"
                        class="btn btn-outline">
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

            <div :if={@asset_form_open?} class="space-y-3 rounded-lg border border-zinc-100 bg-white p-4">
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
                    <select id="asset_account_id"
                            name="asset[account_id]"
                            class="input">
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

          <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div>
                <h3 class="text-lg font-semibold text-zinc-900">Budget pulse</h3>
                <p class="text-xs text-zinc-500"><%= budget_period_label(@budget_period) %> insights</p>
              </div>
              <div class="flex items-center gap-2">
                <button :for={period <- budget_periods()}
                        type="button"
                        class={budget_period_button_class(period, @budget_period)}
                        phx-click="change-budget-period"
                        phx-value-period={budget_period_value(period)}>
                  <%= budget_period_label(period) %>
                </button>
              </div>
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

              <li :if={Enum.empty?(@metrics.budgets)} class="rounded-lg border border-dashed border-zinc-200 p-6 text-center text-xs text-zinc-500">Not enough activity yet.</li>
            </ul>

            <div class="grid gap-4 md:grid-cols-2">
              <div class="space-y-3 rounded-lg border border-zinc-100 bg-zinc-50 p-4">
                <div class="flex items-center justify-between">
                  <h4 class="text-sm font-semibold text-zinc-800">Income vs. expenses</h4>
                  <span class="text-xs text-zinc-500"><%= budget_period_label(@budget_period) %> totals</span>
                </div>

                <ul class="space-y-2 text-sm">
                  <li :for={rollup <- rollup_entries(@metrics.budget_rollups.entry_type, [:income, :expense])}
                      class="rounded-lg border border-zinc-200 bg-white p-3">
                    <div class="flex items-center justify-between">
                      <span class="font-medium text-zinc-900"><%= rollup.label %></span>
                      <span class="text-xs text-zinc-500"><%= format_percent(rollup.utilization_percent) %> utilised</span>
                    </div>

                    <dl class="mt-2 space-y-1 text-xs">
                      <div class="flex items-center justify-between">
                        <dt class="text-zinc-500">Allocated</dt>
                        <dd class="text-zinc-700">
                          <%= visible_value(@show_balances?, rollup.allocated, rollup.allocated_masked) %>
                        </dd>
                      </div>
                      <div class="flex items-center justify-between">
                        <dt class="text-zinc-500">Actual</dt>
                        <dd class="text-zinc-700">
                          <%= visible_value(@show_balances?, rollup.actual, rollup.actual_masked) %>
                        </dd>
                      </div>
                      <div class="flex items-center justify-between">
                        <dt class="text-zinc-500">Projection</dt>
                        <dd class="text-zinc-700">
                          <%= visible_value(@show_balances?, rollup.projection, rollup.projection_masked) %>
                        </dd>
                      </div>
                      <div class="flex items-center justify-between">
                        <dt class="text-zinc-500">Variance</dt>
                        <dd class={variance_class(rollup.variance_decimal)}>
                          <%= visible_value(@show_balances?, rollup.variance, rollup.variance_masked) %>
                        </dd>
                      </div>
                    </dl>
                  </li>

                  <li :if={Enum.empty?(rollup_entries(@metrics.budget_rollups.entry_type, [:income, :expense]))}
                      class="text-xs text-zinc-500">Not enough activity yet.</li>
                </ul>
              </div>

              <div class="space-y-3 rounded-lg border border-zinc-100 bg-zinc-50 p-4">
                <div class="flex items-center justify-between">
                  <h4 class="text-sm font-semibold text-zinc-800">Fixed vs. variable</h4>
                  <span class="text-xs text-zinc-500"><%= budget_period_label(@budget_period) %> mix</span>
                </div>

                <ul class="space-y-2 text-sm">
                  <li :for={rollup <- rollup_entries(@metrics.budget_rollups.variability, [:fixed, :variable])}
                      class="rounded-lg border border-zinc-200 bg-white p-3">
                    <div class="flex items-center justify-between">
                      <span class="font-medium text-zinc-900"><%= rollup.label %></span>
                      <span class="text-xs text-zinc-500"><%= format_percent(rollup.utilization_percent) %> utilised</span>
                    </div>

                    <dl class="mt-2 space-y-1 text-xs">
                      <div class="flex items-center justify-between">
                        <dt class="text-zinc-500">Allocated</dt>
                        <dd class="text-zinc-700">
                          <%= visible_value(@show_balances?, rollup.allocated, rollup.allocated_masked) %>
                        </dd>
                      </div>
                      <div class="flex items-center justify-between">
                        <dt class="text-zinc-500">Actual</dt>
                        <dd class="text-zinc-700">
                          <%= visible_value(@show_balances?, rollup.actual, rollup.actual_masked) %>
                        </dd>
                      </div>
                      <div class="flex items-center justify-between">
                        <dt class="text-zinc-500">Projection</dt>
                        <dd class="text-zinc-700">
                          <%= visible_value(@show_balances?, rollup.projection, rollup.projection_masked) %>
                        </dd>
                      </div>
                      <div class="flex items-center justify-between">
                        <dt class="text-zinc-500">Variance</dt>
                        <dd class={variance_class(rollup.variance_decimal)}>
                          <%= visible_value(@show_balances?, rollup.variance, rollup.variance_masked) %>
                        </dd>
                      </div>
                    </dl>
                  </li>

                  <li :if={Enum.empty?(rollup_entries(@metrics.budget_rollups.variability, [:fixed, :variable]))}
                      class="text-xs text-zinc-500">No variability insights yet.</li>
                </ul>
              </div>
            </div>
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
      budget_rollups: %{entry_type: entry_rollups, variability: variability_rollups},
      subscription: Subscriptions.spend_summary(current_user),
      category_rollups: Transactions.category_rollups(current_user),
      recent_transactions: Transactions.recent_with_color(current_user),
      notifications: Notifications.pending(current_user, budget_opts)
    }
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
    base = "inline-flex items-center rounded-full border px-3 py-1 text-xs font-semibold transition-colors"

    if period == current do
      base <> " border-emerald-500 bg-emerald-500 text-white"
    else
      base <> " border-zinc-200 text-zinc-600 hover:border-emerald-400 hover:text-emerald-600"
    end
  end

  defp budget_period_value(period) when is_atom(period), do: Atom.to_string(period)
  defp budget_period_value(period), do: period

  defp rollup_entries(nil, _order), do: []

  defp rollup_entries(rollups, order) do
    order
    |> Enum.map(&Map.get(rollups, &1))
    |> Enum.reject(&is_nil/1)
  end

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
