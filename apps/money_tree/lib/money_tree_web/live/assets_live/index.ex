defmodule MoneyTreeWeb.AssetsLive.Index do
  @moduledoc """
  LiveView for managing tangible assets outside the dashboard.
  """

  use MoneyTreeWeb, :live_view

  alias Decimal
  alias MoneyTree.Accounts
  alias MoneyTree.Assets
  alias MoneyTree.Assets.Asset
  alias MoneyTree.Assets.ProviderRegistry
  alias MoneyTree.Assets.VehicleProfile
  alias MoneyTree.Loans
  alias MoneyTree.Mortgages

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: current_user}} = socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Assets",
       asset_form_open?: false,
       asset_form_mode: :new,
       asset_editing_asset: nil,
       asset_form_type: "vehicle",
       asset_changeset: new_asset_changeset(current_user, "vehicle"),
       vehicle_onboarding: empty_vehicle_onboarding(),
       vehicle_preview: nil,
       vehicle_preview_error: nil,
       asset_accounts: [],
       asset_loans: [],
       asset_mortgages: [],
       selected_asset: nil,
       asset_valuations: [],
       valuation_changeset: nil,
       vehicle_profile_changeset: nil
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
       asset_form_type: "vehicle",
       asset_changeset: new_asset_changeset(socket.assigns.current_user, "vehicle"),
       vehicle_onboarding: empty_vehicle_onboarding(),
       vehicle_preview: nil,
       vehicle_preview_error: nil
     )}
  end

  def handle_event("cancel-asset", _params, socket) do
    {:noreply, reset_asset_form(socket)}
  end

  def handle_event(
        "select-asset-type",
        %{"asset_setup" => %{"type" => type}},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    type = if type in Asset.asset_types(), do: type, else: "other"

    {:noreply,
     assign(socket,
       asset_form_type: type,
       asset_changeset: new_asset_changeset(current_user, type),
       vehicle_preview: nil,
       vehicle_preview_error: nil
     )}
  end

  def handle_event(
        "preview-vehicle",
        %{"vehicle" => params},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    vehicle_onboarding = Map.take(params, ["vin", "mileage", "market_region"])

    case Assets.preview_vehicle(current_user, vehicle_onboarding) do
      {:ok, preview} ->
        {:noreply,
         assign(socket,
           vehicle_onboarding: vehicle_onboarding,
           vehicle_preview: preview,
           vehicle_preview_error: nil,
           marketcheck_usage: Assets.provider_usage("marketcheck"),
           asset_changeset: vehicle_preview_changeset(current_user, preview)
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           vehicle_onboarding: vehicle_onboarding,
           vehicle_preview: nil,
           vehicle_preview_error: vehicle_preview_error(reason),
           marketcheck_usage: Assets.provider_usage("marketcheck")
         )}
    end
  end

  def handle_event("edit-vehicle-lookup", _params, socket) do
    {:noreply,
     assign(socket,
       vehicle_preview: nil,
       vehicle_preview_error: nil,
       asset_changeset: new_asset_changeset(socket.assigns.current_user, "vehicle")
     )}
  end

  def handle_event(
        "confirm-vehicle",
        %{"asset" => params},
        %{
          assigns: %{
            current_user: current_user,
            vehicle_preview: preview
          }
        } = socket
      )
      when is_map(preview) do
    case Assets.create_vehicle_from_preview(current_user, preview, params) do
      {:ok, _asset} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> reset_asset_form()
         |> put_flash(:info, "Vehicle added from the reviewed MarketCheck estimate.")}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> assign(asset_form_open?: true)
         |> put_flash(:error, "You do not have permission to use that linked account or debt.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           asset_form_open?: true,
           asset_changeset: Map.put(changeset, :action, :validate)
         )}
    end
  end

  def handle_event("confirm-vehicle", _params, socket) do
    {:noreply,
     socket
     |> assign(vehicle_preview_error: "That preview expired. Look up the VIN again.")
     |> put_flash(:error, "Please review the vehicle before adding it.")}
  end

  def handle_event(
        "view-asset",
        %{"id" => asset_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    {:noreply, load_asset_detail(socket, current_user, asset_id)}
  end

  def handle_event("close-asset-detail", _params, socket) do
    {:noreply,
     assign(socket,
       selected_asset: nil,
       asset_valuations: [],
       valuation_changeset: nil,
       vehicle_profile_changeset: nil
     )}
  end

  def handle_event(
        "link-asset-debt",
        %{"asset" => params},
        %{
          assigns: %{
            current_user: current_user,
            selected_asset: %Asset{} = asset
          }
        } = socket
      ) do
    params = debt_link_params(asset, params)

    case Assets.update_asset(current_user, asset, params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> load_asset_detail(current_user, updated.id)
         |> put_flash(:info, "Linked debt updated.")}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to link that debt record.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Unable to update the linked debt.")}
    end
  end

  def handle_event(
        "validate-valuation",
        %{"asset_valuation" => params},
        %{assigns: %{selected_asset: %Asset{} = asset}} = socket
      ) do
    changeset =
      asset
      |> Assets.change_asset_valuation(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, valuation_changeset: changeset)}
  end

  def handle_event(
        "record-valuation",
        %{"asset_valuation" => params},
        %{assigns: %{current_user: current_user, selected_asset: %Asset{} = asset}} = socket
      ) do
    case Assets.record_valuation(current_user, asset, manual_valuation_params(params)) do
      {:ok, %{asset: updated}} ->
        {:noreply,
         socket
         |> load_page(current_user)
         |> load_asset_detail(current_user, updated.id)
         |> put_flash(:info, "Valuation recorded without replacing prior history.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, valuation_changeset: Map.put(changeset, :action, :validate))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to value that asset.")}
    end
  end

  def handle_event(
        "validate-vehicle-profile",
        %{"vehicle_profile" => params},
        %{assigns: %{selected_asset: %Asset{} = asset}} = socket
      ) do
    profile = selected_vehicle_profile(asset)

    changeset =
      profile
      |> Assets.change_vehicle_profile(Map.put(params, "asset_id", asset.id))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, vehicle_profile_changeset: changeset)}
  end

  def handle_event(
        "save-vehicle-profile",
        %{"vehicle_profile" => params},
        %{assigns: %{current_user: current_user, selected_asset: %Asset{} = asset}} = socket
      ) do
    case Assets.upsert_vehicle_profile(current_user, asset, params) do
      {:ok, _profile} ->
        _enqueue_result = Assets.enqueue_vehicle_valuation_refresh(asset)

        {:noreply,
         socket
         |> load_page(current_user)
         |> load_asset_detail(current_user, asset.id)
         |> put_flash(:info, "Vehicle details saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, vehicle_profile_changeset: Map.put(changeset, :action, :validate))}

      {:error, :not_vehicle} ->
        {:noreply, put_flash(socket, :error, "Vehicle details only apply to vehicle assets.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to update that asset.")}
    end
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
           asset_form_type: asset.asset_type,
           vehicle_preview: nil,
           vehicle_preview_error: nil,
           asset_changeset: Assets.change_asset(asset)
         )}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Asset not found or no longer accessible.")}
    end
  end

  def handle_event("validate-asset", %{"asset" => params}, socket) do
    base_asset = socket.assigns.asset_editing_asset || %Asset{}
    asset_form_type = Map.get(params, "asset_type", socket.assigns.asset_form_type)

    changeset =
      base_asset
      |> Assets.change_asset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     assign(socket,
       asset_changeset: changeset,
       asset_form_open?: true,
       asset_form_type: asset_form_type
     )}
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

      <div id="marketcheck-status" class="rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
        <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <p class="text-sm font-semibold text-zinc-900">MarketCheck vehicle valuations</p>
            <p :if={@marketcheck_configured?} class="text-xs text-zinc-500">
              Enabled • vehicle onboarding uses two requests • later value refreshes use at most one request per vehicle every 7 days
            </p>
            <p :if={!@marketcheck_configured?} class="text-xs text-zinc-500">
              Disabled until both MARKETCHECK_ENABLED and the API key are configured.
            </p>
          </div>
          <div class="text-sm text-zinc-700">
            <strong><%= @marketcheck_usage.used %>/<%= @marketcheck_usage.limit %></strong>
            requests used this month
            <span class="text-xs text-zinc-500">(<%= @marketcheck_usage.remaining %> remaining)</span>
          </div>
        </div>
      </div>

      <div class="grid gap-4 lg:grid-cols-3">
        <div class="rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Tracked assets</p>
          <p class="mt-1 text-2xl font-semibold text-zinc-900"><%= @asset_summary.total_count %></p>
          <p class="text-xs text-zinc-500">Tangible holdings under management</p>
        </div>

        <div class="rounded-xl border border-zinc-200 bg-white p-4 shadow-sm lg:col-span-2">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-zinc-500">Value and equity totals</p>
          <div class="mt-3 grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            <div :for={total <- @asset_summary.totals} class="rounded-lg bg-zinc-50 px-3 py-2">
              <p class="text-xs text-zinc-500"><%= total.currency %> • <%= total.asset_count %> assets</p>
              <dl class="mt-2 grid grid-cols-3 gap-2 text-xs">
                <div>
                  <dt class="text-zinc-500">Gross value</dt>
                  <dd class="font-semibold text-zinc-900"><%= total.gross_value %></dd>
                </div>
                <div>
                  <dt class="text-zinc-500">Linked debt</dt>
                  <dd class="font-semibold text-zinc-900"><%= total.linked_debt %></dd>
                </div>
                <div>
                  <dt class="text-zinc-500">Net equity</dt>
                  <dd class="font-semibold text-zinc-900"><%= total.net_equity %></dd>
                </div>
              </dl>
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
                  <p class="font-semibold text-zinc-900"><%= summary.net_equity %> net equity</p>
                  <p class="text-xs text-zinc-500">
                    <%= summary.gross_value %> gross
                    <%= if Decimal.compare(summary.linked_debt_amount, Decimal.new("0")) == :gt,
                      do: " • #{summary.linked_debt} debt" %>
                  </p>
                </div>
              </div>

              <div class="flex flex-wrap gap-3 text-xs text-zinc-500">
                <span :if={summary.asset.location}><%= summary.asset.location %></span>
                <span :if={summary.asset.acquired_on}>Acquired <%= format_date(summary.asset.acquired_on) %></span>
                <span><%= summary.valuation_freshness %></span>
              </div>

              <p :if={summary.asset.notes} class="text-sm text-zinc-600"><%= summary.asset.notes %></p>

              <p :if={not Enum.empty?(summary.asset.document_refs)} class="text-xs text-zinc-500">
                Documents: <%= Enum.join(summary.asset.document_refs, ", ") %>
              </p>

              <div class="flex justify-end gap-2">
                <button type="button" class="btn btn-outline" phx-click="view-asset" phx-value-id={summary.asset.id}>
                  Details & values
                </button>
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

          <div :if={@selected_asset} id="asset-detail" class="space-y-5 rounded-xl border border-emerald-200 bg-white p-4">
            <div class="flex items-start justify-between gap-3">
              <div>
                <h3 class="text-lg font-semibold text-zinc-900"><%= @selected_asset.name %></h3>
                <p class="text-xs text-zinc-500">Valuation history and asset-specific details</p>
              </div>
              <button type="button" class="btn btn-outline" phx-click="close-asset-detail">Close</button>
            </div>

            <div :if={detail_summary(@asset_summary, @selected_asset)} class="grid gap-2 sm:grid-cols-3">
              <% detail = detail_summary(@asset_summary, @selected_asset) %>
              <div class="rounded-lg bg-zinc-50 p-3">
                <p class="text-xs text-zinc-500">Gross value</p>
                <p class="font-semibold text-zinc-900"><%= detail.gross_value %></p>
              </div>
              <div class="rounded-lg bg-zinc-50 p-3">
                <p class="text-xs text-zinc-500">Linked debt</p>
                <p class="font-semibold text-zinc-900"><%= detail.linked_debt %></p>
              </div>
              <div class="rounded-lg bg-zinc-50 p-3">
                <p class="text-xs text-zinc-500">Net equity</p>
                <p class="font-semibold text-zinc-900"><%= detail.net_equity %></p>
              </div>
            </div>

            <form :if={@selected_asset.asset_type == "vehicle"}
                  id="asset-debt-link-form"
                  phx-submit="link-asset-debt"
                  class="rounded-xl border border-zinc-200 bg-zinc-50 p-4">
              <div class="flex flex-col gap-3 sm:flex-row sm:items-end">
                <div class="min-w-0 flex-1">
                  <label class="text-sm font-medium text-zinc-700" for="detail_linked_loan_id">
                    Linked vehicle loan
                  </label>
                  <select id="detail_linked_loan_id"
                          name="asset[linked_loan_id]"
                          class="input mt-1">
                    <%= Phoenix.HTML.Form.options_for_select(
                      debt_options(@asset_loans, &loan_label/1),
                      @selected_asset.linked_loan_id
                    ) %>
                  </select>
                  <p class="mt-1 text-xs text-zinc-500">
                    The current balance is deducted from this vehicle’s gross value.
                  </p>
                </div>
                <button type="submit" class="btn" phx-disable-with="Saving…">Save link</button>
              </div>
              <p :if={Enum.empty?(@asset_loans)} class="mt-2 text-xs text-amber-700">
                No loan records are available yet. Add one in Loan Center first.
              </p>
            </form>

            <form :if={@selected_asset.asset_type == "real_estate"}
                  id="asset-debt-link-form"
                  phx-submit="link-asset-debt"
                  class="rounded-xl border border-zinc-200 bg-zinc-50 p-4">
              <div class="flex flex-col gap-3 sm:flex-row sm:items-end">
                <div class="min-w-0 flex-1">
                  <label class="text-sm font-medium text-zinc-700" for="detail_linked_mortgage_id">
                    Linked mortgage
                  </label>
                  <select id="detail_linked_mortgage_id"
                          name="asset[linked_mortgage_id]"
                          class="input mt-1">
                    <%= Phoenix.HTML.Form.options_for_select(
                      debt_options(@asset_mortgages, &mortgage_label/1),
                      @selected_asset.linked_mortgage_id
                    ) %>
                  </select>
                  <p class="mt-1 text-xs text-zinc-500">
                    The current balance is deducted from this property’s gross value.
                  </p>
                </div>
                <button type="submit" class="btn" phx-disable-with="Saving…">Save link</button>
              </div>
              <p :if={Enum.empty?(@asset_mortgages)} class="mt-2 text-xs text-amber-700">
                No mortgage records are available yet. Add one in Loan Center first.
              </p>
            </form>

            <.simple_form for={@valuation_changeset}
                          id="valuation-form"
                          phx-change="validate-valuation"
                          phx-submit="record-valuation"
                          :let={f}>
              <h4 class="font-semibold text-zinc-900">Record manual valuation</h4>
              <div class="grid gap-3 sm:grid-cols-2">
                <.input field={f[:amount]} label="Value" type={:number} step="0.01" min="0" />
                <.input field={f[:currency]} label="Currency" />
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="asset_valuation_valued_on">Valued on</label>
                  <input id="asset_valuation_valued_on"
                         name="asset_valuation[valued_on]"
                         type="date"
                         value={format_input_date(f[:valued_on].value)}
                         class="input" />
                </div>
                <.input :if={@selected_asset.asset_type == "vehicle"}
                        field={f[:mileage]}
                        label="Mileage at valuation"
                        type={:number}
                        min="0" />
              </div>
              <div class="flex justify-end">
                <button type="submit" class="btn">Record valuation</button>
              </div>
            </.simple_form>

            <.simple_form :if={@selected_asset.asset_type == "vehicle"}
                          for={@vehicle_profile_changeset}
                          id="vehicle-profile-form"
                          phx-change="validate-vehicle-profile"
                          phx-submit="save-vehicle-profile"
                          :let={f}>
              <h4 class="font-semibold text-zinc-900">Vehicle details</h4>
              <div class="grid gap-3 sm:grid-cols-2">
                <.input field={f[:encrypted_vin]} label="VIN" />
                <.input field={f[:year]} label="Year" type={:number} min="1886" max="2200" />
                <.input field={f[:make]} label="Make" />
                <.input field={f[:model]} label="Model" />
                <.input field={f[:trim]} label="Trim" />
                <.input field={f[:body_style]} label="Body style" />
                <.input field={f[:mileage]} label="Mileage" type={:number} min="0" />
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="vehicle_profile_mileage_as_of">Mileage as of</label>
                  <input id="vehicle_profile_mileage_as_of"
                         name="vehicle_profile[mileage_as_of]"
                         type="date"
                         value={format_input_date(f[:mileage_as_of].value)}
                         class="input" />
                </div>
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="vehicle_profile_condition">Condition</label>
                  <select id="vehicle_profile_condition" name="vehicle_profile[condition]" class="input">
                    <%= Phoenix.HTML.Form.options_for_select(
                      [{"Not set", ""} | Enum.map(VehicleProfile.conditions(), &{String.capitalize(&1), &1})],
                      f[:condition].value
                    ) %>
                  </select>
                </div>
                <.input field={f[:market_region]} label="Market ZIP or region" />
                <.input field={f[:encrypted_license_plate]} label="License plate" />
                <.input field={f[:license_plate_state]} label="Plate state" />
              </div>
              <div class="flex justify-end">
                <button type="submit" class="btn">Save vehicle details</button>
              </div>
            </.simple_form>

            <div class="space-y-3">
              <% trend = valuation_trend(@asset_valuations) %>
              <% mileage = mileage_history(@asset_valuations) %>

              <div>
                <h4 class="font-semibold text-zinc-900">Value over time</h4>
                <p class="text-xs text-zinc-500">
                  Provider estimates and user-entered values remain separate, immutable observations.
                </p>
              </div>

              <div :if={Enum.empty?(@asset_valuations)} class="text-sm text-zinc-500">
                No valuation snapshots yet.
              </div>

              <div :if={!Enum.empty?(@asset_valuations)} class="grid gap-3 sm:grid-cols-2">
                <div id="asset-value-trend" class="rounded-lg bg-zinc-50 p-3">
                  <p class="text-xs text-zinc-500">Value trend</p>
                  <%= if trend do %>
                    <p class="font-semibold text-zinc-900"><%= trend.label %></p>
                    <p class="text-xs text-zinc-600">
                      <%= trend.change %><%= if trend.percent, do: " • #{trend.percent}" %>
                      <span class="block"><%= trend.period %></span>
                    </p>
                  <% else %>
                    <p class="font-semibold text-zinc-900">More history needed</p>
                    <p class="text-xs text-zinc-500">A trend appears after two comparable valuations.</p>
                  <% end %>
                </div>

                <div :if={@selected_asset.asset_type == "vehicle"}
                     id="asset-mileage-history"
                     class="rounded-lg bg-zinc-50 p-3">
                  <p class="text-xs text-zinc-500">Mileage history</p>
                  <%= if mileage do %>
                    <p class="font-semibold text-zinc-900"><%= mileage.latest %> miles</p>
                    <p class="text-xs text-zinc-600">
                      <%= mileage.change %>
                      <span class="block">Latest reading <%= mileage.latest_on %></span>
                    </p>
                  <% else %>
                    <p class="font-semibold text-zinc-900">No mileage observations</p>
                    <p class="text-xs text-zinc-500">Add mileage with a vehicle valuation.</p>
                  <% end %>
                </div>
              </div>

              <div :if={!Enum.empty?(@asset_valuations)}
                   class="flex flex-wrap gap-4 text-xs text-zinc-600"
                   aria-label="Valuation source legend">
                <span class="inline-flex items-center gap-1.5">
                  <span class="size-2.5 rounded-full bg-emerald-500"></span>
                  Provider estimate
                </span>
                <span class="inline-flex items-center gap-1.5">
                  <span class="size-2.5 rounded-full bg-sky-500"></span>
                  Manual value
                </span>
              </div>

              <div :for={valuation <- Enum.reverse(@asset_valuations)}
                   class="grid gap-2 rounded-lg border border-zinc-100 p-3 text-xs sm:grid-cols-[7rem_minmax(0,1fr)_minmax(12rem,auto)] sm:items-center">
                <span class="text-zinc-500"><%= format_date(valuation.valued_on) %></span>
                <div class="h-2 rounded bg-zinc-100"
                     role="img"
                     aria-label={"#{valuation_source_label(valuation)} at #{valuation_bar_width(valuation, @asset_valuations)} percent of the largest recorded value"}>
                  <div class={[
                         "h-2 rounded",
                         valuation_bar_class(valuation)
                       ]}
                       style={"width: #{valuation_bar_width(valuation, @asset_valuations)}%"}>
                  </div>
                </div>
                <div class="sm:text-right">
                  <p class="font-semibold text-zinc-800"><%= valuation_display_value(valuation) %></p>
                  <p :if={valuation_range?(valuation)} class="text-zinc-500">
                    Point estimate: <%= format_valuation_money(valuation.amount, valuation.currency) %>
                  </p>
                  <p class="text-zinc-500">
                    <%= valuation_source_label(valuation) %>
                    <%= if valuation.confidence, do: " • #{String.capitalize(valuation.confidence)} confidence" %>
                    <%= if valuation.mileage, do: " • #{valuation.mileage} mi" %>
                  </p>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <div class="flex items-start justify-between gap-3">
            <div>
              <h2 class="text-lg font-semibold text-zinc-900">
                <%= if @asset_form_mode == :edit, do: "Edit asset", else: "Add asset" %>
              </h2>
              <p class="text-sm text-zinc-500">
                <%= if @asset_form_mode == :edit,
                  do: "Update the essentials first; optional details stay out of the way.",
                  else: "Start with the asset type. We’ll ask only for what is needed." %>
              </p>
            </div>
            <button :if={@asset_form_open?} type="button" class="btn btn-outline" phx-click="cancel-asset">
              Cancel
            </button>
          </div>

          <div :if={!@asset_form_open?} class="rounded-xl border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
            Choose “Add asset” to create a new record, or edit an existing asset from the inventory list.
          </div>

          <form :if={@asset_form_open? && @asset_form_mode == :new}
                id="asset-type-form"
                phx-change="select-asset-type"
                class="space-y-2">
            <label class="text-sm font-medium text-zinc-700" for="asset_setup_type">What are you adding?</label>
            <select id="asset_setup_type" name="asset_setup[type]" class="input">
              <%= Phoenix.HTML.Form.options_for_select(asset_type_options(nil), @asset_form_type) %>
            </select>
          </form>

          <form :if={@asset_form_open? && @asset_form_mode == :new &&
                     @asset_form_type == "vehicle" && is_nil(@vehicle_preview)}
                id="vehicle-lookup-form"
                phx-submit="preview-vehicle"
                class="space-y-4">
            <div class="rounded-xl border border-emerald-100 bg-emerald-50/60 p-4">
              <p class="font-semibold text-zinc-900">Look up the vehicle</p>
              <p class="mt-1 text-xs text-zinc-600">
                This preview uses one VIN decode and one price request. Nothing is saved until you confirm it.
              </p>
            </div>

            <div>
              <label class="text-sm font-medium text-zinc-700" for="vehicle_vin">VIN</label>
              <input id="vehicle_vin"
                     name="vehicle[vin]"
                     value={@vehicle_onboarding["vin"]}
                     maxlength="17"
                     autocomplete="off"
                     placeholder="17-character VIN"
                     class="input uppercase" />
            </div>
            <div class="grid gap-4 sm:grid-cols-2">
              <div>
                <label class="text-sm font-medium text-zinc-700" for="vehicle_mileage">Current mileage</label>
                <input id="vehicle_mileage"
                       name="vehicle[mileage]"
                       value={@vehicle_onboarding["mileage"]}
                       type="number"
                       min="0"
                       inputmode="numeric"
                       class="input" />
              </div>
              <div>
                <label class="text-sm font-medium text-zinc-700" for="vehicle_market_region">Market ZIP</label>
                <input id="vehicle_market_region"
                       name="vehicle[market_region]"
                       value={@vehicle_onboarding["market_region"]}
                       maxlength="5"
                       inputmode="numeric"
                       autocomplete="postal-code"
                       placeholder="5-digit ZIP"
                       class="input" />
              </div>
            </div>

            <p :if={@vehicle_preview_error}
               id="vehicle-preview-error"
               class="rounded-lg border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">
              <%= @vehicle_preview_error %>
            </p>

            <div class="flex justify-end">
              <button type="submit"
                      class="btn"
                      disabled={!@marketcheck_configured?}
                      phx-disable-with="Looking up vehicle…">
                Review vehicle
              </button>
            </div>
          </form>

          <div :if={@asset_form_open? && @asset_form_mode == :new &&
                    @asset_form_type == "vehicle" && @vehicle_preview}
               id="vehicle-preview"
               class="space-y-4">
            <div class="rounded-xl border border-emerald-200 bg-emerald-50/60 p-4">
              <div class="flex items-start justify-between gap-3">
                <div>
                  <p class="text-xs font-semibold uppercase tracking-wide text-emerald-700">Review before saving</p>
                  <p class="mt-1 text-lg font-semibold text-zinc-900">
                    <%= vehicle_description(@vehicle_preview) %>
                  </p>
                  <p class="text-sm text-zinc-600">
                    <%= vehicle_secondary_description(@vehicle_preview) %>
                  </p>
                </div>
                <p class="text-right">
                  <span class="block text-xs text-zinc-500">MarketCheck estimate</span>
                  <strong class="text-lg text-zinc-900">
                    <%= Accounts.format_money(@vehicle_preview.valuation.value, "USD", []) %>
                  </strong>
                </p>
              </div>
              <div class="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-xs text-zinc-600">
                <span>VIN ending <%= String.slice(@vehicle_preview.vin, -4, 4) %></span>
                <span><%= @vehicle_preview.mileage %> miles</span>
                <span>ZIP <%= @vehicle_preview.market_region %></span>
                <span :if={@vehicle_preview.cached?}>Reused a recent preview</span>
              </div>
            </div>

            <.simple_form for={@asset_changeset}
                          id="vehicle-confirm-form"
                          phx-change="validate-asset"
                          phx-submit="confirm-vehicle"
                          :let={f}>
              <div class="space-y-4">
                <.input field={f[:name]} label="Name" />

                <div>
                  <label class="text-sm font-medium text-zinc-700" for="asset_linked_loan_id">
                    Linked vehicle loan (optional)
                  </label>
                  <select id="asset_linked_loan_id" name="asset[linked_loan_id]" class="input">
                    <%= Phoenix.HTML.Form.options_for_select(
                      debt_options(@asset_loans, &loan_label/1),
                      f[:linked_loan_id].value
                    ) %>
                  </select>
                </div>

                <details class="rounded-xl border border-zinc-200 p-4">
                  <summary class="cursor-pointer text-sm font-semibold text-zinc-800">More details</summary>
                  <div class="mt-4 grid gap-4">
                    <div>
                      <label class="text-sm font-medium text-zinc-700" for="asset_account_id">
                        Funding account (optional)
                      </label>
                      <select id="asset_account_id" name="asset[account_id]" class="input">
                        <%= Phoenix.HTML.Form.options_for_select(
                          asset_account_options(@asset_accounts),
                          f[:account_id].value
                        ) %>
                      </select>
                    </div>
                    <.input field={f[:acquisition_cost]} label="Acquisition cost" type={:number} step="0.01" min="0" />
                    <.input field={f[:ownership_type]} label="Ownership type" />
                    <.input field={f[:ownership_details]} label="Ownership details" type={:textarea} />
                    <.input field={f[:location]} label="Location" />
                    <.input field={f[:notes]} label="Notes" type={:textarea} />
                    <div>
                      <label class="text-sm font-medium text-zinc-700" for="asset_acquired_on">Acquired on</label>
                      <input id="asset_acquired_on"
                             name="asset[acquired_on]"
                             type="date"
                             value={format_input_date(f[:acquired_on].value)}
                             class="input" />
                    </div>
                    <.input field={f[:documents_text]}
                            label="Document references"
                            type={:textarea}
                            placeholder="One reference per line" />
                  </div>
                </details>
              </div>

              <div class="flex flex-wrap justify-end gap-2">
                <button type="button" class="btn btn-outline" phx-click="edit-vehicle-lookup">
                  Change VIN or mileage
                </button>
                <button type="submit" class="btn" phx-disable-with="Adding vehicle…">
                  Confirm and add vehicle
                </button>
              </div>
            </.simple_form>
          </div>

          <.simple_form :if={@asset_form_open? &&
                             (@asset_form_mode == :edit || @asset_form_type != "vehicle")}
                        for={@asset_changeset}
                        id="asset-form"
                        phx-change="validate-asset"
                        phx-submit="save-asset"
                        :let={f}>
            <div class="space-y-4">
              <input :if={@asset_form_mode == :new}
                     type="hidden"
                     name="asset[asset_type]"
                     value={@asset_form_type} />
              <.input field={f[:name]} label="Name" />
              <div :if={@asset_form_mode == :edit}>
                <label class="text-sm font-medium text-zinc-700" for="asset_asset_type">Type</label>
                <select id="asset_asset_type" name="asset[asset_type]" class="input">
                  <%= Phoenix.HTML.Form.options_for_select(
                    asset_type_options(@asset_editing_asset),
                    f[:asset_type].value
                  ) %>
                </select>
                <p :for={error <- errors_on(@asset_changeset, :asset_type)} class="text-sm text-red-600"><%= error %></p>
              </div>
              <div class="grid gap-4 sm:grid-cols-[minmax(0,1fr)_8rem]">
                <.input field={f[:valuation_amount]} label="Current value" type={:number} step="0.01" min="0" />
                <.input field={f[:valuation_currency]} label="Currency" />
              </div>

              <details class="rounded-xl border border-zinc-200 p-4">
                <summary class="cursor-pointer text-sm font-semibold text-zinc-800">More details</summary>
                <div class="mt-4 grid gap-4">
                  <div>
                    <label class="text-sm font-medium text-zinc-700" for="asset_account_id">
                      Funding account (optional)
                    </label>
                    <select id="asset_account_id" name="asset[account_id]" class="input">
                      <%= Phoenix.HTML.Form.options_for_select(
                        asset_account_options(@asset_accounts),
                        f[:account_id].value || (@asset_editing_asset && @asset_editing_asset.account_id)
                      ) %>
                    </select>
                  </div>

                  <div :if={@asset_form_type in ["vehicle", "equipment", "collectible", "other"]}>
                    <label class="text-sm font-medium text-zinc-700" for="asset_linked_loan_id">
                      Linked loan (optional)
                    </label>
                    <select id="asset_linked_loan_id" name="asset[linked_loan_id]" class="input">
                      <%= Phoenix.HTML.Form.options_for_select(
                        debt_options(@asset_loans, &loan_label/1),
                        f[:linked_loan_id].value
                      ) %>
                    </select>
                  </div>

                  <div :if={@asset_form_type == "real_estate"}>
                    <label class="text-sm font-medium text-zinc-700" for="asset_linked_mortgage_id">
                      Linked mortgage (optional)
                    </label>
                    <select id="asset_linked_mortgage_id" name="asset[linked_mortgage_id]" class="input">
                      <%= Phoenix.HTML.Form.options_for_select(
                        debt_options(@asset_mortgages, &mortgage_label/1),
                        f[:linked_mortgage_id].value
                      ) %>
                    </select>
                  </div>

                  <.input field={f[:category]} label="Category" />
                  <.input field={f[:acquisition_cost]} label="Acquisition cost" type={:number} step="0.01" min="0" />
                  <.input field={f[:ownership_type]} label="Ownership type" />
                  <.input field={f[:ownership_details]} label="Ownership details" type={:textarea} />
                  <.input field={f[:location]} label="Location" />
                  <.input field={f[:notes]} label="Notes" type={:textarea} />

                  <div>
                    <label class="text-sm font-medium text-zinc-700" for="asset_acquired_on">Acquired on</label>
                    <input id="asset_acquired_on"
                           name="asset[acquired_on]"
                           type="date"
                           value={format_input_date(f[:acquired_on].value)}
                           class="input" />
                  </div>

                  <div>
                    <label class="text-sm font-medium text-zinc-700" for="asset_last_valued_on">Last valued on</label>
                    <input id="asset_last_valued_on"
                           name="asset[last_valued_on]"
                           type="date"
                           value={format_input_date(f[:last_valued_on].value)}
                           class="input" />
                  </div>

                  <.input field={f[:documents_text]}
                          label="Document references"
                          type={:textarea}
                          placeholder="One reference per line" />
                </div>
              </details>
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
      asset_summary: Assets.dashboard_summary(current_user),
      asset_accounts: Accounts.list_accessible_accounts(current_user, order_by: {:asc, :name}),
      asset_loans: Loans.list_loans(current_user),
      asset_mortgages: Mortgages.list_mortgages(current_user),
      marketcheck_configured?: ProviderRegistry.configured?("marketcheck"),
      marketcheck_usage: Assets.provider_usage("marketcheck")
    )
  end

  defp load_asset_detail(socket, current_user, asset_id) do
    with {:ok, asset} <- Assets.fetch_asset(current_user, asset_id),
         {:ok, valuations} <- Assets.list_asset_valuations(current_user, asset) do
      profile = selected_vehicle_profile(asset)

      assign(socket,
        selected_asset: asset,
        asset_valuations: valuations,
        valuation_changeset: Assets.change_asset_valuation(asset),
        vehicle_profile_changeset:
          if(asset.asset_type == "vehicle",
            do: Assets.change_vehicle_profile(profile),
            else: nil
          )
      )
    else
      _error ->
        socket
        |> assign(
          selected_asset: nil,
          asset_valuations: [],
          valuation_changeset: nil,
          vehicle_profile_changeset: nil
        )
        |> put_flash(:error, "Asset details are no longer accessible.")
    end
  end

  defp reset_asset_form(socket) do
    assign(socket,
      asset_form_open?: false,
      asset_form_mode: :new,
      asset_editing_asset: nil,
      asset_form_type: "vehicle",
      asset_changeset: new_asset_changeset(socket.assigns.current_user, "vehicle"),
      vehicle_onboarding: empty_vehicle_onboarding(),
      vehicle_preview: nil,
      vehicle_preview_error: nil
    )
  end

  defp maybe_reset_form_for_deleted(socket, asset_id) do
    socket =
      case socket.assigns.asset_editing_asset do
        %Asset{id: ^asset_id} -> reset_asset_form(socket)
        _ -> socket
      end

    case socket.assigns.selected_asset do
      %Asset{id: ^asset_id} ->
        assign(socket,
          selected_asset: nil,
          asset_valuations: [],
          valuation_changeset: nil,
          vehicle_profile_changeset: nil
        )

      _ ->
        socket
    end
  end

  defp new_asset_changeset(current_user, asset_type) do
    Assets.change_asset(
      %Asset{user_id: current_user.id},
      %{
        "asset_type" => asset_type,
        "valuation_currency" => "USD",
        "ownership_type" => "individual",
        "last_valued_on" => Date.utc_today()
      }
    )
  end

  defp vehicle_preview_changeset(current_user, preview) do
    decoded = preview.decoded

    Assets.change_asset(
      %Asset{user_id: current_user.id},
      %{
        "name" => vehicle_description(preview),
        "asset_type" => "vehicle",
        "category" => "vehicle",
        "valuation_amount" => preview.valuation.value,
        "valuation_currency" => "USD",
        "ownership_type" => "individual",
        "last_valued_on" => Date.utc_today(),
        "notes" =>
          [decoded.trim, decoded.body_style]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" • ")
      }
    )
  end

  defp empty_vehicle_onboarding do
    %{"vin" => "", "mileage" => "", "market_region" => ""}
  end

  defp vehicle_description(%{decoded: decoded}) do
    [decoded.year, decoded.make, decoded.model]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp vehicle_secondary_description(%{decoded: decoded}) do
    [decoded.trim, decoded.body_style]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" • ")
    |> case do
      "" -> "Vehicle details decoded from the VIN"
      description -> description
    end
  end

  defp vehicle_preview_error(:invalid_vin),
    do: "Enter a valid 17-character VIN without the letters I, O, or Q."

  defp vehicle_preview_error(:invalid_mileage), do: "Enter the vehicle’s current mileage."
  defp vehicle_preview_error(:invalid_market_region), do: "Enter a 5-digit market ZIP code."
  defp vehicle_preview_error(:invalid_vehicle), do: "MarketCheck could not validate that vehicle."

  defp vehicle_preview_error(:missing_api_key),
    do: "MarketCheck is enabled, but its API key is unavailable."

  defp vehicle_preview_error(:disabled), do: "MarketCheck vehicle lookup is not enabled."

  defp vehicle_preview_error(:monthly_budget_exhausted),
    do: "The monthly MarketCheck request budget has been reached."

  defp vehicle_preview_error(:provider_rate_window_full),
    do: "Vehicle lookups are briefly busy. Try again in a moment."

  defp vehicle_preview_error(:provider_request_recent),
    do: "That lookup was just attempted. Wait a minute before trying it again."

  defp vehicle_preview_error(:rate_limited),
    do: "MarketCheck temporarily rate-limited the lookup. Try again later."

  defp vehicle_preview_error(:timeout),
    do: "MarketCheck did not respond in time. No asset was saved."

  defp vehicle_preview_error({:http_error, 401}),
    do: "MarketCheck rejected the API key."

  defp vehicle_preview_error({:http_error, 403}),
    do: "The MarketCheck key is not authorized for this lookup."

  defp vehicle_preview_error({:http_error, 404}),
    do: "MarketCheck could not find that vehicle."

  defp vehicle_preview_error(_reason),
    do: "MarketCheck could not complete the preview. No asset was saved."

  defp asset_account_options(accounts) do
    [{"No linked funding account", ""} | Enum.map(accounts, &{&1.name, &1.id})]
  end

  defp asset_type_options(editing_asset) do
    options =
      Enum.map(Asset.asset_types(), fn type ->
        {type |> String.replace("_", " ") |> String.capitalize(), type}
      end)

    case editing_asset do
      %Asset{asset_type: type} when is_binary(type) ->
        if type in Asset.asset_types(), do: options, else: [{type, type} | options]

      _ ->
        options
    end
  end

  defp debt_options(records, label_fun),
    do: [{"No linked debt", ""} | Enum.map(records, &{label_fun.(&1), &1.id})]

  defp debt_link_params(%Asset{asset_type: "vehicle"}, params),
    do: Map.take(params, ["linked_loan_id"])

  defp debt_link_params(%Asset{asset_type: "real_estate"}, params),
    do: Map.take(params, ["linked_mortgage_id"])

  defp debt_link_params(%Asset{}, params),
    do: Map.take(params, ["linked_loan_id", "linked_mortgage_id"])

  defp manual_valuation_params(params) do
    params
    |> Map.take(["amount", "currency", "valued_on", "mileage"])
    |> Map.put("source", "manual")
    |> Map.put("manually_overridden", true)
  end

  defp loan_label(loan), do: loan.name || loan.lender_name || "Loan"
  defp mortgage_label(mortgage), do: mortgage.nickname || mortgage.property_name || "Mortgage"

  defp selected_vehicle_profile(%Asset{vehicle_profile: %VehicleProfile{} = profile}), do: profile
  defp selected_vehicle_profile(%Asset{id: asset_id}), do: %VehicleProfile{asset_id: asset_id}

  defp detail_summary(summary, %Asset{id: asset_id}) do
    Enum.find(summary.assets, &(&1.asset.id == asset_id))
  end

  defp valuation_source_label(%{source: "provider", provider_key: "marketcheck"}),
    do: "MarketCheck estimate"

  defp valuation_source_label(%{source: "provider", provider_key: provider_key})
       when is_binary(provider_key),
       do: "#{String.capitalize(provider_key)} estimate"

  defp valuation_source_label(%{source: "manual"}), do: "Manual"
  defp valuation_source_label(%{source: source}), do: source

  defp valuation_trend([latest | _rest] = valuations) when length(valuations) > 1 do
    oldest = List.last(valuations)

    if latest.currency == oldest.currency do
      change = Decimal.sub(latest.amount, oldest.amount)
      absolute_change = Decimal.abs(change)

      %{
        label: valuation_trend_label(change),
        change: format_valuation_money(absolute_change, latest.currency),
        percent: valuation_change_percent(absolute_change, oldest.amount),
        period: "#{format_date(oldest.valued_on)} → #{format_date(latest.valued_on)}"
      }
    end
  end

  defp valuation_trend(_valuations), do: nil

  defp valuation_trend_label(change) do
    case Decimal.compare(change, Decimal.new("0")) do
      :lt -> "Depreciation"
      :gt -> "Appreciation"
      :eq -> "No value change"
    end
  end

  defp valuation_change_percent(_change, oldest_amount)
       when not is_struct(oldest_amount, Decimal),
       do: nil

  defp valuation_change_percent(change, oldest_amount) do
    if Decimal.compare(oldest_amount, Decimal.new("0")) == :gt do
      change
      |> Decimal.div(oldest_amount)
      |> Decimal.mult(Decimal.new("100"))
      |> Decimal.round(1)
      |> Decimal.to_string(:normal)
      |> Kernel.<>("%")
    end
  end

  defp mileage_history(valuations) do
    case Enum.filter(valuations, &is_integer(&1.mileage)) do
      [] ->
        nil

      [latest | _rest] = observations ->
        oldest = List.last(observations)

        %{
          latest: latest.mileage,
          latest_on: format_date(latest.valued_on),
          change: mileage_change_label(latest, oldest, length(observations))
        }
    end
  end

  defp mileage_change_label(_latest, _oldest, 1), do: "First recorded mileage"

  defp mileage_change_label(latest, oldest, _count) do
    delta = latest.mileage - oldest.mileage
    direction = if delta > 0, do: "+", else: ""
    "#{direction}#{delta} miles since #{format_date(oldest.valued_on)}"
  end

  defp valuation_range?(%{value_low: %Decimal{}, value_high: %Decimal{}}), do: true
  defp valuation_range?(_valuation), do: false

  defp valuation_display_value(%{
         value_low: %Decimal{} = low,
         value_high: %Decimal{} = high,
         currency: currency
       }) do
    "#{format_valuation_money(low, currency)} – #{format_valuation_money(high, currency)}"
  end

  defp valuation_display_value(%{source: "provider", amount: amount, currency: currency}),
    do: "#{format_valuation_money(amount, currency)} estimate"

  defp valuation_display_value(%{amount: amount, currency: currency}),
    do: format_valuation_money(amount, currency)

  defp valuation_bar_class(%{source: "provider"}), do: "bg-emerald-500"
  defp valuation_bar_class(%{source: "manual"}), do: "bg-sky-500"
  defp valuation_bar_class(_valuation), do: "bg-zinc-500"

  defp format_valuation_money(amount, currency),
    do: Accounts.format_money(amount, currency, [])

  defp valuation_bar_width(valuation, valuations) do
    maximum =
      valuations
      |> Enum.map(& &1.amount)
      |> Enum.max_by(&Decimal.to_float/1, fn -> Decimal.new("0") end)

    if Decimal.compare(maximum, Decimal.new("0")) == :gt do
      valuation.amount
      |> Decimal.div(maximum)
      |> Decimal.mult(Decimal.new("100"))
      |> Decimal.round(1)
      |> Decimal.to_string(:normal)
    else
      "0"
    end
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
