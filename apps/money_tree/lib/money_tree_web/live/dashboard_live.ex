defmodule MoneyTreeWeb.DashboardLive do
  @moduledoc """
  Account overview LiveView with masked balance toggling and inactivity locking.
  """

  use MoneyTreeWeb, :live_view

  alias MoneyTree.Accounts
  alias MoneyTree.Assets
  alias MoneyTree.Assets.Asset
  alias MoneyTreeWeb.AssetFormComponent
  alias MoneyTree.Transactions

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: current_user}} = socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Dashboard",
       show_balances?: false,
       locked?: false,
       asset_form_open?: false,
       asset_form_action: :new,
       asset_form_asset: %Asset{documents: []},
       accessible_accounts: []
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
    {:noreply, assign_transactions(socket, current_user)}
  end

  def handle_event("new-asset", _params, %{assigns: %{current_user: current_user}} = socket) do
    {:noreply,
     socket
     |> assign(
       asset_form_open?: true,
       asset_form_action: :new,
       asset_form_asset: %Asset{documents: []}
     )
     |> ensure_accessible_accounts(current_user)}
  end

  def handle_event("cancel-asset-form", _params, socket) do
    {:noreply, close_asset_form(socket)}
  end

  def handle_event(
        "edit-asset",
        %{"id" => asset_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    case Assets.fetch_accessible_asset(current_user, asset_id, preload: [:account]) do
      {:ok, asset} ->
        {:noreply,
         socket
         |> assign(
           asset_form_open?: true,
           asset_form_action: :edit,
           asset_form_asset: asset
         )
         |> ensure_accessible_accounts(current_user)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Asset not found.")}
    end
  end

  def handle_event(
        "delete-asset",
        %{"id" => asset_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    with {:ok, asset} <- Assets.fetch_accessible_asset(current_user, asset_id),
         {:ok, _} <- Assets.delete_asset_for_user(current_user, asset) do
      {:noreply,
       socket
       |> put_flash(:info, "Asset removed.")
       |> close_asset_form_if_matching(asset)
       |> load_dashboard(current_user)}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Asset not found or inaccessible.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to remove asset: #{first_error_message(changeset)}")}
    end
  end

  @impl true
  def handle_info({:asset_form_saved, _asset}, %{assigns: %{current_user: current_user}} = socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Asset saved.")
     |> close_asset_form()
     |> load_dashboard(current_user)}
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
        <div class="space-y-4">
          <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
            <h2 class="text-lg font-semibold text-zinc-900">Accounts</h2>
            <p class="text-sm text-zinc-500">
              Balances are masked until you choose to reveal them.
            </p>

            <ul class="space-y-3">
              <li :for={summary <- @account_summary.accounts}
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
                <div :for={total <- @account_summary.totals}
                     class="flex items-center justify-between text-sm">
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
              <div>
                <h2 class="text-lg font-semibold text-zinc-900">Assets</h2>
                <p class="text-sm text-zinc-500">Track tangible holdings and their valuations.</p>
              </div>
              <button class="btn" type="button" phx-click="new-asset">
                Add asset
              </button>
            </div>

            <.live_component :if={@asset_form_open?}
                             module={AssetFormComponent}
                             id="asset-form-component"
                             action={@asset_form_action}
                             asset={@asset_form_asset}
                             accounts={@accessible_accounts}
                             current_user={@current_user} />

            <ul class="space-y-3">
              <li :for={summary <- @asset_summary.assets}
                  class="flex flex-col gap-2 rounded-lg border border-zinc-100 bg-zinc-50 p-3">
                <div class="flex items-center justify-between">
                  <div>
                    <p class="font-medium text-zinc-900"><%= summary.asset.name %></p>
                    <p class="text-xs text-zinc-500">
                      <%= summary.type %> • <%= summary.asset.account.name %>
                    </p>
                  </div>
                  <div class="flex items-center gap-2">
                    <button type="button"
                            class="btn btn-outline"
                            phx-click="edit-asset"
                            phx-value-id={summary.asset.id}>
                      Edit
                    </button>
                    <button type="button"
                            class="btn btn-outline btn-danger"
                            phx-click="delete-asset"
                            phx-value-id={summary.asset.id}
                            data-confirm="Are you sure you want to remove this asset?">
                      Remove
                    </button>
                  </div>
                </div>

                <div class="flex items-center justify-between text-sm">
                  <span class="text-zinc-600">Valuation</span>
                  <span class="font-semibold text-zinc-800">
                    <%= if @show_balances?, do: summary.valuation_amount, else: summary.valuation_amount_masked %>
                  </span>
                </div>

                <div :if={summary.ownership || summary.location}
                     class="flex flex-wrap gap-2 text-xs text-zinc-500">
                  <span :if={summary.ownership}>Ownership: <%= summary.ownership %></span>
                  <span :if={summary.location}>Location: <%= summary.location %></span>
                </div>
              </li>
              <li :if={Enum.empty?(@asset_summary.assets)}
                  class="rounded-lg border border-dashed border-zinc-200 p-4 text-center text-sm text-zinc-500">
                No assets recorded yet.
              </li>
            </ul>

            <div class="mt-4 space-y-2 rounded-lg border border-zinc-100 bg-zinc-50 p-3">
              <h3 class="text-sm font-semibold text-zinc-700">Valuation totals</h3>
              <dl class="space-y-2">
                <div :for={total <- @asset_summary.totals}
                     class="flex items-center justify-between text-sm">
                  <dt class="text-zinc-600">
                    <%= total.currency %> • <%= total.asset_count %> assets
                  </dt>
                  <dd class="font-semibold text-zinc-800">
                    <%= if @show_balances?, do: total.total_amount, else: total.total_amount_masked %>
                  </dd>
                </div>
              </dl>
            </div>
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
    |> assign(:account_summary, Accounts.dashboard_summary(current_user))
    |> assign(:asset_summary, Assets.dashboard_summary(current_user))
    |> ensure_accessible_accounts(current_user)
    |> assign_transactions(current_user)
  end

  defp assign_transactions(socket, current_user) do
    assign(socket, :transactions, Transactions.paginate_for_user(current_user))
  end

  defp ensure_accessible_accounts(socket, current_user) do
    accounts =
      Accounts.list_accessible_accounts(current_user,
        order_by: [{:asc, :name}]
      )

    assign(socket, :accessible_accounts, accounts)
  end

  defp close_asset_form(socket) do
    socket
    |> assign(asset_form_open?: false)
    |> assign(asset_form_asset: %Asset{documents: []})
    |> assign(asset_form_action: :new)
  end

  defp close_asset_form_if_matching(socket, %Asset{id: id}) do
    case socket.assigns do
      %{asset_form_open?: true, asset_form_asset: %Asset{id: ^id}} -> close_asset_form(socket)
      _ -> socket
    end
  end

  defp first_error_message(%Ecto.Changeset{errors: errors}) do
    errors
    |> List.first()
    |> case do
      {field, {message, _}} -> "#{Phoenix.Naming.humanize(field)} #{message}"
      _ -> "unexpected error"
    end
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
