defmodule MoneyTreeWeb.BudgetLive.Index do
  @moduledoc """
  LiveView responsible for managing user budgets across time periods and categories.
  """

  use MoneyTreeWeb, :live_view

  alias MoneyTree.Budgets
  alias MoneyTree.Budgets.Budget
  alias MoneyTreeWeb.CoreComponents

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: current_user}} = socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Budgets",
       budget_changeset: Budgets.change_budget(%Budget{}),
       budget_form_mode: :new,
       budget_editing: nil,
       period_options: period_options(),
       entry_type_options: entry_type_options(),
       variability_options: variability_options()
     )
     |> assign_budget_rows(current_user)}
  end

  @impl true
  def handle_event("new-budget", _params, socket) do
    {:noreply,
     assign(socket,
       budget_form_mode: :new,
       budget_editing: nil,
       budget_changeset: Budgets.change_budget(%Budget{})
     )}
  end

  def handle_event(
        "edit-budget",
        %{"id" => budget_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    case Budgets.get_budget!(current_user, budget_id) do
      %Budget{} = budget ->
        {:noreply,
         assign(socket,
           budget_form_mode: :edit,
           budget_editing: budget,
           budget_changeset: Budgets.change_budget(budget)
         )}
    end
  rescue
    Ecto.NoResultsError ->
      {:noreply, put_flash(socket, :error, "Budget not found or no longer accessible.")}
  end

  def handle_event(
        "delete-budget",
        %{"id" => budget_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    with {:ok, %Budget{} = budget} <- fetch_budget(current_user, budget_id),
         {:ok, _} <- Budgets.delete_budget(budget) do
      {:noreply,
       socket
       |> assign_budget_rows(current_user)
       |> maybe_reset_deleted_budget(budget_id)
       |> put_flash(:info, "Budget removed successfully.")}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Budget not found or already removed.")}
    end
  end

  def handle_event(
        "validate-budget",
        %{"budget" => params},
        %{assigns: %{budget_editing: editing}} = socket
      ) do
    base = editing || %Budget{}

    changeset =
      base
      |> Budgets.change_budget(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, budget_changeset: changeset)}
  end

  def handle_event(
        "save-budget",
        %{"budget" => params},
        %{assigns: %{current_user: current_user, budget_form_mode: :new}} = socket
      ) do
    case Budgets.create_budget(current_user, params) do
      {:ok, _budget} ->
        {:noreply,
         socket
         |> assign_budget_rows(current_user)
         |> assign(budget_changeset: Budgets.change_budget(%Budget{}), budget_editing: nil)
         |> put_flash(:info, "Budget created successfully.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, budget_changeset: Map.put(changeset, :action, :validate))}
    end
  end

  def handle_event(
        "save-budget",
        %{"budget" => params},
        %{assigns: %{current_user: current_user, budget_form_mode: :edit, budget_editing: %Budget{} = budget}} =
          socket
      ) do
    case Budgets.update_budget(budget, params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign_budget_rows(current_user)
         |> assign(
           budget_changeset: Budgets.change_budget(updated),
           budget_editing: updated,
           budget_form_mode: :edit
         )
         |> put_flash(:info, "Budget updated successfully.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, budget_changeset: Map.put(changeset, :action, :validate))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-6">
      <.header title="Budgets" subtitle="Create and track targets across spending categories.">
        <:actions>
          <button class="btn btn-outline" type="button" phx-click="new-budget">New budget</button>
        </:actions>
      </.header>

      <div class="grid gap-6 lg:grid-cols-3">
        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm lg:col-span-2">
          <h2 class="text-lg font-semibold text-zinc-900">Your budgets</h2>
          <p class="text-sm text-zinc-500">
            Monitor allocations by period, entry type, and variability to understand where cash is headed.
          </p>

          <ul class="space-y-3 text-sm">
            <li :for={budget <- @budget_rows}
                id={"budget-#{budget.id}"}
                class="rounded-lg border border-zinc-100 bg-zinc-50 p-3">
              <div class="flex items-center justify-between">
                <div>
                  <p class="text-base font-semibold text-zinc-900"><%= budget.name %></p>
                  <p class="text-xs text-zinc-500">
                    <%= budget.period %> • <%= budget.entry_type %> • <%= budget.variability %>
                  </p>
                </div>

                <div class="flex items-center gap-2">
                  <button type="button"
                          class="btn btn-ghost btn-xs"
                          phx-click="edit-budget"
                          phx-value-id={budget.id}>
                    Edit
                  </button>
                  <button type="button"
                          class="btn btn-outline btn-xs"
                          phx-click="delete-budget"
                          data-confirm="Are you sure?"
                          phx-value-id={budget.id}>
                    Delete
                  </button>
                </div>
              </div>

              <dl class="mt-3 grid gap-2 text-sm md:grid-cols-3">
                <div>
                  <dt class="text-xs uppercase tracking-wide text-zinc-500">Allocation</dt>
                  <dd class="font-medium text-zinc-800"><%= budget.allocation_formatted %></dd>
                </div>
                <div>
                  <dt class="text-xs uppercase tracking-wide text-zinc-500">Masked</dt>
                  <dd class="font-medium text-zinc-800"><%= budget.allocation_masked %></dd>
                </div>
                <div>
                  <dt class="text-xs uppercase tracking-wide text-zinc-500">Currency</dt>
                  <dd class="font-medium text-zinc-800"><%= budget.currency %></dd>
                </div>
              </dl>
            </li>

            <li :if={Enum.empty?(@budget_rows)} class="rounded-lg border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
              No budgets created yet. Use the form to get started.
            </li>
          </ul>
        </div>

        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <h2 class="text-lg font-semibold text-zinc-900">
            <%= if @budget_form_mode == :edit do %>
              Update budget
            <% else %>
              New budget
            <% end %>
          </h2>
          <p class="text-sm text-zinc-500">
            Define allocations for recurring spend or income streams. All amounts must use ISO currency codes.
          </p>

          <.simple_form for={@budget_changeset}
                        id="budget-form"
                        phx-change="validate-budget"
                        phx-submit="save-budget"
                        :let={f}>
            <div class="space-y-4">
              <.input field={f[:name]} label="Name" placeholder="e.g. Housing" />

              <div class="grid gap-4 md:grid-cols-2">
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="budget_period">Period</label>
                  <select id="budget_period"
                          name="budget[period]"
                          class="input">
                    <%= Phoenix.HTML.Form.options_for_select(@period_options, select_value(f[:period].value)) %>
                  </select>
                  <p :for={error <- errors_on(@budget_changeset, :period)} class="text-sm text-red-600"><%= error %></p>
                </div>

                <div>
                  <label class="text-sm font-medium text-zinc-700" for="budget_entry_type">Type</label>
                  <select id="budget_entry_type"
                          name="budget[entry_type]"
                          class="input">
                    <%= Phoenix.HTML.Form.options_for_select(@entry_type_options, select_value(f[:entry_type].value)) %>
                  </select>
                  <p :for={error <- errors_on(@budget_changeset, :entry_type)} class="text-sm text-red-600"><%= error %></p>
                </div>
              </div>

              <div class="grid gap-4 md:grid-cols-2">
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="budget_variability">Variability</label>
                  <select id="budget_variability"
                          name="budget[variability]"
                          class="input">
                    <%= Phoenix.HTML.Form.options_for_select(@variability_options, select_value(f[:variability].value)) %>
                  </select>
                  <p :for={error <- errors_on(@budget_changeset, :variability)} class="text-sm text-red-600"><%= error %></p>
                </div>

                <.input field={f[:allocation_amount]}
                        label="Allocation amount"
                        type={:number}
                        step="0.01"
                        min="0" />
              </div>

              <.input field={f[:currency]} label="Currency" placeholder="USD" />

              <div class="flex justify-end gap-2">
                <button type="button" class="btn btn-ghost" phx-click="new-budget">Reset</button>
                <button type="submit" class="btn">
                  <%= if @budget_form_mode == :edit, do: "Update budget", else: "Create budget" %>
                </button>
              </div>
            </div>
          </.simple_form>
        </div>
      </div>
    </section>
    """
  end

  defp assign_budget_rows(socket, current_user) do
    budgets = Budgets.list_budgets(current_user)
    rows = Enum.map(budgets, &Budgets.format_budget/1)

    assign(socket, budget_rows: rows)
  end

  defp maybe_reset_deleted_budget(socket, deleted_id) do
    case socket.assigns.budget_editing do
      %Budget{id: ^deleted_id} ->
        assign(socket,
          budget_form_mode: :new,
          budget_editing: nil,
          budget_changeset: Budgets.change_budget(%Budget{})
        )

      _ ->
        socket
    end
  end

  defp fetch_budget(user, id) do
    {:ok, Budgets.get_budget!(user, id)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp period_options do
    Budget.periods()
    |> Enum.map(fn period ->
      label = period |> Atom.to_string() |> String.capitalize()
      {label, Atom.to_string(period)}
    end)
  end

  defp entry_type_options do
    Budget.entry_types()
    |> Enum.map(fn type ->
      label = type |> Atom.to_string() |> String.capitalize()
      {label, Atom.to_string(type)}
    end)
  end

  defp variability_options do
    Budget.variabilities()
    |> Enum.map(fn variability ->
      label = variability |> Atom.to_string() |> String.capitalize()
      {label, Atom.to_string(variability)}
    end)
  end

  defp select_value(value) when is_atom(value), do: Atom.to_string(value)
  defp select_value(value), do: value

  defp errors_on(%Ecto.Changeset{} = changeset, field) do
    changeset
    |> Map.get(:errors)
    |> Keyword.get_values(field)
    |> Enum.map(&CoreComponents.translate_error/1)
  end
end
