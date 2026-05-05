defmodule MoneyTreeWeb.AccountsLive.Index do
  @moduledoc """
  LiveView for account and institution connection management overview.
  """

  use MoneyTreeWeb, :live_view

  alias MoneyTree.Accounts
  alias MoneyTree.Institutions

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: current_user}} = socket) do
    {:ok,
     socket
     |> assign(page_title: "Accounts & Institutions")
     |> load_page(current_user)}
  end

  @impl true
  def handle_event(
        "refresh-connection",
        %{"id" => connection_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    with {:ok, connection} <-
           Institutions.get_active_connection_for_user(current_user, connection_id,
             preload: [:institution]
           ),
         :ok <-
           sync_module().schedule_incremental_sync(connection,
             telemetry_metadata: %{"source" => "accounts_live"}
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Sync requested for #{connection.institution.name}.")}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Connection not found.")}

      {:error, :revoked} ->
        {:noreply, put_flash(socket, :error, "This connection is already revoked.")}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "Unable to queue a sync for this connection right now.")}
    end
  end

  def handle_event(
        "revoke-connection",
        %{"id" => connection_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    with {:ok, connection} <-
           Institutions.get_active_connection_for_user(current_user, connection_id,
             preload: [:institution]
           ),
         {:ok, _revoked} <-
           Institutions.mark_connection_revoked(current_user, connection_id,
             reason: "user_initiated"
           ) do
      {:noreply,
       socket
       |> load_page(current_user)
       |> put_flash(:info, "Revoked #{connection_label(connection)}.")}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Connection not found.")}

      {:error, :revoked} ->
        {:noreply, put_flash(socket, :error, "This connection is already revoked.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Unable to revoke this connection right now.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-6">
      <.header title="Accounts & institutions" subtitle="Review linked institutions, connected accounts, and sync health.">
        <:actions>
          <a href="/app/react/link-bank" class="btn btn-outline">Connect institution</a>
        </:actions>
      </.header>

      <div class="grid gap-4 lg:grid-cols-3">
        <div class="rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Institutions</p>
          <p class="mt-1 text-2xl font-semibold text-zinc-900"><%= length(@connections) %></p>
          <p class="text-xs text-zinc-500">Active external connections</p>
        </div>

        <div class="rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Accounts</p>
          <p class="mt-1 text-2xl font-semibold text-zinc-900"><%= length(@summary.accounts) %></p>
          <p class="text-xs text-zinc-500">Accessible financial accounts</p>
        </div>

        <div class="rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Sync issues</p>
          <p class="mt-1 text-2xl font-semibold text-zinc-900"><%= sync_issue_count(@connections) %></p>
          <p class="text-xs text-zinc-500">Connections with recent sync errors</p>
        </div>
      </div>

      <div class="grid gap-6 xl:grid-cols-[minmax(0,1.3fr)_minmax(0,1fr)]">
        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <div class="flex items-start justify-between gap-4">
            <div>
              <h2 class="text-lg font-semibold text-zinc-900">Linked institutions</h2>
              <p class="text-sm text-zinc-500">Provider connections and current sync state.</p>
            </div>
            <a href="/app/react/link-bank" class="btn btn-outline">Manage links</a>
          </div>

          <ul class="space-y-3">
            <li :for={connection <- @connections} class="space-y-3 rounded-xl border border-zinc-100 bg-zinc-50 p-4">
              <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                <div>
                  <p class="text-base font-semibold text-zinc-900"><%= connection.institution.name %></p>
                  <p class="text-xs uppercase tracking-wide text-zinc-500"><%= connection.provider %> connection</p>
                </div>
                <span class={connection_status_badge_class(connection)}>
                  <%= connection_status_label(connection) %>
                </span>
              </div>

              <dl class="grid gap-3 text-sm sm:grid-cols-2">
                <div class="rounded-lg bg-white px-3 py-2">
                  <dt class="text-xs uppercase tracking-wide text-zinc-500">Accounts</dt>
                  <dd class="mt-1 font-medium text-zinc-800"><%= length(connection.accounts) %></dd>
                </div>
                <div class="rounded-lg bg-white px-3 py-2">
                  <dt class="text-xs uppercase tracking-wide text-zinc-500">Last synced</dt>
                  <dd class="mt-1 font-medium text-zinc-800"><%= format_datetime(connection.last_synced_at) %></dd>
                </div>
              </dl>

              <p :if={connection.last_sync_error} class="rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-800">
                Recent sync issue recorded. Reconnect or refresh this institution if balances look stale.
              </p>

              <div class="flex flex-wrap justify-end gap-2">
                <button type="button"
                        class="btn btn-outline"
                        phx-click="refresh-connection"
                        phx-value-id={connection.id}>
                  Refresh sync
                </button>
                <a :if={connection.last_sync_error}
                   href="/app/react/link-bank"
                   class="btn btn-outline">
                  Reconnect
                </a>
                <button type="button"
                        class="btn btn-ghost text-rose-600"
                        phx-click="revoke-connection"
                        phx-value-id={connection.id}
                        data-confirm="Disconnect this institution?">
                  Revoke
                </button>
              </div>
            </li>

            <li :if={Enum.empty?(@connections)} class="rounded-xl border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
              No institutions linked yet. Connect your first bank to start syncing balances and transactions.
            </li>
          </ul>
        </div>

        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <div>
            <h2 class="text-lg font-semibold text-zinc-900">Connected accounts</h2>
            <p class="text-sm text-zinc-500">Account balances grouped by institution and account type.</p>
          </div>

          <ul class="space-y-3">
            <li :for={account_summary <- @summary.accounts} class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
              <div class="flex items-start justify-between gap-4">
                <div>
                  <p class="font-semibold text-zinc-900"><%= account_summary.account.name %></p>
                  <p class="text-xs text-zinc-500">
                    <%= account_summary.account.type %>
                    <%= if account_summary.account.institution do %>
                      • <%= account_summary.account.institution.name %>
                    <% end %>
                  </p>
                </div>
                <div class="text-right">
                  <p class="font-semibold text-zinc-900"><%= account_summary.current_balance %></p>
                  <p class="text-xs text-zinc-500">Available <%= account_summary.available_balance %></p>
                </div>
              </div>
            </li>

            <li :if={Enum.empty?(@summary.accounts)} class="rounded-xl border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
              No accounts are available yet.
            </li>
          </ul>
        </div>
      </div>
    </section>
    """
  end

  defp load_page(socket, current_user) do
    summary =
      Accounts.dashboard_summary(current_user,
        preload: [:institution, :institution_connection]
      )

    connections =
      current_user
      |> Institutions.list_active_connections(preload: [:institution, :accounts])
      |> Institutions.preload_defaults()

    assign(socket, summary: summary, connections: connections)
  end

  defp sync_issue_count(connections) do
    Enum.count(connections, & &1.last_sync_error)
  end

  defp connection_status_badge_class(%{last_sync_error: error}) when not is_nil(error) do
    "rounded-full bg-amber-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-amber-700"
  end

  defp connection_status_badge_class(_connection) do
    "rounded-full bg-emerald-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-emerald-700"
  end

  defp connection_status_label(%{last_sync_error: error}) when not is_nil(error),
    do: "Needs attention"

  defp connection_status_label(_connection), do: "Connected"

  defp connection_label(%{institution: %{name: name}}) when is_binary(name), do: name
  defp connection_label(_connection), do: "connection"

  defp sync_module do
    Application.get_env(:money_tree, :synchronization, MoneyTree.Synchronization)
  end

  defp format_datetime(nil), do: "Not synced yet"

  defp format_datetime(%DateTime{} = value) do
    Calendar.strftime(value, "%b %-d, %Y %I:%M %p")
  end

  defp format_datetime(_value), do: "Unknown"
end
