defmodule MoneyTreeWeb.BudgetLive.Index do
  @moduledoc """
  LiveView responsible for managing user budgets across time periods and categories.
  """

  use MoneyTreeWeb, :live_view

  alias Decimal
  alias MoneyTree.Budgets
  alias MoneyTree.Budgets.Budget

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
       variability_options: variability_options(),
       target_mode_options: target_mode_options(),
       rollover_policy_options: rollover_policy_options()
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
        "accept-suggestion",
        %{"id" => budget_id},
        %{assigns: %{current_user: current_user, planner_recommendations: recommendations}} =
          socket
      ) do
    with recommendation when not is_nil(recommendation) <-
           Enum.find(recommendations, &(&1.budget_id == budget_id)),
         {:ok, _budget} <-
           Budgets.accept_recommendation(
             current_user,
             budget_id,
             recommendation.suggested_allocation,
             recommendation.explanation
           ) do
      {:noreply,
       socket
       |> assign_budget_rows(current_user)
       |> put_flash(:info, "Suggestion accepted.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Unable to accept suggestion.")}
    end
  end

  def handle_event(
        "reject-suggestion",
        %{"id" => budget_id},
        %{assigns: %{current_user: current_user, planner_recommendations: recommendations}} =
          socket
      ) do
    with recommendation when not is_nil(recommendation) <-
           Enum.find(recommendations, &(&1.budget_id == budget_id)),
         {:ok, _revision} <-
           Budgets.reject_recommendation(
             current_user,
             budget_id,
             recommendation.suggested_allocation,
             recommendation.explanation
           ) do
      {:noreply,
       socket
       |> assign_budget_rows(current_user)
       |> put_flash(:info, "Suggestion rejected.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Unable to reject suggestion.")}
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
        %{
          assigns: %{
            current_user: current_user,
            budget_form_mode: :edit,
            budget_editing: %Budget{} = budget
          }
        } =
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
          <h2 class="text-lg font-semibold text-zinc-900">Planner suggestions</h2>
          <ul class="space-y-3 text-sm">
            <li :for={suggestion <- @planner_recommendations}
                class="rounded-lg border border-emerald-100 bg-emerald-50 p-3">
              <p class="font-semibold text-emerald-900"><%= suggestion.budget_name %></p>
              <p class="text-xs text-emerald-800"><%= suggestion.explanation %></p>
              <p class="text-xs text-emerald-700 mt-1">
                Suggested <%= suggestion.currency %> <%= Decimal.to_string(suggestion.suggested_allocation, :normal) %>
                (Δ <%= Decimal.to_string(suggestion.delta, :normal) %>)
              </p>
              <div class="mt-2 flex gap-2">
                <button class="btn btn-xs" type="button" phx-click="accept-suggestion" phx-value-id={suggestion.budget_id}>Accept</button>
                <button class="btn btn-outline btn-xs" type="button" phx-click="reject-suggestion" phx-value-id={suggestion.budget_id}>Reject</button>
              </div>
            </li>
            <li :if={Enum.empty?(@planner_recommendations)} class="rounded-lg border border-dashed border-zinc-200 p-4 text-zinc-500">
              No recommendations yet.
            </li>
          </ul>

          <h2 class="text-lg font-semibold text-zinc-900">Your budgets</h2>

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
                  <p class="text-xs text-zinc-500">
                    <%= budget.target_mode %> • <%= budget.rollover_policy %> • Priority <%= budget.priority %>
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
                  <dt class="text-xs uppercase tracking-wide text-zinc-500">Minimum / Maximum</dt>
                  <dd class="font-medium text-zinc-800"><%= budget.minimum_formatted || "--" %> / <%= budget.maximum_formatted || "--" %></dd>
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
                  <select id="budget_period" name="budget[period]" class="input">
                    <%= Phoenix.HTML.Form.options_for_select(@period_options, select_value(f[:period].value)) %>
                  </select>
                </div>

                <div>
                  <label class="text-sm font-medium text-zinc-700" for="budget_entry_type">Type</label>
                  <select id="budget_entry_type" name="budget[entry_type]" class="input">
                    <%= Phoenix.HTML.Form.options_for_select(@entry_type_options, select_value(f[:entry_type].value)) %>
                  </select>
                </div>
              </div>

              <div class="grid gap-4 md:grid-cols-2">
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="budget_variability">Variability</label>
                  <select id="budget_variability" name="budget[variability]" class="input">
                    <%= Phoenix.HTML.Form.options_for_select(@variability_options, select_value(f[:variability].value)) %>
                  </select>
                </div>

                <.input field={f[:allocation_amount]}
                        label="Allocation amount"
                        type={:number}
                        step="0.01"
                        min="0" />
              </div>

              <div class="grid gap-4 md:grid-cols-2">
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="budget_target_mode">Target mode</label>
                  <select id="budget_target_mode" name="budget[target_mode]" class="input">
                    <%= Phoenix.HTML.Form.options_for_select(@target_mode_options, select_value(f[:target_mode].value)) %>
                  </select>
                </div>
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="budget_rollover_policy">Rollover policy</label>
                  <select id="budget_rollover_policy" name="budget[rollover_policy]" class="input">
                    <%= Phoenix.HTML.Form.options_for_select(@rollover_policy_options, select_value(f[:rollover_policy].value)) %>
                  </select>
                </div>
              </div>

              <div class="grid gap-4 md:grid-cols-3">
                <.input field={f[:minimum_amount]} label="Minimum" type={:number} step="0.01" />
                <.input field={f[:maximum_amount]} label="Maximum" type={:number} step="0.01" />
                <.input field={f[:priority]} label="Priority" type={:number} min="0" max="100" />
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
    recommendations = Budgets.planner_recommendations(current_user, budgets: budgets)

    assign(socket, budget_rows: rows, planner_recommendations: recommendations)
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

  defp target_mode_options do
    Budget.target_modes()
    |> Enum.map(fn mode ->
      {mode |> Atom.to_string() |> String.capitalize(), Atom.to_string(mode)}
    end)
  end

  defp rollover_policy_options do
    Budget.rollover_policies()
    |> Enum.map(fn policy ->
      {policy |> Atom.to_string() |> String.capitalize(), Atom.to_string(policy)}
    end)
  end

  defp select_value(value) when is_atom(value), do: Atom.to_string(value)
  defp select_value(value), do: value
end
