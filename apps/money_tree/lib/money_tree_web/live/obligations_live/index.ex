defmodule MoneyTreeWeb.ObligationsLive.Index do
  @moduledoc """
  LiveView for reviewing payment obligations and alerting posture.
  """

  use MoneyTreeWeb, :live_view

  alias MoneyTree.Accounts
  alias MoneyTree.Notifications
  alias MoneyTree.Obligations
  alias MoneyTree.Obligations.Obligation

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: current_user}} = socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Obligations",
       selected_event: nil,
       obligation_form_open?: false,
       obligation_form_mode: :new,
       obligation_editing_obligation: nil,
       obligation_changeset: Obligations.change_obligation(%Obligation{})
     )
     |> load_page(current_user)}
  end

  @impl true
  def handle_params(params, _uri, %{assigns: %{current_user: current_user}} = socket) do
    selected_event = load_selected_event(current_user, Map.get(params, "event"))

    {:noreply, assign(socket, :selected_event, selected_event)}
  end

  @impl true
  def handle_event("new-obligation", _params, socket) do
    {:noreply,
     assign(socket,
       obligation_form_open?: true,
       obligation_form_mode: :new,
       obligation_editing_obligation: nil,
       obligation_changeset: Obligations.change_obligation(%Obligation{})
     )}
  end

  def handle_event("cancel-obligation", _params, socket) do
    {:noreply, reset_obligation_form(socket)}
  end

  def handle_event(
        "edit-obligation",
        %{"id" => obligation_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    case Obligations.fetch_obligation(current_user, obligation_id) do
      {:ok, obligation} ->
        {:noreply,
         assign(socket,
           obligation_form_open?: true,
           obligation_form_mode: :edit,
           obligation_editing_obligation: obligation,
           obligation_changeset: Obligations.change_obligation(obligation)
         )}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Obligation not found or no longer accessible.")}
    end
  end

  def handle_event("validate-obligation", %{"obligation" => params}, socket) do
    base_obligation = socket.assigns.obligation_editing_obligation || %Obligation{}

    changeset =
      base_obligation
      |> Obligations.change_obligation(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, obligation_changeset: changeset, obligation_form_open?: true)}
  end

  def handle_event(
        "save-obligation",
        %{"obligation" => params},
        %{assigns: %{current_user: current_user, obligation_form_mode: :new}} = socket
      ) do
    case Obligations.create_obligation(current_user, params) do
      {:ok, _obligation} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> reset_obligation_form()
         |> put_flash(:info, "Obligation added successfully.")}

      {:error, :linked_funding_account_required} ->
        {:noreply,
         socket
         |> assign(obligation_form_open?: true)
         |> put_flash(:error, "Funding account is required.")}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> assign(obligation_form_open?: true)
         |> put_flash(:error, "You do not have permission to use that account.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           obligation_form_open?: true,
           obligation_changeset: Map.put(changeset, :action, :validate)
         )}
    end
  end

  def handle_event(
        "save-obligation",
        %{"obligation" => params},
        %{
          assigns: %{
            current_user: current_user,
            obligation_form_mode: :edit,
            obligation_editing_obligation: %Obligation{} = obligation
          }
        } = socket
      ) do
    case Obligations.update_obligation(current_user, obligation, params) do
      {:ok, _obligation} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> reset_obligation_form()
         |> put_flash(:info, "Obligation updated successfully.")}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> assign(obligation_form_open?: true)
         |> put_flash(:error, "You do not have permission to update that obligation.")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> reset_obligation_form()
         |> put_flash(:error, "Obligation not found or already removed.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           obligation_form_open?: true,
           obligation_changeset: Map.put(changeset, :action, :validate)
         )}
    end
  end

  def handle_event(
        "delete-obligation",
        %{"id" => obligation_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    case Obligations.delete_obligation(current_user, obligation_id) do
      {:ok, _obligation} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> maybe_reset_form_for_deleted(obligation_id)
         |> put_flash(:info, "Obligation removed successfully.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Obligation not found or already removed.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-6">
      <.header title="Obligations" subtitle="Track recurring payment commitments and the alerts around them.">
        <:actions>
          <button type="button" class="btn btn-outline" phx-click="new-obligation">Add obligation</button>
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

              <div class="flex justify-end gap-2">
                <button type="button" class="btn btn-outline" phx-click="edit-obligation" phx-value-id={obligation.id}>
                  Edit
                </button>
                <button type="button"
                        class="btn btn-ghost text-rose-600"
                        phx-click="delete-obligation"
                        phx-value-id={obligation.id}
                        data-confirm="Are you sure you want to remove this obligation?">
                  Remove
                </button>
              </div>
            </li>

            <li :if={Enum.empty?(@obligations)} class="rounded-xl border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
              No obligations configured yet. Add your first recurring payment rule.
            </li>
          </ul>
        </div>

        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <div class="flex items-start justify-between gap-3">
            <div>
              <h2 class="text-lg font-semibold text-zinc-900">
                <%= if @obligation_form_mode == :edit, do: "Edit obligation", else: "Add obligation" %>
              </h2>
              <p class="text-sm text-zinc-500">Configure due cadence, minimum amount, and linked funding source.</p>
            </div>
            <button :if={@obligation_form_open?} type="button" class="btn btn-outline" phx-click="cancel-obligation">
              Cancel
            </button>
          </div>

          <div :if={!@obligation_form_open?} class="rounded-xl border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
            Choose “Add obligation” to create a new rule, or edit one from the list.
          </div>

          <.simple_form :if={@obligation_form_open?}
                        for={@obligation_changeset}
                        id="obligation-form"
                        phx-change="validate-obligation"
                        phx-submit="save-obligation"
                        :let={f}>
            <div class="grid gap-4">
              <.input field={f[:creditor_payee]} label="Creditor / payee" />

              <div>
                <label class="text-sm font-medium text-zinc-700" for="obligation_linked_funding_account_id">Funding account</label>
                <select id="obligation_linked_funding_account_id" name="obligation[linked_funding_account_id]" class="input">
                  <%= Phoenix.HTML.Form.options_for_select(
                    funding_account_options(@funding_accounts),
                    f[:linked_funding_account_id].value || (@obligation_editing_obligation && @obligation_editing_obligation.linked_funding_account_id)
                  ) %>
                </select>
                <p :for={error <- errors_on(@obligation_changeset, :linked_funding_account_id)} class="text-sm text-red-600"><%= error %></p>
              </div>

              <div>
                <label class="text-sm font-medium text-zinc-700" for="obligation_due_rule">Due rule</label>
                <select id="obligation_due_rule" name="obligation[due_rule]" class="input">
                  <%= Phoenix.HTML.Form.options_for_select(due_rule_options(), f[:due_rule].value || "calendar_day") %>
                </select>
                <p :for={error <- errors_on(@obligation_changeset, :due_rule)} class="text-sm text-red-600"><%= error %></p>
              </div>

              <.input field={f[:due_day]} label="Due day" type={:number} min="1" max="31" />
              <.input field={f[:minimum_due_amount]} label="Minimum due amount" type={:number} step="0.01" min="0.01" />
              <.input field={f[:grace_period_days]} label="Grace period days" type={:number} min="0" max="31" />
              <.input field={f[:active]} label="Active" type={:checkbox} />
            </div>

            <div class="flex justify-end gap-2">
              <button type="button" class="btn btn-outline" phx-click="cancel-obligation">Cancel</button>
              <button type="submit" class="btn">
                <%= if @obligation_form_mode == :edit, do: "Save changes", else: "Add obligation" %>
              </button>
            </div>
          </.simple_form>

          <div class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
            <p class="text-sm text-zinc-600">
              Notification delivery preferences remain available under notification settings.
            </p>
            <div class="mt-3 flex flex-wrap gap-2">
              <.link navigate={~p"/app/settings/notifications"} class="btn btn-outline">Open notification settings</.link>
            </div>
          </div>
        </div>
      </div>

      <div class="grid gap-6 xl:grid-cols-[minmax(0,1.2fr)_minmax(0,1fr)]">
        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <div>
            <h2 class="text-lg font-semibold text-zinc-900">Recent alert history</h2>
            <p class="text-sm text-zinc-500">Durable obligation alert events and current delivery state.</p>
          </div>

          <ul class="space-y-3">
            <li :for={event <- @event_history}
                class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
              <.link patch={~p"/app/obligations?event=#{event.id}"} class="block space-y-3">
                <div class="flex items-start justify-between gap-3">
                  <div>
                    <p class="font-semibold text-zinc-900"><%= event.title %></p>
                    <p class="text-xs text-zinc-500">
                      <%= event_status_label(event.status) %>
                      <%= if event.event_date, do: " • due #{event.event_date}" %>
                    </p>
                  </div>
                  <span class={severity_badge_class(event.severity)}>
                    <%= event.severity %>
                  </span>
                </div>

                <p class="text-sm text-zinc-600"><%= event.message %></p>

                <div class="flex flex-wrap items-center gap-2 text-xs text-zinc-500">
                  <span class={delivery_status_badge_class(event.delivery_status)}>
                    <%= String.replace(event.delivery_status, "_", " ") %>
                  </span>
                  <span><%= format_datetime(event.occurred_at) %></span>
                  <span :if={event.resolved_at} class="text-emerald-700">Resolved</span>
                </div>
              </.link>
            </li>

            <li :if={Enum.empty?(@event_history)} class="rounded-xl border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
              No durable alert history yet.
            </li>
          </ul>
        </div>

        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <div>
            <h2 class="text-lg font-semibold text-zinc-900">Alert details</h2>
            <p class="text-sm text-zinc-500">Inspect delivery and lifecycle metadata for a selected event.</p>
          </div>

          <div :if={@selected_event} class="space-y-4">
            <div class="rounded-lg border border-zinc-100 bg-zinc-50 p-4">
              <p class="text-xs uppercase tracking-wide text-zinc-500">Title</p>
              <p class="mt-1 font-semibold text-zinc-900"><%= @selected_event.title %></p>
              <p class="mt-2 text-sm text-zinc-600"><%= @selected_event.message %></p>
            </div>

            <dl class="space-y-2 text-sm text-zinc-600">
              <div class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-2">
                <dt>Status</dt>
                <dd class="font-medium text-zinc-900"><%= event_status_label(@selected_event.status) %></dd>
              </div>
              <div class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-2">
                <dt>Severity</dt>
                <dd class="font-medium text-zinc-900"><%= @selected_event.severity %></dd>
              </div>
              <div class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-2">
                <dt>Delivery</dt>
                <dd class="font-medium text-zinc-900"><%= String.replace(@selected_event.delivery_status, "_", " ") %></dd>
              </div>
              <div class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-2">
                <dt>Attempts</dt>
                <dd class="font-medium text-zinc-900"><%= @selected_event.delivery_attempt_count %></dd>
              </div>
              <div class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-2">
                <dt>Occurred</dt>
                <dd class="font-medium text-zinc-900"><%= format_datetime(@selected_event.occurred_at) %></dd>
              </div>
              <div class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-2">
                <dt>Resolved</dt>
                <dd class="font-medium text-zinc-900"><%= format_datetime(@selected_event.resolved_at) %></dd>
              </div>
              <div class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-2">
                <dt>Obligation</dt>
                <dd class="font-medium text-zinc-900"><%= obligation_label(@selected_event) %></dd>
              </div>
            </dl>

            <div :if={present?(@selected_event.action)} class="rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-2 text-sm">
              <p class="text-xs uppercase tracking-wide text-zinc-500">Suggested action</p>
              <p class="mt-1 font-medium text-zinc-900"><%= @selected_event.action %></p>
            </div>

            <div :if={present?(@selected_event.last_delivery_error)} class="rounded-lg border border-rose-100 bg-rose-50 px-3 py-2 text-sm text-rose-800">
              <p class="text-xs uppercase tracking-wide text-rose-600">Last delivery error</p>
              <p class="mt-1"><%= @selected_event.last_delivery_error %></p>
            </div>
          </div>

          <div :if={is_nil(@selected_event)} class="rounded-xl border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
            Select an event from history to inspect details.
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp load_page(socket, current_user) do
    assign(socket,
      obligations: Obligations.summary(current_user),
      funding_accounts: Accounts.list_accessible_accounts(current_user, order_by: {:asc, :name}),
      preference: Notifications.get_alert_preference(current_user),
      notifications: Notifications.pending(current_user),
      event_history: Notifications.list_event_history(current_user, limit: 20)
    )
  end

  defp reset_obligation_form(socket) do
    assign(socket,
      obligation_form_open?: false,
      obligation_form_mode: :new,
      obligation_editing_obligation: nil,
      obligation_changeset: Obligations.change_obligation(%Obligation{})
    )
  end

  defp maybe_reset_form_for_deleted(socket, obligation_id) do
    case socket.assigns.obligation_editing_obligation do
      %Obligation{id: ^obligation_id} -> reset_obligation_form(socket)
      _ -> socket
    end
  end

  defp funding_account_options(accounts) do
    Enum.map(accounts, &{&1.name, &1.id})
  end

  defp due_rule_options do
    [
      {"Calendar day", "calendar_day"},
      {"Last day of month", "last_day_of_month"}
    ]
  end

  defp errors_on(changeset, field) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Map.get(field, [])
  end

  defp load_selected_event(_current_user, nil), do: nil
  defp load_selected_event(_current_user, ""), do: nil

  defp load_selected_event(current_user, event_id) do
    case Notifications.get_event(current_user, event_id, preload: [:obligation]) do
      {:ok, event} -> event
      {:error, :not_found} -> nil
    end
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

  defp event_status_label("due_today"), do: "Due today"
  defp event_status_label("overdue"), do: "Overdue"
  defp event_status_label("upcoming"), do: "Upcoming"
  defp event_status_label("recovered"), do: "Recovered"
  defp event_status_label(status), do: status

  defp severity_badge_class("critical"),
    do:
      "rounded-full bg-rose-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-rose-700"

  defp severity_badge_class("warning"),
    do:
      "rounded-full bg-amber-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-amber-700"

  defp severity_badge_class(_severity),
    do:
      "rounded-full bg-zinc-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-zinc-600"

  defp delivery_status_badge_class("delivered"),
    do:
      "rounded-full bg-emerald-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-emerald-700"

  defp delivery_status_badge_class("failed"),
    do:
      "rounded-full bg-rose-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-rose-700"

  defp delivery_status_badge_class("suppressed"),
    do:
      "rounded-full bg-zinc-200 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-zinc-700"

  defp delivery_status_badge_class(_status),
    do:
      "rounded-full bg-amber-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-amber-700"

  defp obligation_label(%{obligation: %{creditor_payee: payee}}) when is_binary(payee), do: payee
  defp obligation_label(_event), do: "Not linked"

  defp present?(value) when value in [nil, ""], do: false
  defp present?(_value), do: true

  defp format_datetime(nil), do: "Not recorded"

  defp format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%b %-d, %Y %I:%M %p UTC")
  end

  defp format_datetime(_value), do: "Unknown"

  defp active_badge_class(true),
    do:
      "rounded-full bg-emerald-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-emerald-700"

  defp active_badge_class(false),
    do:
      "rounded-full bg-zinc-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-zinc-600"
end
