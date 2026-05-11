defmodule MoneyTreeWeb.AssetsLive.Index do
  @moduledoc """
  LiveView for managing tangible assets outside the dashboard.
  """

  use MoneyTreeWeb, :live_view

  alias MoneyTree.Accounts
  alias MoneyTree.Assets
  alias MoneyTree.Assets.Asset

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: current_user}} = socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Assets",
       asset_form_open?: false,
       asset_form_mode: :new,
       asset_editing_asset: nil,
       asset_changeset: Assets.change_asset(%Asset{}),
       asset_accounts: []
     )
     |> load_page(current_user)}
  end

  @impl true
  def handle_event("new-asset", _params, socket) do
    {:noreply,
     assign(socket,
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
        {:noreply,
         assign(socket,
           asset_form_open?: true,
           asset_form_mode: :edit,
           asset_editing_asset: asset,
           asset_changeset: Assets.change_asset(asset)
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
         |> load_page(current_user)
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
        %{
          assigns: %{
            current_user: current_user,
            asset_form_mode: :edit,
            asset_editing_asset: %Asset{} = asset
          }
        } = socket
      ) do
    case Assets.update_asset(current_user, asset, params, preload: [:account]) do
      {:ok, _asset} ->
        {:noreply,
         socket
         |> load_page(current_user)
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
       |> load_page(current_user)
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
    <section class="space-y-6">
      <.header title="Assets" subtitle="Track and manage tangible assets separately from the dashboard.">
        <:actions>
          <button type="button" class="btn btn-outline" phx-click="new-asset">Add asset</button>
        </:actions>
      </.header>

      <div class="grid gap-4 lg:grid-cols-3">
        <div class="rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Tracked assets</p>
          <p class="mt-1 text-2xl font-semibold text-zinc-900"><%= @asset_summary.total_count %></p>
          <p class="text-xs text-zinc-500">Tangible holdings under management</p>
        </div>

        <div class="rounded-xl border border-zinc-200 bg-white p-4 shadow-sm lg:col-span-2">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Valuation totals</p>
          <div class="mt-3 grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            <div :for={total <- @asset_summary.totals} class="rounded-lg bg-zinc-50 px-3 py-2">
              <p class="text-xs text-zinc-500"><%= total.currency %> • <%= total.asset_count %> assets</p>
              <p class="mt-1 font-semibold text-zinc-900"><%= total.valuation %></p>
            </div>
            <p :if={Enum.empty?(@asset_summary.totals)} class="text-sm text-zinc-500">
              Totals appear after at least one valuation is recorded.
            </p>
          </div>
        </div>
      </div>

      <div class="grid gap-6 xl:grid-cols-[minmax(0,1.35fr)_minmax(0,1fr)]">
        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <div>
            <h2 class="text-lg font-semibold text-zinc-900">Asset inventory</h2>
            <p class="text-sm text-zinc-500">Update valuations, ownership details, and supporting references.</p>
          </div>

          <ul class="space-y-3">
            <li :for={summary <- @asset_summary.assets}
                id={"asset-#{summary.asset.id}"}
                class="space-y-3 rounded-xl border border-zinc-100 bg-zinc-50 p-4">
              <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
                <div>
                  <p class="font-semibold text-zinc-900"><%= summary.asset.name %></p>
                  <p class="text-xs text-zinc-500">
                    <%= summary.asset.asset_type %>
                    <%= if summary.asset.category, do: " • #{summary.asset.category}" %>
                    • <%= asset_account_name(summary.asset) %>
                  </p>
                </div>

                <div class="text-right">
                  <p class="font-semibold text-zinc-900"><%= summary.valuation %></p>
                  <p class="text-xs text-zinc-500"><%= summary.asset.ownership_type %></p>
                </div>
              </div>

              <div class="flex flex-wrap gap-3 text-xs text-zinc-500">
                <span :if={summary.asset.location}><%= summary.asset.location %></span>
                <span :if={summary.asset.acquired_on}>Acquired <%= format_date(summary.asset.acquired_on) %></span>
                <span :if={summary.asset.last_valued_on}>Last valued <%= format_date(summary.asset.last_valued_on) %></span>
              </div>

              <p :if={summary.asset.notes} class="text-sm text-zinc-600"><%= summary.asset.notes %></p>

              <p :if={not Enum.empty?(summary.asset.document_refs)} class="text-xs text-zinc-500">
                Documents: <%= Enum.join(summary.asset.document_refs, ", ") %>
              </p>

              <div class="flex justify-end gap-2">
                <button type="button" class="btn btn-outline" phx-click="edit-asset" phx-value-id={summary.asset.id}>
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

            <li :if={Enum.empty?(@asset_summary.assets)} class="rounded-xl border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
              No assets tracked yet. Add your first asset to include it in household net-worth reporting.
            </li>
          </ul>
        </div>

        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <div class="flex items-start justify-between gap-3">
            <div>
              <h2 class="text-lg font-semibold text-zinc-900">
                <%= if @asset_form_mode == :edit, do: "Edit asset", else: "Add asset" %>
              </h2>
              <p class="text-sm text-zinc-500">Record valuations and attach each asset to a funding account.</p>
            </div>
            <button :if={@asset_form_open?} type="button" class="btn btn-outline" phx-click="cancel-asset">
              Cancel
            </button>
          </div>

          <div :if={!@asset_form_open?} class="rounded-xl border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
            Choose “Add asset” to create a new record, or edit an existing asset from the inventory list.
          </div>

          <.simple_form :if={@asset_form_open?}
                        for={@asset_changeset}
                        id="asset-form"
                        phx-change="validate-asset"
                        phx-submit="save-asset"
                        :let={f}>
            <div class="grid gap-4">
              <div>
                <label class="text-sm font-medium text-zinc-700" for="asset_account_id">Account</label>
                <select id="asset_account_id" name="asset[account_id]" class="input">
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
                <input id="asset_acquired_on" name="asset[acquired_on]" type="date" value={format_input_date(f[:acquired_on].value)} class="input" />
                <p :for={error <- errors_on(@asset_changeset, :acquired_on)} class="text-sm text-red-600"><%= error %></p>
              </div>

              <div>
                <label class="text-sm font-medium text-zinc-700" for="asset_last_valued_on">Last valued on</label>
                <input id="asset_last_valued_on" name="asset[last_valued_on]" type="date" value={format_input_date(f[:last_valued_on].value)} class="input" />
                <p :for={error <- errors_on(@asset_changeset, :last_valued_on)} class="text-sm text-red-600"><%= error %></p>
              </div>

              <.input field={f[:documents_text]}
                      label="Document references"
                      type={:textarea}
                      placeholder="Enter document references separated by commas or new lines" />
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
    </section>
    """
  end

  defp load_page(socket, current_user) do
    assign(socket,
      asset_summary: Assets.dashboard_summary(current_user, preload: [:account]),
      asset_accounts: Accounts.list_accessible_accounts(current_user, order_by: {:asc, :name})
    )
  end

  defp reset_asset_form(socket) do
    assign(socket,
      asset_form_open?: false,
      asset_form_mode: :new,
      asset_editing_asset: nil,
      asset_changeset: Assets.change_asset(%Asset{})
    )
  end

  defp maybe_reset_form_for_deleted(socket, asset_id) do
    case socket.assigns.asset_editing_asset do
      %Asset{id: ^asset_id} -> reset_asset_form(socket)
      _ -> socket
    end
  end

  defp asset_account_options(accounts) do
    Enum.map(accounts, &{&1.name, &1.id})
  end

  defp asset_account_name(%Asset{account: %{name: name}}) when is_binary(name), do: name
  defp asset_account_name(%Asset{}), do: "Unlinked account"

  defp errors_on(changeset, field) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Map.get(field, [])
  end

  defp format_input_date(nil), do: nil
  defp format_input_date(%Date{} = value), do: Date.to_iso8601(value)
  defp format_input_date(value) when is_binary(value), do: value
  defp format_input_date(_value), do: nil

  defp format_date(%Date{} = value), do: Calendar.strftime(value, "%b %-d, %Y")
  defp format_date(_value), do: nil
end
