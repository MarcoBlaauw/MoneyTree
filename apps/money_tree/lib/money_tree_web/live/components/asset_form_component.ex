defmodule MoneyTreeWeb.AssetFormComponent do
  @moduledoc """
  Live component that renders the asset form for creating and updating tangible assets.
  """

  use MoneyTreeWeb, :live_component

  alias Ecto.Changeset
  alias Jason
  alias MoneyTree.Assets

  @impl true
  def update(assigns, socket) do
    changeset =
      assigns
      |> Map.get(:changeset)
      |> case do
        %Changeset{} = existing -> existing
        _ -> Assets.change_asset(assigns.asset)
      end

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, changeset)}
  end

  @impl true
  def handle_event("validate", %{"asset" => params}, socket) do
    with {:ok, normalized} <- normalize_params(params) do
      changeset =
        socket.assigns.asset
        |> Assets.change_asset(normalized)
        |> Map.put(:action, :validate)

      {:noreply, assign(socket, :changeset, changeset)}
    else
      {:error, {field, message}} ->
        changeset =
          socket.assigns.changeset
          |> Changeset.add_error(field, message)
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  def handle_event("save", %{"asset" => params}, socket) do
    with {:ok, normalized} <- normalize_params(params),
         {:ok, asset} <- persist_asset(socket, normalized) do
      send(self(), {:asset_form_saved, asset})
      {:noreply, socket}
    else
      {:error, %Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, %{changeset | action: :validate})}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "You do not have access to the selected account.")
         |> assign(:changeset, %{socket.assigns.changeset | action: :validate})}

      {:error, {field, message}} ->
        changeset =
          socket.assigns.changeset
          |> Changeset.add_error(field, message)
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp persist_asset(%{assigns: %{action: :new, current_user: user}}, params) do
    Assets.create_asset_for_user(user, params)
  end

  defp persist_asset(%{assigns: %{action: :edit, current_user: user, asset: asset}}, params) do
    Assets.update_asset_for_user(user, asset, params)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4 rounded-lg border border-zinc-200 bg-white p-4 shadow-sm">
      <div class="flex items-center justify-between">
        <h3 class="text-base font-semibold text-zinc-900">
          <%= if @action == :new, do: "Add asset", else: "Edit asset" %>
        </h3>
        <button type="button"
                class="btn btn-outline"
                phx-click="cancel-asset-form">
          Cancel
        </button>
      </div>

      <.simple_form :let={f}
                    for={@changeset}
                    id="asset-form"
                    phx-submit="save"
                    phx-change="validate"
                    phx-target={@myself}>
        <.input field={f[:name]} label="Name" />
        <.input field={f[:type]} label="Type" />
        <.input field={f[:valuation_amount]} label="Valuation" type={:number} step="0.01" min="0" />
        <.input field={f[:valuation_currency]} label="Currency" />
        <.input field={f[:valuation_date]} label="Valuation date" type={:date} />
        <div class="flex flex-col gap-1">
          <label for={f[:account_id].id} class="text-sm font-medium text-zinc-700">Account</label>
          <select id={f[:account_id].id}
                  name={f[:account_id].name}
                  class="input"
                  required>
            <option value="">Select account</option>
            <%= Phoenix.HTML.Form.options_for_select(
              Enum.map(@accounts, &{&1.name, &1.id}),
              f[:account_id].value
            ) %>
          </select>
          <p :for={msg <- List.wrap(f[:account_id].errors)} class="text-sm text-red-600">
            <%= MoneyTreeWeb.CoreComponents.translate_error(msg) %>
          </p>
        </div>
        <.input field={f[:ownership]} label="Ownership" />
        <.input field={f[:location]} label="Location" />
        <div class="flex flex-col gap-1">
          <label for={f[:documents].id} class="text-sm font-medium text-zinc-700">
            Documents (comma or newline separated)
          </label>
          <textarea id={f[:documents].id}
                    name={f[:documents].name}
                    class="textarea"
                    placeholder="URL or reference"><%= Enum.join(f[:documents].value || [], "\n") %></textarea>
          <p :for={msg <- List.wrap(f[:documents].errors)} class="text-sm text-red-600">
            <%= MoneyTreeWeb.CoreComponents.translate_error(msg) %>
          </p>
        </div>
        <.input field={f[:notes]} label="Notes" type={:textarea} />
        <.input field={f[:metadata]} label="Metadata (JSON)" type={:textarea} />
        <div class="flex justify-end">
          <button type="submit" class="btn">
            <%= if @action == :new, do: "Save asset", else: "Update asset" %>
          </button>
        </div>
      </.simple_form>
    </div>
    """
  end

  defp normalize_params(params) do
    params = Map.new(params)

    with {:ok, params} <- normalize_documents(params) do
      {:ok, normalize_metadata(params)}
    end
  end

  defp normalize_documents(params) do
    case Map.get(params, "documents") do
      nil ->
        {:ok, params}

      documents when is_list(documents) ->
        {:ok, params}

      documents when is_binary(documents) ->
        parsed =
          documents
          |> String.split(["\n", ","], trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, Map.put(params, "documents", parsed)}

      _other ->
        {:error, {:documents, "must be provided as text"}}
    end
  end

  defp normalize_metadata(params) do
    case Map.get(params, "metadata") do
      nil ->
        params

      metadata when is_map(metadata) ->
        metadata |> then(&Map.put(params, "metadata", &1))

      metadata when is_binary(metadata) ->
        trimmed = String.trim(metadata)

        cond do
          trimmed == "" ->
            Map.put(params, "metadata", %{})

          true ->
            case Jason.decode(trimmed) do
              {:ok, decoded} when is_map(decoded) -> Map.put(params, "metadata", decoded)
              {:ok, _other} -> Map.put(params, "metadata", %{})
              {:error, _} -> Map.put(params, "metadata", metadata)
            end
        end

      _other ->
        params
    end
  end
end
