defmodule MoneyTreeWeb.OwnerUsersLive.Index do
  @moduledoc """
  Owner-only user management: search, sort, role changes, and suspend/reactivate.
  """

  use MoneyTreeWeb, :live_view

  alias MoneyTree.Accounts
  alias MoneyTree.Users.User

  @per_page 50

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: current_user}} = socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Users",
       search: "",
       sort_key: :email,
       sort_direction: :asc,
       row_errors: %{},
       current_user: current_user
     )
     |> load_users()}
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, socket |> assign(:search, query) |> load_users()}
  end

  def handle_event("reset-search", _params, socket) do
    {:noreply, socket |> assign(:search, "") |> load_users()}
  end

  def handle_event("sort", %{"key" => key}, socket) do
    key = String.to_existing_atom(key)

    direction =
      if socket.assigns.sort_key == key and socket.assigns.sort_direction == :asc,
        do: :desc,
        else: :asc

    {:noreply,
     socket
     |> assign(sort_key: key, sort_direction: direction)
     |> sort_users()}
  end

  def handle_event("change-role", %{"_id" => id, "role" => role}, socket) do
    with {:ok, %User{} = user} <- Accounts.fetch_user(id),
         {:ok, role} <- parse_role(role),
         {:ok, %User{} = updated} <-
           Accounts.update_user_role(user, role, actor: socket.assigns.current_user) do
      {:noreply, socket |> put_user(updated) |> clear_row_error(id)}
    else
      _error ->
        {:noreply, put_row_error(socket, id, "Unable to update this user.")}
    end
  end

  def handle_event("toggle-suspension", %{"id" => id, "suspended" => suspended}, socket) do
    actor = socket.assigns.current_user

    result =
      case Accounts.fetch_user(id) do
        {:ok, %User{} = user} ->
          if suspended == "true" do
            Accounts.suspend_user(user, actor: actor)
          else
            Accounts.reactivate_user(user, actor: actor)
          end

        error ->
          error
      end

    case result do
      {:ok, %User{} = updated} ->
        {:noreply, socket |> put_user(updated) |> clear_row_error(id)}

      _error ->
        {:noreply, put_row_error(socket, id, "Unable to update this user.")}
    end
  end

  defp load_users(%{assigns: %{search: search}} = socket) do
    %{entries: users, metadata: metadata} =
      Accounts.paginate_users(search: blank_to_nil(search), per_page: @per_page)

    socket
    |> assign(users: users, metadata: metadata)
    |> sort_users()
  end

  defp sort_users(%{assigns: %{users: users, sort_key: key, sort_direction: direction}} = socket) do
    multiplier = if direction == :asc, do: 1, else: -1

    sorted =
      Enum.sort_by(
        users,
        &sort_value(&1, key),
        fn a, b -> multiplier * compare(a, b) <= 0 end
      )

    assign(socket, :sorted_users, sorted)
  end

  defp compare(a, b) when a < b, do: -1
  defp compare(a, b) when a > b, do: 1
  defp compare(_a, _b), do: 0

  defp sort_value(%User{} = user, :email), do: user.email
  defp sort_value(%User{} = user, :role), do: Atom.to_string(user.role)
  defp sort_value(%User{} = user, :suspended), do: if(user.suspended_at, do: 1, else: 0)
  defp sort_value(%User{} = user, :inserted_at), do: user.inserted_at
  defp sort_value(%User{} = user, :updated_at), do: user.updated_at

  defp put_user(%{assigns: %{users: users}} = socket, %User{} = updated) do
    users = Enum.map(users, fn user -> if user.id == updated.id, do: updated, else: user end)
    socket |> assign(:users, users) |> sort_users()
  end

  defp put_row_error(socket, id, message) do
    assign(socket, :row_errors, Map.put(socket.assigns.row_errors, id, message))
  end

  defp clear_row_error(socket, id) do
    assign(socket, :row_errors, Map.delete(socket.assigns.row_errors, id))
  end

  defp parse_role(role) when is_binary(role) do
    if role in Enum.map(User.roles(), &Atom.to_string/1) do
      {:ok, String.to_existing_atom(role)}
    else
      {:error, :invalid_role}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: if(String.trim(value) == "", do: nil, else: value)

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-6">
      <.header title="Users" subtitle="Search, sort, and update roles for every user connected to this workspace.">
        <:actions>
          <form phx-submit="search" class="flex items-center gap-2">
            <input type="search" name="q" value={@search} placeholder="Search by email..." class="input" />
            <button type="submit" class="btn btn-outline">Search</button>
            <button :if={@search != ""} type="button" class="btn btn-outline" phx-click="reset-search">Reset</button>
          </form>
        </:actions>
      </.header>

      <p class="rounded-xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-800">
        <span class="font-semibold"><%= @metadata.total_entries %> users in workspace.</span>
        Showing <%= length(@sorted_users) %> on this page.
      </p>

      <div class="overflow-x-auto rounded-2xl border border-zinc-200 bg-white shadow-sm">
        <table class="w-full table-auto text-left text-sm">
          <thead>
            <tr class="border-b border-zinc-200 text-xs uppercase tracking-wide text-zinc-500">
              <th class="py-3 pl-4 pr-3"><.sort_button label="Email" sort_key={:email} current={@sort_key} direction={@sort_direction} /></th>
              <th class="py-3 px-3"><.sort_button label="Role" sort_key={:role} current={@sort_key} direction={@sort_direction} /></th>
              <th class="py-3 px-3"><.sort_button label="Status" sort_key={:suspended} current={@sort_key} direction={@sort_direction} /></th>
              <th class="py-3 px-3"><.sort_button label="Created" sort_key={:inserted_at} current={@sort_key} direction={@sort_direction} /></th>
              <th class="py-3 px-3"><.sort_button label="Updated" sort_key={:updated_at} current={@sort_key} direction={@sort_direction} /></th>
              <th class="py-3 pr-4 text-right">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={user <- @sorted_users} class="border-b border-zinc-100 align-top">
              <td class="whitespace-nowrap py-3 pl-4 pr-3 font-medium text-zinc-900">
                <p><%= user.email %></p>
                <p :if={user.suspended_at} class="text-xs text-zinc-500">Suspended at <%= format_timestamp(user.suspended_at) %></p>
              </td>
              <td class="py-3 px-3">
                <form phx-change="change-role" id={"change-role-#{user.id}"}>
                  <input type="hidden" name="_id" value={user.id} />
                  <select name="role" class="input">
                    <option :for={role <- MoneyTree.Users.User.roles()} value={role} selected={role == user.role}>
                      <%= role %>
                    </option>
                  </select>
                </form>
              </td>
              <td class="py-3 px-3">
                <span class={status_badge_class(user.suspended_at)}>
                  <%= if user.suspended_at, do: "Suspended", else: "Active" %>
                </span>
              </td>
              <td class="py-3 px-3 text-zinc-600"><%= format_timestamp(user.inserted_at) %></td>
              <td class="py-3 px-3 text-zinc-600"><%= format_timestamp(user.updated_at) %></td>
              <td class="py-3 pr-4">
                <div class="flex flex-col items-end gap-2">
                  <button
                    type="button"
                    class="btn btn-outline"
                    phx-click="toggle-suspension"
                    phx-value-id={user.id}
                    phx-value-suspended={to_string(is_nil(user.suspended_at))}
                  >
                    <%= if user.suspended_at, do: "Reactivate", else: "Suspend" %>
                  </button>
                  <p :if={Map.get(@row_errors, user.id)} class="max-w-xs text-right text-xs text-rose-600" role="alert">
                    <%= Map.get(@row_errors, user.id) %>
                  </p>
                </div>
              </td>
            </tr>
            <tr :if={@sorted_users == []}>
              <td colspan="6" class="py-8 text-center text-sm text-zinc-500">No users match your filters.</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :sort_key, :atom, required: true
  attr :current, :atom, required: true
  attr :direction, :atom, required: true

  defp sort_button(assigns) do
    ~H"""
    <button type="button" phx-click="sort" phx-value-key={@sort_key} class="flex items-center gap-1 font-semibold text-zinc-600 hover:text-zinc-900">
      <%= @label %>
      <span :if={@sort_key == @current} class="text-xs text-zinc-400"><%= if @direction == :asc, do: "↑", else: "↓" %></span>
    </button>
    """
  end

  defp status_badge_class(nil),
    do:
      "inline-flex items-center rounded-full bg-emerald-100 px-3 py-1 text-xs font-semibold text-emerald-700"

  defp status_badge_class(_suspended_at),
    do:
      "inline-flex items-center rounded-full bg-rose-100 px-3 py-1 text-xs font-semibold text-rose-700"

  defp format_timestamp(nil), do: "—"

  defp format_timestamp(%DateTime{} = datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%b %d, %Y %H:%M UTC")
  rescue
    _ -> DateTime.to_string(datetime)
  end

  defp format_timestamp(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_string(datetime)
end
