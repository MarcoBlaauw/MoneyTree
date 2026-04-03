defmodule MoneyTreeWeb.ObligationsLive.Index do
  @moduledoc """
  LiveView for reviewing payment obligations and alerting posture.
  """

  use MoneyTreeWeb, :live_view

  alias MoneyTree.Notifications
  alias MoneyTree.Obligations

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: current_user}} = socket) do
    {:ok,
     socket
     |> assign(page_title: "Obligations")
     |> load_page(current_user)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-6">
      <.header title="Obligations" subtitle="Track recurring payment commitments and the alerts around them.">
        <:actions>
          <a href="/app/react/control-panel" class="btn btn-outline">Open manager</a>
        </:actions>
      </.header>

      <div class="grid gap-4 lg:grid-cols-3">
        <div class="rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Active obligations</p>
          <p class="mt-1 text-2xl font-semibold text-zinc-900"><%= active_count(@obligations) %></p>
          <p class="text-xs text-zinc-500">Bills and payment commitments currently enabled</p>
        </div>

        <div class="rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Dashboard alerts</p>
          <p class="mt-1 text-2xl font-semibold text-zinc-900"><%= length(@notifications) %></p>
          <p class="text-xs text-zinc-500">Open durable and computed alerts tied to due-state monitoring</p>
        </div>

        <div class="rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Delivery channels</p>
          <p class="mt-1 text-2xl font-semibold text-zinc-900"><%= enabled_channel_summary(@preference) %></p>
          <p class="text-xs text-zinc-500">Current notification channel posture</p>
        </div>
      </div>

      <div class="grid gap-6 xl:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)]">
        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <div>
            <h2 class="text-lg font-semibold text-zinc-900">Current obligations</h2>
            <p class="text-sm text-zinc-500">Review due rules, linked accounts, and minimum amounts.</p>
          </div>

          <ul class="space-y-3">
            <li :for={obligation <- @obligations} class="space-y-3 rounded-xl border border-zinc-100 bg-zinc-50 p-4">
              <div class="flex items-start justify-between gap-4">
                <div>
                  <p class="font-semibold text-zinc-900"><%= obligation.creditor_payee %></p>
                  <p class="text-xs text-zinc-500">
                    Due <%= due_label(obligation) %>
                    <%= if obligation.linked_funding_account_name do %>
                      • funded from <%= obligation.linked_funding_account_name %>
                    <% end %>
                  </p>
                </div>
                <span class={active_badge_class(obligation.active)}>
                  <%= if obligation.active, do: "Active", else: "Paused" %>
                </span>
              </div>

              <dl class="grid gap-3 text-sm sm:grid-cols-2">
                <div class="rounded-lg bg-white px-3 py-2">
                  <dt class="text-xs uppercase tracking-wide text-zinc-500">Minimum due</dt>
                  <dd class="mt-1 font-medium text-zinc-900"><%= obligation.minimum_due_amount %></dd>
                </div>
                <div class="rounded-lg bg-white px-3 py-2">
                  <dt class="text-xs uppercase tracking-wide text-zinc-500">Grace period</dt>
                  <dd class="mt-1 font-medium text-zinc-900"><%= obligation.grace_period_days %> days</dd>
                </div>
              </dl>
            </li>

            <li :if={Enum.empty?(@obligations)} class="rounded-xl border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
              No obligations configured yet. Use the manager to add your first recurring payment rule.
            </li>
          </ul>
        </div>

        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <div>
            <h2 class="text-lg font-semibold text-zinc-900">Alert settings snapshot</h2>
            <p class="text-sm text-zinc-500">Delivery and resend posture from your stored preferences.</p>
          </div>

          <ul class="space-y-3 text-sm">
            <li class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-2">
              <span class="text-zinc-600">Email delivery</span>
              <span class="font-medium text-zinc-900"><%= enabled_label(@preference.email_enabled) %></span>
            </li>
            <li class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-2">
              <span class="text-zinc-600">Dashboard visibility</span>
              <span class="font-medium text-zinc-900"><%= enabled_label(@preference.dashboard_enabled) %></span>
            </li>
            <li class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-2">
              <span class="text-zinc-600">Upcoming lead days</span>
              <span class="font-medium text-zinc-900"><%= @preference.upcoming_lead_days %></span>
            </li>
            <li class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-2">
              <span class="text-zinc-600">Resend interval</span>
              <span class="font-medium text-zinc-900"><%= @preference.resend_interval_hours %> hours</span>
            </li>
            <li class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-2">
              <span class="text-zinc-600">Maximum resends</span>
              <span class="font-medium text-zinc-900"><%= @preference.max_resends %></span>
            </li>
          </ul>

          <div class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
            <p class="text-sm text-zinc-600">
              Full obligation editing and channel preference management still lives in the current control panel surface.
            </p>
            <div class="mt-3 flex flex-wrap gap-2">
              <a href="/app/react/control-panel" class="btn btn-outline">Open control panel</a>
              <.link navigate={~p"/app/settings/notifications"} class="btn btn-outline">Open notification settings</.link>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp load_page(socket, current_user) do
    assign(socket,
      obligations: Obligations.summary(current_user),
      preference: Notifications.get_alert_preference(current_user),
      notifications: Notifications.pending(current_user)
    )
  end

  defp active_count(obligations), do: Enum.count(obligations, & &1.active)

  defp enabled_channel_summary(preference) do
    enabled =
      [
        {preference.email_enabled, "Email"},
        {Map.get(preference, :sms_enabled, false), "SMS"},
        {Map.get(preference, :push_enabled, false), "Push"}
      ]
      |> Enum.filter(fn {enabled?, _label} -> enabled? end)
      |> Enum.map_join(", ", fn {_enabled?, label} -> label end)

    if enabled == "", do: "None", else: enabled
  end

  defp due_label(%{due_rule: "last_day_of_month"}), do: "on the last day of the month"
  defp due_label(%{due_day: day}) when is_integer(day), do: "on day #{day}"
  defp due_label(_obligation), do: "by configured rule"

  defp enabled_label(true), do: "Enabled"
  defp enabled_label(false), do: "Disabled"

  defp active_badge_class(true),
    do:
      "rounded-full bg-emerald-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-emerald-700"

  defp active_badge_class(false),
    do:
      "rounded-full bg-zinc-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-zinc-600"
end
