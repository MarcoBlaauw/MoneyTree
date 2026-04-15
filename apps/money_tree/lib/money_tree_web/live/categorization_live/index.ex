defmodule MoneyTreeWeb.CategorizationLive.Index do
  use MoneyTreeWeb, :live_view

  alias MoneyTree.Categorization
  alias MoneyTree.Transactions

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: user}} = socket) do
    {:ok, load(socket, user)}
  end

  @impl true
  def handle_event(
        "recategorize",
        %{"transaction_id" => transaction_id, "category" => category},
        %{assigns: %{current_user: user}} = socket
      ) do
    case Categorization.recategorize_transaction(user, transaction_id, category) do
      {:ok, _} ->
        {:noreply, socket |> load(user) |> put_flash(:info, "Transaction recategorized")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Unable to recategorize transaction")}
    end
  end

  def handle_event("create-rule", %{"rule" => params}, %{assigns: %{current_user: user}} = socket) do
    params =
      params
      |> Map.update("description_keywords", [], &split_csv/1)
      |> Map.update("account_types", [], &split_csv/1)

    case Categorization.create_rule(user, params) do
      {:ok, _} -> {:noreply, socket |> load(user) |> put_flash(:info, "Rule created")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not create rule")}
    end
  end

  def handle_event("delete-rule", %{"id" => id}, %{assigns: %{current_user: user}} = socket) do
    _ = Categorization.delete_rule(user, id)
    {:noreply, load(socket, user)}
  end

  defp split_csv(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp load(socket, user) do
    txns = Transactions.paginate_for_user(user, page: 1, per_page: 20).entries

    assign(socket,
      page_title: "Transactions",
      transactions: txns,
      rules: Categorization.list_rules(user)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-6">
      <.header title="Categorization rules" subtitle="Manage transaction categorization rules under Transactions.">
        <:actions>
          <.link navigate={~p"/app/transactions"} class="btn btn-outline">Back to transactions</.link>
        </:actions>
      </.header>

      <div class="rounded-xl border border-zinc-200 bg-white p-4">
        <h2 class="text-sm font-semibold text-zinc-800">Recent transactions</h2>
        <ul class="mt-3 space-y-2">
          <li :for={transaction <- @transactions} class="flex flex-col gap-2 rounded border border-zinc-100 p-2 md:flex-row md:items-center md:justify-between">
            <div>
              <p class="text-sm font-medium"><%= transaction.description %></p>
              <p class="text-xs text-zinc-500"><%= transaction.account.name %> • <%= transaction.currency %></p>
            </div>
            <.form for={%{}} phx-submit="recategorize" class="flex items-center gap-2">
              <input type="hidden" name="transaction_id" value={transaction.id} />
              <input type="text" name="category" value={Map.get(transaction, :category) || ""} class="input input-bordered input-sm" placeholder="Category" />
              <button type="submit" class="btn btn-sm">Save</button>
            </.form>
          </li>
        </ul>
      </div>

      <div class="rounded-xl border border-zinc-200 bg-white p-4">
        <h2 class="text-sm font-semibold text-zinc-800">Rules</h2>
        <.form for={%{}} as={:rule} phx-submit="create-rule" class="mt-3 grid gap-2 md:grid-cols-3">
          <input name="rule[category]" placeholder="Category" class="input input-bordered input-sm" required />
          <input name="rule[merchant_regex]" placeholder="Merchant regex" class="input input-bordered input-sm" />
          <input name="rule[description_keywords]" placeholder="Keywords csv" class="input input-bordered input-sm" />
          <input name="rule[account_types]" placeholder="Account types csv" class="input input-bordered input-sm" />
          <input name="rule[min_amount]" placeholder="Min amount" class="input input-bordered input-sm" />
          <input name="rule[max_amount]" placeholder="Max amount" class="input input-bordered input-sm" />
          <input name="rule[priority]" value="100" class="input input-bordered input-sm" />
          <button type="submit" class="btn btn-sm md:col-span-3">Create rule</button>
        </.form>

        <ul class="mt-4 space-y-2">
          <li :for={rule <- @rules} class="flex items-center justify-between rounded border border-zinc-100 p-2">
            <p class="text-sm"><%= rule.category %> <span class="text-xs text-zinc-500">prio <%= rule.priority %></span></p>
            <button phx-click="delete-rule" phx-value-id={rule.id} class="btn btn-outline btn-xs">Delete</button>
          </li>
        </ul>
      </div>
    </section>
    """
  end
end
