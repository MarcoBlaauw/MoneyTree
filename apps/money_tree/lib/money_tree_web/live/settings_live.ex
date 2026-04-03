defmodule MoneyTreeWeb.SettingsLive do
  @moduledoc """
  LiveView for account, security, sessions, notification, and privacy settings.
  """

  use MoneyTreeWeb, :live_view

  alias MoneyTree.Accounts
  alias MoneyTree.Notifications

  @sections [
    %{id: "profile", label: "Profile", description: "Identity, role, and account summary."},
    %{
      id: "security",
      label: "Security",
      description: "Authentication methods and recovery posture."
    },
    %{
      id: "sessions",
      label: "Sessions & devices",
      description: "Browsers and clients with recent access."
    },
    %{
      id: "notifications",
      label: "Notifications",
      description: "Durable alerts, channels, and resend rules."
    },
    %{
      id: "privacy",
      label: "Data & privacy",
      description: "Exports, retention, and account data operations."
    }
  ]

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: current_user}} = socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Settings",
       locked?: false,
       profile_form: nil,
       notification_form: nil,
       sections: @sections,
       current_section: "profile"
     )
     |> load_settings(current_user)}
  end

  @impl true
  def handle_params(%{"section" => section}, _uri, socket) do
    {:noreply, assign(socket, :current_section, normalize_section(section))}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :current_section, "profile")}
  end

  @impl true
  def handle_event("lock-interface", _params, socket) do
    {:noreply,
     socket
     |> assign(locked?: true)
     |> put_flash(:info, "Settings locked. Unlock to view sensitive information.")}
  end

  def handle_event(
        "unlock-interface",
        _params,
        %{assigns: %{current_user: current_user}} = socket
      ) do
    {:noreply,
     socket
     |> assign(locked?: false)
     |> load_settings(current_user)
     |> put_flash(:info, "Settings unlocked.")}
  end

  def handle_event(
        "refresh-settings",
        _params,
        %{assigns: %{current_user: current_user, locked?: false}} = socket
      ) do
    {:noreply, load_settings(socket, current_user)}
  end

  def handle_event("refresh-settings", _params, socket) do
    {:noreply, put_flash(socket, :error, "Unlock settings to refresh data.")}
  end

  def handle_event(
        "validate-profile",
        %{"profile" => params},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    changeset =
      current_user
      |> Accounts.change_user_profile(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :profile_form, to_form(changeset, as: :profile))}
  end

  def handle_event(
        "save-profile",
        %{"profile" => params},
        %{assigns: %{current_user: current_user, locked?: false}} = socket
      ) do
    case Accounts.update_user_profile(current_user, params) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> load_settings(updated_user)
         |> put_flash(:info, "Profile updated.")}

      {:error, changeset} ->
        {:noreply,
         assign(
           socket,
           :profile_form,
           to_form(Map.put(changeset, :action, :validate), as: :profile)
         )}
    end
  end

  def handle_event("save-profile", _params, socket) do
    {:noreply, put_flash(socket, :error, "Unlock settings to update your profile.")}
  end

  def handle_event(
        "validate-notifications",
        %{"notifications" => params},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    changeset =
      current_user
      |> Notifications.get_alert_preference()
      |> Notifications.change_alert_preference(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :notification_form, to_form(changeset, as: :notifications))}
  end

  def handle_event(
        "save-notifications",
        %{"notifications" => params},
        %{assigns: %{current_user: current_user, locked?: false}} = socket
      ) do
    case Notifications.upsert_alert_preference(current_user, params) do
      {:ok, _preference} ->
        {:noreply,
         socket
         |> load_settings(current_user)
         |> put_flash(:info, "Alert preferences updated.")}

      {:error, changeset} ->
        {:noreply,
         assign(
           socket,
           :notification_form,
           to_form(Map.put(changeset, :action, :validate), as: :notifications)
         )}
    end
  end

  def handle_event("save-notifications", _params, socket) do
    {:noreply, put_flash(socket, :error, "Unlock settings to update alert preferences.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-6">
      <.header title="Settings" subtitle="Manage account details, authentication posture, sessions, and alerts.">
        <:actions>
          <button class="btn btn-outline" type="button" phx-click="lock-interface">Lock</button>
          <button :if={@locked?} class="btn" type="button" phx-click="unlock-interface">Unlock</button>
          <button class="btn btn-outline" type="button" phx-click="refresh-settings">Refresh</button>
        </:actions>
      </.header>

      <div class="grid gap-6 xl:grid-cols-[18rem_minmax(0,1fr)]">
        <aside class="space-y-4 rounded-2xl border border-zinc-200 bg-white p-4 shadow-sm">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.18em] text-zinc-400">Settings areas</p>
            <p class="mt-2 text-sm text-zinc-500">Separate account, security, session, notification, and privacy tasks so this page scales cleanly.</p>
          </div>

          <nav class="space-y-2">
            <.link :for={section <- @sections}
              navigate={settings_path(section.id)}
              class={section_nav_class(section.id, @current_section)}>
              <span class="text-sm font-semibold"><%= section.label %></span>
              <span class="mt-1 block text-xs font-normal leading-5 text-zinc-500"><%= section.description %></span>
            </.link>
          </nav>
        </aside>

        <div class="space-y-6">
          <div :if={@locked?} class="rounded-xl border border-dashed border-zinc-200 bg-zinc-50 p-6 text-center text-sm text-zinc-600">
            Settings are locked. Unlock to view account and security details.
          </div>

          <div :if={!@locked?}>
            <%= case @current_section do %>
              <% "profile" -> %>
                <.profile_section settings={@settings} profile_form={@profile_form} />
              <% "security" -> %>
                <.security_section settings={@settings} />
              <% "sessions" -> %>
                <.sessions_section settings={@settings} />
              <% "notifications" -> %>
                <.notifications_section notification_form={@notification_form} />
              <% "privacy" -> %>
                <.privacy_section settings={@settings} />
            <% end %>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :settings, :map, required: true
  attr :profile_form, :any, required: true

  defp profile_section(assigns) do
    ~H"""
    <section class="space-y-6">
      <div class="rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm">
        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.18em] text-zinc-400">Profile</p>
            <h2 class="mt-2 text-2xl font-semibold text-zinc-900"><%= @settings.profile.full_name %></h2>
            <p class="mt-1 text-sm text-zinc-500"><%= @settings.profile.email %></p>
          </div>
          <div class="grid gap-3 sm:grid-cols-2">
            <div class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
              <p class="text-xs font-semibold uppercase tracking-wide text-zinc-400">Role</p>
              <p class="mt-2 text-lg font-semibold capitalize text-zinc-900"><%= @settings.profile.role %></p>
            </div>
            <div class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
              <p class="text-xs font-semibold uppercase tracking-wide text-zinc-400">Last login</p>
              <p class="mt-2 text-sm font-medium text-zinc-900"><%= format_timestamp(@settings.security.last_login_at) %></p>
            </div>
          </div>
        </div>
      </div>

      <div class="grid gap-6 lg:grid-cols-2">
        <div class="rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm">
          <h3 class="text-lg font-semibold text-zinc-900">Account summary</h3>
          <dl class="mt-4 space-y-3 text-sm text-zinc-600">
            <div class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-3">
              <dt class="font-medium text-zinc-700">Full name</dt>
              <dd><%= @settings.profile.full_name %></dd>
            </div>
            <div class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-3">
              <dt class="font-medium text-zinc-700">Email</dt>
              <dd><%= @settings.profile.email %></dd>
            </div>
            <div class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-3">
              <dt class="font-medium text-zinc-700">Workspace role</dt>
              <dd class="capitalize"><%= @settings.profile.role %></dd>
            </div>
          </dl>
        </div>

        <div class="rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm">
          <h3 class="text-lg font-semibold text-zinc-900">Edit profile</h3>
          <.form
            for={@profile_form}
            id="profile-form"
            phx-change="validate-profile"
            phx-submit="save-profile"
            class="mt-4 space-y-4"
          >
            <.input field={@profile_form[:encrypted_full_name]} type={:text} label="Full name" />
            <.input field={@profile_form[:email]} type={:email} label="Email" />

            <div class="flex items-center justify-between gap-3">
              <p class="text-sm text-zinc-500">Use an address you can actually receive mail on for magic-link testing.</p>
              <button type="submit" class="btn">Save profile</button>
            </div>
          </.form>
        </div>
      </div>
    </section>
    """
  end

  attr :settings, :map, required: true

  defp security_section(assigns) do
    ~H"""
    <section class="space-y-6" id="security-settings" phx-hook="SecurityPasskeys">
      <div class="rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm">
        <p class="text-xs font-semibold uppercase tracking-[0.18em] text-zinc-400">Security</p>
        <h2 class="mt-2 text-2xl font-semibold text-zinc-900">Authentication posture</h2>
        <p class="mt-2 text-sm text-zinc-500">
          Password compatibility remains in place temporarily, but the security model is now moving toward email magic links, passkeys, and hardware security keys. This section shows what is already registered and exposes the foundation for the browser-side enrollment flow.
        </p>

        <div class="mt-6 grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          <div class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
            <p class="text-xs font-semibold uppercase tracking-wide text-zinc-400">Multi-factor auth</p>
            <p class="mt-2 text-lg font-semibold text-zinc-900">
              <%= if @settings.security.multi_factor_enabled, do: "Enabled", else: "Disabled" %>
            </p>
          </div>
          <div class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
            <p class="text-xs font-semibold uppercase tracking-wide text-zinc-400">Passkeys</p>
            <p class="mt-2 text-lg font-semibold text-zinc-900"><%= @settings.security.passkeys_count %></p>
          </div>
          <div class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
            <p class="text-xs font-semibold uppercase tracking-wide text-zinc-400">Security keys</p>
            <p class="mt-2 text-lg font-semibold text-zinc-900"><%= @settings.security.security_keys_count %></p>
          </div>
          <div class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
            <p class="text-xs font-semibold uppercase tracking-wide text-zinc-400">Magic links</p>
            <p class="mt-2 text-lg font-semibold text-zinc-900">
              <%= if @settings.security.magic_link_enabled, do: "Enabled", else: "Disabled" %>
            </p>
          </div>
        </div>

        <div class="mt-6 flex flex-wrap gap-3">
          <button class="btn" type="button" data-register-webauthn="passkey">Register passkey</button>
          <button class="btn btn-outline" type="button" data-register-webauthn="security_key">Register security key</button>
        </div>
        <p class="mt-3 text-sm text-zinc-500" data-webauthn-status></p>
      </div>

      <div class="grid gap-6 lg:grid-cols-2">
        <div class="rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm">
          <h3 class="text-lg font-semibold text-zinc-900">Current status</h3>
          <ul class="mt-4 space-y-3 text-sm text-zinc-600">
            <li class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-3">
              <span>Last login</span>
              <span class="font-medium text-zinc-900"><%= format_timestamp(@settings.security.last_login_at) %></span>
            </li>
            <li class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-3">
              <span>Password login</span>
              <span class="font-medium text-zinc-900"><%= if @settings.security.password_enabled, do: "Still enabled", else: "Disabled" %></span>
            </li>
            <li class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-3">
              <span>Last passkey added</span>
              <span class="font-medium text-zinc-900"><%= format_timestamp(@settings.security.last_passkey_registered_at) %></span>
            </li>
            <li class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-3">
              <span>Last security key added</span>
              <span class="font-medium text-zinc-900"><%= format_timestamp(@settings.security.last_security_key_registered_at) %></span>
            </li>
          </ul>
        </div>

        <div class="rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm">
          <h3 class="text-lg font-semibold text-zinc-900">Credential inventory</h3>
          <ul class="mt-4 space-y-3 text-sm text-zinc-600">
            <li :for={credential <- @settings.security.passkeys} class="rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-3">
              <div class="flex items-center justify-between gap-3">
                <div>
                  <p class="font-medium text-zinc-900"><%= credential.label %></p>
                  <p class="mt-1 text-xs uppercase tracking-wide text-zinc-500">Passkey</p>
                </div>
                <div class="flex items-center gap-3">
                  <span class="text-xs text-zinc-500"><%= format_timestamp(credential.inserted_at) %></span>
                  <button class="text-xs font-semibold text-zinc-700 underline" type="button" data-revoke-webauthn={credential.id}>Remove</button>
                </div>
              </div>
            </li>
            <li :for={credential <- @settings.security.security_keys} class="rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-3">
              <div class="flex items-center justify-between gap-3">
                <div>
                  <p class="font-medium text-zinc-900"><%= credential.label %></p>
                  <p class="mt-1 text-xs uppercase tracking-wide text-zinc-500">Security key</p>
                </div>
                <div class="flex items-center gap-3">
                  <span class="text-xs text-zinc-500"><%= format_timestamp(credential.inserted_at) %></span>
                  <button class="text-xs font-semibold text-zinc-700 underline" type="button" data-revoke-webauthn={credential.id}>Remove</button>
                </div>
              </div>
            </li>
            <li :if={Enum.empty?(@settings.security.passkeys) and Enum.empty?(@settings.security.security_keys)}
              class="rounded-lg border border-dashed border-zinc-200 bg-zinc-50 px-3 py-3">
              No passkeys or security keys are registered yet.
            </li>
          </ul>
        </div>
      </div>

      <div class="rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm">
        <h3 class="text-lg font-semibold text-zinc-900">Next controls</h3>
        <ul class="mt-4 space-y-3 text-sm text-zinc-600">
          <li class="rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-3">Server-side WebAuthn challenge storage is ready for browser enrollment and assertion flows.</li>
          <li class="rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-3">Password fallback stays available until passkeys, magic links, and hardware keys are proven reliable in real use.</li>
          <li class="rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-3">Recovery codes and step-up MFA can land next without changing the section structure again.</li>
        </ul>
      </div>
    </section>
    """
  end

  attr :settings, :map, required: true

  defp sessions_section(assigns) do
    ~H"""
    <section class="space-y-6">
      <div class="rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm">
        <p class="text-xs font-semibold uppercase tracking-[0.18em] text-zinc-400">Sessions & devices</p>
        <h2 class="mt-2 text-2xl font-semibold text-zinc-900">Recent access</h2>
        <p class="mt-2 text-sm text-zinc-500">Review where the account has been used recently. Session revocation and trusted-device controls can land here next without changing the page structure again.</p>
      </div>

      <div class="rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm">
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
              <td class="py-3 font-medium text-zinc-800"><%= session.context %></td>
              <td class="py-3 text-zinc-600"><%= format_timestamp(session.last_used_at) %></td>
              <td class="py-3 text-zinc-600"><%= session.ip_address || "Unknown" %></td>
              <td class="py-3 text-zinc-600"><%= session.user_agent || "Unknown" %></td>
            </tr>
            <tr :if={Enum.empty?(@settings.sessions)}>
              <td colspan="4" class="py-4 text-center text-zinc-500">No active sessions recorded.</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :notification_form, :any, required: true

  defp notifications_section(assigns) do
    ~H"""
    <section class="space-y-6">
      <div class="rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm">
        <p class="text-xs font-semibold uppercase tracking-[0.18em] text-zinc-400">Notifications</p>
        <h2 class="mt-2 text-2xl font-semibold text-zinc-900">Payment alerts</h2>
        <p class="mt-2 text-sm text-zinc-500">
          Control durable obligation reminders, dashboard visibility, and resend policy.
        </p>
      </div>

      <div class="rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm">
        <.form
          for={@notification_form}
          id="notification-preferences-form"
          phx-change="validate-notifications"
          phx-submit="save-notifications"
          class="space-y-5"
        >
          <div class="grid gap-4 md:grid-cols-2">
            <label class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 p-3 text-sm text-zinc-700">
              <span>Email delivery</span>
              <input type="hidden" name="notifications[email_enabled]" value="false" />
              <input type="checkbox" name="notifications[email_enabled]" value="true" checked={Phoenix.HTML.Form.normalize_value("checkbox", @notification_form[:email_enabled].value)} />
            </label>

            <label class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 p-3 text-sm text-zinc-700">
              <span>Show on dashboard</span>
              <input type="hidden" name="notifications[dashboard_enabled]" value="false" />
              <input type="checkbox" name="notifications[dashboard_enabled]" value="true" checked={Phoenix.HTML.Form.normalize_value("checkbox", @notification_form[:dashboard_enabled].value)} />
            </label>

            <label class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 p-3 text-sm text-zinc-700">
              <span>Upcoming reminders</span>
              <input type="hidden" name="notifications[upcoming_enabled]" value="false" />
              <input type="checkbox" name="notifications[upcoming_enabled]" value="true" checked={Phoenix.HTML.Form.normalize_value("checkbox", @notification_form[:upcoming_enabled].value)} />
            </label>

            <label class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 p-3 text-sm text-zinc-700">
              <span>Due today reminders</span>
              <input type="hidden" name="notifications[due_today_enabled]" value="false" />
              <input type="checkbox" name="notifications[due_today_enabled]" value="true" checked={Phoenix.HTML.Form.normalize_value("checkbox", @notification_form[:due_today_enabled].value)} />
            </label>

            <label class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 p-3 text-sm text-zinc-700">
              <span>Overdue reminders</span>
              <input type="hidden" name="notifications[overdue_enabled]" value="false" />
              <input type="checkbox" name="notifications[overdue_enabled]" value="true" checked={Phoenix.HTML.Form.normalize_value("checkbox", @notification_form[:overdue_enabled].value)} />
            </label>

            <label class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 p-3 text-sm text-zinc-700">
              <span>Recovered confirmations</span>
              <input type="hidden" name="notifications[recovered_enabled]" value="false" />
              <input type="checkbox" name="notifications[recovered_enabled]" value="true" checked={Phoenix.HTML.Form.normalize_value("checkbox", @notification_form[:recovered_enabled].value)} />
            </label>
          </div>

          <div class="grid gap-4 md:grid-cols-3">
            <.input field={@notification_form[:upcoming_lead_days]} type={:number} label="Upcoming lead days" min="0" />
            <.input field={@notification_form[:resend_interval_hours]} type={:number} label="Resend every (hours)" min="1" />
            <.input field={@notification_form[:max_resends]} type={:number} label="Maximum resends" min="0" />
          </div>

          <button type="submit" class="btn">Save alert preferences</button>
        </.form>
      </div>
    </section>
    """
  end

  attr :settings, :map, required: true

  defp privacy_section(assigns) do
    ~H"""
    <section class="space-y-6">
      <div class="rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm">
        <p class="text-xs font-semibold uppercase tracking-[0.18em] text-zinc-400">Data & privacy</p>
        <h2 class="mt-2 text-2xl font-semibold text-zinc-900">Data operations</h2>
        <p class="mt-2 text-sm text-zinc-500">This section reserves space for exports, retention controls, and privacy operations so those workflows do not sprawl into general settings later.</p>
      </div>

      <div class="grid gap-6 lg:grid-cols-2">
        <div class="rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm">
          <h3 class="text-lg font-semibold text-zinc-900">Export readiness</h3>
          <ul class="mt-4 space-y-3 text-sm text-zinc-600">
            <li class="rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-3">Transaction, budget, and obligation exports can land here without affecting the main app shell.</li>
            <li class="rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-3">Durable notification history should eventually link into this privacy area as part of user-data portability.</li>
          </ul>
        </div>

        <div class="rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm">
          <h3 class="text-lg font-semibold text-zinc-900">Current profile footprint</h3>
          <dl class="mt-4 space-y-3 text-sm text-zinc-600">
            <div class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-3">
              <dt class="font-medium text-zinc-700">Account email</dt>
              <dd><%= @settings.profile.email %></dd>
            </div>
            <div class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-3">
              <dt class="font-medium text-zinc-700">Active session count</dt>
              <dd><%= Enum.count(@settings.sessions) %></dd>
            </div>
          </dl>
        </div>
      </div>
    </section>
    """
  end

  defp load_settings(socket, current_user) do
    settings = Accounts.user_settings(current_user)
    preference = Notifications.get_alert_preference(current_user)
    profile_changeset = Accounts.change_user_profile(current_user)

    socket
    |> assign(:settings, settings)
    |> assign(:profile_form, to_form(profile_changeset, as: :profile))
    |> assign(
      :notification_form,
      to_form(Notifications.change_alert_preference(preference), as: :notifications)
    )
  end

  defp normalize_section(section) when is_binary(section) do
    if Enum.any?(@sections, &(&1.id == section)), do: section, else: "profile"
  end

  defp normalize_section(_section), do: "profile"

  defp settings_path("profile"), do: ~p"/app/settings"
  defp settings_path(section), do: ~p"/app/settings/#{section}"

  defp section_nav_class(section_id, current_section) do
    base = "block rounded-xl border px-3 py-3 transition-colors"

    if section_id == current_section do
      base <> " border-emerald-200 bg-emerald-50 text-zinc-900"
    else
      base <> " border-zinc-200 bg-white text-zinc-700 hover:bg-zinc-50"
    end
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
