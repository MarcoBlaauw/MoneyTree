defmodule MoneyTreeWeb.SettingsLive do
  @moduledoc """
  LiveView for displaying profile and security settings with inactivity locking.
  """

  use MoneyTreeWeb, :live_view

  alias MoneyTree.Accounts

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: current_user}} = socket) do
    {:ok,
     socket
     |> assign(page_title: "Settings", locked?: false)
     |> load_settings(current_user)}
  end

  @impl true
  def handle_event("lock-interface", _params, socket) do
    {:noreply,
     socket
     |> assign(locked?: true)
     |> put_flash(:info, "Settings locked. Unlock to view sensitive information.")}
  end

  def handle_event("unlock-interface", _params, %{assigns: %{current_user: current_user}} = socket) do
    {:noreply,
     socket
     |> assign(locked?: false)
     |> load_settings(current_user)
     |> put_flash(:info, "Settings unlocked.")}
  end

  def handle_event("refresh-settings", _params, %{assigns: %{current_user: current_user, locked?: false}} = socket) do
    {:noreply, load_settings(socket, current_user)}
  end

  def handle_event("refresh-settings", _params, socket) do
    {:noreply, put_flash(socket, :error, "Unlock settings to refresh data.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-6">
      <.header title="Settings" subtitle="Manage profile, security, and device sessions.">
        <:actions>
          <button class="btn btn-outline" type="button" phx-click="lock-interface">Lock</button>
          <button :if={@locked?} class="btn" type="button" phx-click="unlock-interface">Unlock</button>
          <button class="btn btn-outline" type="button" phx-click="refresh-settings">Refresh</button>
        </:actions>
      </.header>

      <div :if={@locked?} class="rounded-lg border border-dashed border-zinc-200 bg-zinc-50 p-6 text-center text-sm text-zinc-600">
        Settings are locked. Unlock to view profile details.
      </div>

      <div :if={!@locked?} class="grid gap-6 lg:grid-cols-2">
        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <h2 class="text-lg font-semibold text-zinc-900">Profile</h2>
          <dl class="space-y-3 text-sm text-zinc-600">
            <div class="flex items-center justify-between">
              <dt class="font-medium text-zinc-700">Full name</dt>
              <dd><%= @settings.profile.full_name %></dd>
            </div>
            <div class="flex items-center justify-between">
              <dt class="font-medium text-zinc-700">Email</dt>
              <dd><%= @settings.profile.email %></dd>
            </div>
            <div class="flex items-center justify-between">
              <dt class="font-medium text-zinc-700">Role</dt>
              <dd class="capitalize"><%= @settings.profile.role %></dd>
            </div>
          </dl>
        </div>

        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <h2 class="text-lg font-semibold text-zinc-900">Security</h2>
          <ul class="space-y-2 text-sm text-zinc-600">
            <li class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 p-3">
              <span>Multi-factor authentication</span>
              <span class="font-semibold text-zinc-800">
                <%= if @settings.security.multi_factor_enabled, do: "Enabled", else: "Disabled" %>
              </span>
            </li>
            <li class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 p-3">
              <span>Last login</span>
              <span><%= format_timestamp(@settings.security.last_login_at) %></span>
            </li>
          </ul>
        </div>

        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm lg:col-span-2">
          <h2 class="text-lg font-semibold text-zinc-900">Active sessions</h2>
          <table class="w-full table-auto text-left text-sm">
            <thead>
              <tr class="border-b border-zinc-200 text-xs uppercase tracking-wide text-zinc-500">
                <th class="py-2">Context</th>
                <th class="py-2">Last used</th>
                <th class="py-2">IP address</th>
                <th class="py-2">User agent</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={session <- @settings.sessions} class="border-b border-zinc-100">
                <td class="py-2 font-medium text-zinc-800"><%= session.context %></td>
                <td class="py-2 text-zinc-600"><%= format_timestamp(session.last_used_at) %></td>
                <td class="py-2 text-zinc-600"><%= session.ip_address || "Unknown" %></td>
                <td class="py-2 text-zinc-600"><%= session.user_agent || "Unknown" %></td>
              </tr>
              <tr :if={Enum.empty?(@settings.sessions)}>
                <td colspan="4" class="py-4 text-center text-zinc-500">No active sessions recorded.</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </section>
    """
  end

  defp load_settings(socket, current_user) do
    assign(socket, :settings, Accounts.user_settings(current_user))
  end

  defp format_timestamp(nil), do: "Never"

  defp format_timestamp(%DateTime{} = datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%b %d, %Y %H:%M UTC")
  rescue
    _ -> DateTime.to_string(datetime)
  end
end
