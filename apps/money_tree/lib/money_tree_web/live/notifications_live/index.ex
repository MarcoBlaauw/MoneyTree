defmodule MoneyTreeWeb.NotificationsLive.Index do
  @moduledoc """
  LiveView for reviewing durable and computed MoneyTree notifications.
  """

  use MoneyTreeWeb, :live_view

  alias MoneyTree.Notifications

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: current_user}} = socket) do
    {:ok,
     socket
     |> assign(page_title: "Notifications", hidden_notification_keys: MapSet.new())
     |> load_notifications(current_user)}
  end

  @impl true
  def handle_event(
        "resolve-notification",
        %{"id" => event_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    case Notifications.resolve_event(current_user, event_id) do
      {:ok, _event} ->
        {:noreply,
         socket
         |> load_notifications(current_user)
         |> put_flash(:info, "Notification dismissed.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Notification not found or already dismissed.")}

      {:error, :already_resolved} ->
        {:noreply,
         socket
         |> load_notifications(current_user)
         |> put_flash(:info, "Notification already dismissed.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Unable to dismiss the notification right now.")}
    end
  end

  def handle_event("hide-computed-notification", %{"key" => key}, socket) do
    {:noreply,
     socket
     |> update(:hidden_notification_keys, &MapSet.put(&1, key))
     |> put_flash(:info, "Advisory hidden for this session.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-6">
      <.header title="Notifications" subtitle="Review durable alerts and computed advisories.">
        <:actions>
          <.link navigate={~p"/app/dashboard"} class="btn btn-outline">Dashboard</.link>
        </:actions>
      </.header>

      <div class="grid gap-4 lg:grid-cols-3">
        <div class="rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Open</p>
          <p class="mt-1 text-2xl font-semibold text-zinc-900"><%= length(visible_notifications(@notifications, @hidden_notification_keys)) %></p>
          <p class="text-xs text-zinc-500">Visible notifications</p>
        </div>

        <div class="rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Durable</p>
          <p class="mt-1 text-2xl font-semibold text-zinc-900"><%= durable_count(@notifications) %></p>
          <p class="text-xs text-zinc-500">Persist until dismissed</p>
        </div>

        <div class="rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Computed</p>
          <p class="mt-1 text-2xl font-semibold text-zinc-900"><%= computed_count(@notifications) %></p>
          <p class="text-xs text-zinc-500">Generated from current data</p>
        </div>
      </div>

      <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
        <div>
          <h2 class="text-lg font-semibold text-zinc-900">Notification inbox</h2>
          <p class="text-sm text-zinc-500">Durable alerts can be dismissed permanently. Computed advisories can be hidden for the current session.</p>
        </div>

        <ul class="space-y-3">
          <li :for={notification <- visible_notifications(@notifications, @hidden_notification_keys)}
              class="space-y-3 rounded-xl border border-zinc-100 bg-zinc-50 p-4">
            <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <span class={notification_severity_badge_class(notification.severity)}>
                    <%= Atom.to_string(notification.severity) %>
                  </span>
                  <span class="rounded-full bg-white px-2 py-1 text-[11px] font-semibold uppercase tracking-wide text-zinc-500">
                    <%= if notification.durable, do: "Durable event", else: "Computed advisory" %>
                  </span>
                </div>
                <p class="mt-3 font-medium text-zinc-900"><%= notification.message %></p>
                <p :if={notification.action} class="mt-1 text-sm text-emerald-700">
                  <%= notification.action %>
                </p>
              </div>

              <div class="flex shrink-0 justify-end gap-2">
                <button :if={notification.durable && notification.event_id}
                        type="button"
                        class="btn btn-outline"
                        phx-click="resolve-notification"
                        phx-value-id={notification.event_id}>
                  Dismiss
                </button>
                <button :if={!notification.durable}
                        type="button"
                        class="btn btn-outline"
                        phx-click="hide-computed-notification"
                        phx-value-key={notification_key(notification)}>
                  Hide
                </button>
              </div>
            </div>
          </li>

          <li :if={Enum.empty?(visible_notifications(@notifications, @hidden_notification_keys))}
              class="rounded-xl border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
            No notifications need attention right now.
          </li>
        </ul>
      </div>
    </section>
    """
  end

  defp load_notifications(socket, current_user) do
    assign(socket, notifications: Notifications.pending(current_user, period: :monthly))
  end

  defp visible_notifications(notifications, hidden_keys) do
    Enum.reject(notifications, fn notification ->
      MapSet.member?(hidden_keys, notification_key(notification))
    end)
  end

  defp durable_count(notifications), do: Enum.count(notifications, & &1.durable)
  defp computed_count(notifications), do: Enum.count(notifications, &(!&1.durable))

  defp notification_key(notification) do
    [
      notification.message,
      notification.action,
      notification.severity,
      notification.durable,
      notification.event_id
    ]
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

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
end
