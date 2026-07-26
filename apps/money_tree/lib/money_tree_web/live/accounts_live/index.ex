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
     |> assign(editing_account_id: nil, account_form: %{})
     |> assign(account_view: "categorized", account_sort: "name_asc")
     |> load_page(current_user)}
  end

  @impl true
  def handle_event("change-account-list-preferences", params, socket) do
    {:noreply,
     assign(socket,
       account_view: normalize_account_view(Map.get(params, "account_view")),
       account_sort: normalize_account_sort(Map.get(params, "account_sort"))
     )}
  end

  @impl true
  def handle_event(
        "edit-account",
        %{"id" => account_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    case Accounts.fetch_accessible_account(current_user, account_id) do
      {:ok, account} ->
        {:noreply,
         assign(socket,
           editing_account_id: account.id,
           account_form: account_form(account)
         )}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Account not found.")}
    end
  end

  def handle_event("cancel-edit-account", _params, socket) do
    {:noreply, assign(socket, editing_account_id: nil, account_form: %{})}
  end

  def handle_event("change-account-classification", %{"account" => params}, socket) do
    form =
      socket.assigns.account_form
      |> Map.merge(params)
      |> normalize_account_form()

    {:noreply, assign(socket, account_form: form)}
  end

  def handle_event(
        "update-account",
        %{"id" => account_id, "account" => params},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    case Accounts.update_owned_account(current_user, account_id, params) do
      {:ok, _account} ->
        {:noreply,
         socket
         |> assign(editing_account_id: nil, account_form: %{})
         |> load_page(current_user)
         |> put_flash(:info, "Account updated.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Account not found.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Account could not be updated.")}
    end
  end

  def handle_event(
        "delete-account",
        %{"id" => account_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    case Accounts.delete_owned_account(current_user, account_id) do
      {:ok, _account} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> put_flash(:info, "Account removed.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Account not found.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Account could not be removed.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-6">
      <.header title="Accounts & institutions" subtitle="Review linked institutions, connected accounts, and sync health.">
        <:actions>
          <a href="/app/react/link-bank" class="btn btn-outline">Manage institutions</a>
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
          <p class="text-xs text-zinc-500">Last synced <%= latest_sync_label(@connections) %></p>
        </div>
      </div>

      <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
        <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
          <div>
            <h2 class="text-lg font-semibold text-zinc-900">Connected accounts</h2>
            <p class="text-sm text-zinc-500">Account balances by MoneyTree classification, institution, and balance.</p>
          </div>

          <form id="account-list-preferences-form"
                phx-change="change-account-list-preferences"
                class="grid gap-3 sm:grid-cols-2 md:w-[25rem]">
            <label class="space-y-1">
              <span class="text-xs font-medium uppercase tracking-wide text-zinc-500">View</span>
              <select name="account_view"
                      class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900">
                <option value="categorized" selected={@account_view == "categorized"}>Categorized</option>
                <option value="list" selected={@account_view == "list"}>List</option>
              </select>
            </label>
            <label class="space-y-1">
              <span class="text-xs font-medium uppercase tracking-wide text-zinc-500">Sort</span>
              <select name="account_sort"
                      class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900">
                <option value="name_asc" selected={@account_sort == "name_asc"}>Name A-Z</option>
                <option value="name_desc" selected={@account_sort == "name_desc"}>Name Z-A</option>
                <option value="balance_desc" selected={@account_sort == "balance_desc"}>Balance high-low</option>
                <option value="balance_asc" selected={@account_sort == "balance_asc"}>Balance low-high</option>
              </select>
            </label>
          </form>
        </div>

        <div :if={@account_view == "categorized"} class="space-y-5">
          <section :for={group <- grouped_account_summaries(@summary.accounts, @account_sort)}
                   class={["grid gap-3 rounded-2xl border p-3 lg:grid-cols-[8rem_minmax(0,1fr)]", group.container_class]}>
            <div class={["flex min-h-28 flex-row items-center gap-3 rounded-xl px-4 py-3 lg:flex-col lg:items-start lg:justify-between", group.visual_class]}>
              <div>
                <div class="text-4xl leading-none" aria-hidden="true"><%= group.emoji %></div>
                <h3 class="mt-2 text-sm font-semibold uppercase tracking-wide text-white">
                  <%= group.label %>
                </h3>
                <p class="mt-1 text-xs font-medium text-white/80"><%= pluralize_accounts(group.count) %></p>
              </div>
              <div class="ml-auto text-right lg:ml-0 lg:text-left">
                <p class="text-[11px] font-semibold uppercase tracking-wide text-white/70">Category</p>
                <p class="text-xs font-medium text-white/90"><%= group.balance_sheet_label %></p>
              </div>
            </div>

            <div class="min-w-0 space-y-3">
              <ul class="space-y-3">
                <.account_list_item :for={account_summary <- group.accounts}
                                    account_summary={account_summary}
                                    editing_account_id={@editing_account_id}
                                    account_form={@account_form} />
              </ul>

              <div class="rounded-xl border border-zinc-200 bg-white p-4">
                <div class="grid gap-3 lg:grid-cols-[minmax(0,1fr)_12rem_5.5rem] lg:items-end">
                  <div class="min-w-0">
                    <p class="text-xs font-semibold uppercase tracking-wide text-zinc-500">Category total</p>
                    <p class="mt-1 text-sm text-zinc-500"><%= group.label %> subtotal across visible accounts</p>
                  </div>
                  <dl class="grid gap-2 text-sm lg:col-start-2">
                    <div :for={total <- group.totals}
                         class="rounded-lg bg-zinc-50 px-3 py-2 text-right">
                      <dt class="text-xs uppercase tracking-wide text-zinc-500"><%= total.currency %> current</dt>
                      <dd class="mt-1 font-semibold text-zinc-900"><%= total.current_balance %></dd>
                      <dt class="mt-2 text-xs uppercase tracking-wide text-zinc-500"><%= total.currency %> available</dt>
                      <dd class="mt-1 font-medium text-zinc-700"><%= total.available_balance %></dd>
                    </div>
                  </dl>
                  <div class="hidden lg:block" aria-hidden="true"></div>
                </div>
              </div>
            </div>
          </section>

          <div :if={Enum.empty?(@summary.accounts)} class="rounded-xl border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
            No accounts are available yet.
          </div>
        </div>

        <ul :if={@account_view == "list"} class="space-y-3">
          <.account_list_item :for={account_summary <- sorted_account_summaries(@summary.accounts, @account_sort)}
                              account_summary={account_summary}
                              editing_account_id={@editing_account_id}
                              account_form={@account_form} />

          <li :if={Enum.empty?(@summary.accounts)} class="rounded-xl border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
            No accounts are available yet.
          </li>
        </ul>
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

  defp normalize_account_view("list"), do: "list"
  defp normalize_account_view(_view), do: "categorized"

  defp normalize_account_sort(sort)
       when sort in ["name_asc", "name_desc", "balance_desc", "balance_asc"],
       do: sort

  defp normalize_account_sort(_sort), do: "name_asc"

  defp grouped_account_summaries(account_summaries, sort) do
    account_summaries
    |> sorted_account_summaries(sort)
    |> Enum.group_by(&canonical_account_kind(&1.account))
    |> Enum.sort_by(fn {kind, _accounts} -> account_kind_position(kind) end)
    |> Enum.map(fn {kind, accounts} ->
      visual = account_kind_visual(kind)

      %{
        kind: kind,
        label: Accounts.account_kind_label(kind),
        count: length(accounts),
        accounts: accounts,
        totals: category_totals(accounts),
        emoji: visual.emoji,
        container_class: visual.container_class,
        visual_class: visual.visual_class,
        balance_sheet_label: visual.balance_sheet_label
      }
    end)
  end

  defp category_totals(account_summaries) do
    account_summaries
    |> Enum.group_by(&(&1.account.currency || "USD"))
    |> Enum.map(fn {currency, summaries} ->
      current_balance =
        summaries
        |> Enum.map(&normalize_decimal(&1.account.current_balance))
        |> sum_decimals()

      available_balance =
        summaries
        |> Enum.map(&normalize_decimal(&1.account.available_balance))
        |> sum_decimals()

      %{
        currency: currency,
        current_balance: Accounts.format_money(current_balance, currency, []),
        available_balance: Accounts.format_money(available_balance, currency, [])
      }
    end)
    |> Enum.sort_by(& &1.currency)
  end

  defp sum_decimals(decimals) do
    Enum.reduce(decimals, Decimal.new("0"), &Decimal.add/2)
  end

  defp normalize_decimal(%Decimal{} = value), do: value
  defp normalize_decimal(nil), do: Decimal.new("0")
  defp normalize_decimal(value), do: Decimal.new(to_string(value))

  defp account_kind_visual("checking") do
    %{
      emoji: "👛",
      balance_sheet_label: "Operating cash",
      container_class: "border-emerald-100 bg-emerald-50/40",
      visual_class: "bg-gradient-to-br from-emerald-500 to-teal-600"
    }
  end

  defp account_kind_visual("savings") do
    %{
      emoji: "💵",
      balance_sheet_label: "Cash reserves",
      container_class: "border-lime-100 bg-lime-50/50",
      visual_class: "bg-gradient-to-br from-lime-500 to-emerald-600"
    }
  end

  defp account_kind_visual("credit_card") do
    %{
      emoji: "💳",
      balance_sheet_label: "Revolving debt",
      container_class: "border-rose-100 bg-rose-50/40",
      visual_class: "bg-gradient-to-br from-rose-500 to-pink-600"
    }
  end

  defp account_kind_visual("loan") do
    %{
      emoji: "🚗",
      balance_sheet_label: "Installment debt",
      container_class: "border-orange-100 bg-orange-50/40",
      visual_class: "bg-gradient-to-br from-orange-500 to-amber-600"
    }
  end

  defp account_kind_visual("mortgage") do
    %{
      emoji: "🏠",
      balance_sheet_label: "Real estate debt",
      container_class: "border-sky-100 bg-sky-50/40",
      visual_class: "bg-gradient-to-br from-sky-500 to-blue-600"
    }
  end

  defp account_kind_visual("cash") do
    %{
      emoji: "💰",
      balance_sheet_label: "Cash on hand",
      container_class: "border-yellow-100 bg-yellow-50/40",
      visual_class: "bg-gradient-to-br from-yellow-500 to-amber-600"
    }
  end

  defp account_kind_visual("investment") do
    %{
      emoji: "📈",
      balance_sheet_label: "Invested assets",
      container_class: "border-cyan-100 bg-cyan-50/40",
      visual_class: "bg-gradient-to-br from-cyan-500 to-indigo-600"
    }
  end

  defp account_kind_visual("escrow") do
    %{
      emoji: "🏦",
      balance_sheet_label: "Escrow reserves",
      container_class: "border-violet-100 bg-violet-50/40",
      visual_class: "bg-gradient-to-br from-violet-500 to-fuchsia-600"
    }
  end

  defp account_kind_visual(_kind) do
    %{
      emoji: "🗂️",
      balance_sheet_label: "Unclassified",
      container_class: "border-zinc-200 bg-zinc-50",
      visual_class: "bg-gradient-to-br from-zinc-500 to-slate-600"
    }
  end

  defp pluralize_accounts(1), do: "1 account"
  defp pluralize_accounts(count), do: "#{count} accounts"

  defp sorted_account_summaries(account_summaries, "name_desc") do
    Enum.sort_by(account_summaries, &account_sort_name/1, :desc)
  end

  defp sorted_account_summaries(account_summaries, "balance_desc") do
    Enum.sort(account_summaries, &balance_desc?/2)
  end

  defp sorted_account_summaries(account_summaries, "balance_asc") do
    Enum.sort(account_summaries, &balance_asc?/2)
  end

  defp sorted_account_summaries(account_summaries, _sort) do
    Enum.sort_by(account_summaries, &account_sort_name/1, :asc)
  end

  defp account_sort_name(%{account: account}) do
    account.name
    |> to_string()
    |> String.downcase()
  end

  defp balance_desc?(left, right) do
    case Decimal.compare(left.account.current_balance, right.account.current_balance) do
      :gt -> true
      :lt -> false
      :eq -> account_sort_name(left) <= account_sort_name(right)
    end
  end

  defp balance_asc?(left, right) do
    case Decimal.compare(left.account.current_balance, right.account.current_balance) do
      :lt -> true
      :gt -> false
      :eq -> account_sort_name(left) <= account_sort_name(right)
    end
  end

  defp canonical_account_kind(account) do
    account.internal_account_kind ||
      account
      |> Accounts.account_kind_label()
      |> String.downcase()
      |> String.replace(" ", "_")
  end

  defp account_kind_position(kind) do
    Accounts.account_kind_options()
    |> Enum.map(&elem(&1, 1))
    |> Enum.find_index(&(&1 == kind))
    |> case do
      nil -> 999
      index -> index
    end
  end

  defp latest_sync_label(connections) do
    connections
    |> Enum.map(& &1.last_synced_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&DateTime.to_unix/1, fn -> nil end)
    |> case do
      nil -> "not yet"
      %DateTime{} = value -> format_datetime(value)
    end
  end

  defp account_form(account) do
    normalize_account_form(%{
      "name" => account.name || "",
      "internal_account_kind" => account.internal_account_kind || inferred_account_kind(account),
      "liability_type" => account.liability_type || default_liability_type(account)
    })
  end

  defp normalize_account_form(form) do
    kind = Map.get(form, "internal_account_kind", "other")

    liability_type =
      if Accounts.liability_account_kind?(kind) do
        Map.get(form, "liability_type") || default_liability_type(kind)
      end

    form
    |> Map.put("internal_account_kind", kind)
    |> Map.put("liability_type", liability_type)
  end

  defp inferred_account_kind(account) do
    account
    |> Accounts.account_kind_label()
    |> String.downcase()
    |> String.replace(" ", "_")
  end

  defp default_liability_type(%{liability_type: liability_type})
       when is_binary(liability_type) and liability_type != "" do
    liability_type
  end

  defp default_liability_type(%{internal_account_kind: kind}), do: default_liability_type(kind)
  defp default_liability_type("credit_card"), do: "credit_card"
  defp default_liability_type("mortgage"), do: "mortgage"
  defp default_liability_type(kind) when kind in ["loan", nil], do: "other_loan"
  defp default_liability_type(_kind), do: nil

  attr :account_summary, :map, required: true
  attr :editing_account_id, :string, default: nil
  attr :account_form, :map, required: true

  defp account_list_item(assigns) do
    ~H"""
    <li class="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
      <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_12rem_5.5rem] lg:items-start">
        <div class="min-w-0 flex-1">
          <p class="font-semibold text-zinc-900"><%= @account_summary.account.name %></p>
          <p class="text-xs text-zinc-500">
            <%= Accounts.account_kind_label(@account_summary.account) %>
            <%= if @account_summary.account.institution do %>
              • <%= @account_summary.account.institution.name %>
            <% end %>
          </p>
        </div>
        <div class="text-right">
          <p class="font-semibold text-zinc-900"><%= @account_summary.current_balance %></p>
          <p class="text-xs text-zinc-500">Available <%= @account_summary.available_balance %></p>
        </div>
        <div class="flex justify-end gap-2 lg:w-[5.5rem]">
          <div :if={@editing_account_id != @account_summary.account.id} class="flex gap-2">
            <.action_icon icon="edit_note"
                          label={"Edit #{@account_summary.account.name}"}
                          event="edit-account"
                          value={@account_summary.account.id} />
            <.action_icon icon="delete"
                          label={"Remove #{@account_summary.account.name}"}
                          event="delete-account"
                          value={@account_summary.account.id}
                          confirm="Remove this account and its transactions from MoneyTree?" />
          </div>
        </div>
      </div>
      <form :if={@editing_account_id == @account_summary.account.id}
            id={"account-edit-form-#{@account_summary.account.id}"}
            phx-submit="update-account"
            phx-change="change-account-classification"
            phx-value-id={@account_summary.account.id}
            class="mt-4 grid gap-3 rounded-lg border border-zinc-200 bg-white p-3 text-sm">
        <label class="space-y-1">
          <span class="text-xs font-medium uppercase tracking-wide text-zinc-500">Name</span>
          <input name="account[name]"
                 value={@account_form["name"]}
                 class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-zinc-900" />
        </label>
        <div class="grid gap-3 sm:grid-cols-2">
          <label class="space-y-1">
            <span class="text-xs font-medium uppercase tracking-wide text-zinc-500">Account category</span>
            <select name="account[internal_account_kind]"
                    class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-zinc-900">
              <option :for={{label, value} <- Accounts.account_kind_options()}
                      value={value}
                      selected={@account_form["internal_account_kind"] == value}>
                <%= label %>
              </option>
            </select>
          </label>
          <label :if={Accounts.liability_account_kind?(@account_form["internal_account_kind"])}
                 class="space-y-1">
            <span class="text-xs font-medium uppercase tracking-wide text-zinc-500">Liability type</span>
            <select name="account[liability_type]"
                    class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-zinc-900">
              <option :for={{label, value} <- Accounts.liability_type_options()}
                      value={value}
                      selected={@account_form["liability_type"] == value}>
                <%= label %>
              </option>
            </select>
          </label>
        </div>
        <div class="flex justify-end gap-2">
          <button type="button" class="btn btn-ghost" phx-click="cancel-edit-account">Cancel</button>
          <button type="submit" class="btn btn-outline">Save</button>
        </div>
      </form>
    </li>
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :event, :string, required: true
  attr :value, :string, required: true
  attr :confirm, :string, default: nil

  defp action_icon(assigns) do
    ~H"""
    <button type="button"
            class="inline-flex h-8 w-8 items-center justify-center rounded-md border border-emerald-900/60 bg-white text-emerald-900 hover:bg-emerald-50 disabled:cursor-not-allowed disabled:opacity-50"
            phx-click={@event}
            phx-value-id={@value}
            aria-label={@label}
            title={@label}
            data-confirm={@confirm}>
      <.action_icon_svg icon={@icon} />
    </button>
    """
  end

  attr :icon, :string, required: true

  defp action_icon_svg(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24"
         class="h-4 w-4"
         fill="none"
         stroke="currentColor"
         stroke-width="2"
         stroke-linecap="round"
         stroke-linejoin="round"
         aria-hidden="true">
      <g :if={@icon == "edit_note"}>
        <path d="M4 20h4l10.5-10.5a2.1 2.1 0 0 0-3-3L5 17v3Z" />
        <path d="M13.5 7.5l3 3" />
      </g>
      <g :if={@icon == "delete"}>
        <path d="M4 7h16" />
        <path d="M10 11v6" />
        <path d="M14 11v6" />
        <path d="M6 7l1 13h10l1-13" />
        <path d="M9 7V4h6v3" />
      </g>
    </svg>
    """
  end

  defp format_datetime(%DateTime{} = value) do
    Calendar.strftime(value, "%b %-d, %Y %I:%M %p")
  end
end
