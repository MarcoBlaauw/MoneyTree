defmodule MoneyTreeWeb.TransfersLive do
  @moduledoc """
  LiveView responsible for authorising and confirming transfers with step-up hooks.
  """

  use MoneyTreeWeb, :live_view

  alias MoneyTree.Accounts
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Transfers
  alias MoneyTree.Transfers.TransferRequest
  alias MoneyTreeWeb.CoreComponents

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: current_user}} = socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Transfers",
       accounts: Accounts.list_accessible_accounts(current_user),
       changeset: Transfers.change_transfer(current_user, %{}),
       step_up_required?: false,
       step_up_verified?: false,
       locked?: false,
       last_transfer: nil
     )}
  end

  @impl true
  def handle_event("validate", %{"transfer" => params}, %{assigns: %{current_user: user}} = socket) do
    changeset = Transfers.change_transfer(user, params)
    {:noreply, assign(socket, changeset: changeset)}
  end

  def handle_event("request-step-up", _params, socket) do
    {:noreply,
     socket
     |> assign(step_up_required?: true, step_up_verified?: false)
     |> put_flash(:info, "Step-up verification required. Complete the verification to proceed.")}
  end

  def handle_event("step-up-completed", _params, %{assigns: %{step_up_required?: false}} = socket) do
    {:noreply, put_flash(socket, :info, "No step-up required at this time.")}
  end

  def handle_event("step-up-completed", _params, socket) do
    {:noreply,
     socket
     |> assign(step_up_verified?: true)
     |> put_flash(:info, "Step-up verification confirmed.")}
  end

  def handle_event("cancel-step-up", _params, socket) do
    {:noreply, assign(socket, step_up_required?: false, step_up_verified?: false)}
  end

  def handle_event("lock-interface", _params, socket) do
    {:noreply,
     socket
     |> assign(locked?: true)
     |> put_flash(:info, "Transfer tools locked. Unlock to continue.")}
  end

  def handle_event("unlock-interface", _params, %{assigns: %{current_user: current_user}} = socket) do
    {:noreply,
     socket
     |> assign(locked?: false, accounts: Accounts.list_accessible_accounts(current_user))
     |> put_flash(:info, "Transfer tools unlocked.")}
  end

  def handle_event("confirm-transfer", _params, %{assigns: %{locked?: true}} = socket) do
    {:noreply, put_flash(socket, :error, "Unlock transfers before confirming a transfer.")}
  end

  def handle_event("confirm-transfer", %{"transfer" => params}, socket) do
    with :ok <- ensure_step_up(socket.assigns),
         {:ok, result} <- submit_transfer(socket, params) do
      {:noreply, transfer_success(socket, result)}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset)}

      {:error, reason} when is_binary(reason) ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-6">
      <.header title="Transfers" subtitle="Move funds between your accounts.">
        <:actions>
          <button class="btn btn-outline" type="button" phx-click="lock-interface">Lock</button>
          <button :if={@locked?} class="btn" type="button" phx-click="unlock-interface">Unlock</button>
        </:actions>
      </.header>

      <div class="grid gap-6 lg:grid-cols-2">
        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <h2 class="text-lg font-semibold text-zinc-900">Initiate a transfer</h2>
          <p class="text-sm text-zinc-500">
            Select source and destination accounts, then confirm the amount to move.
          </p>

          <.simple_form for={@changeset}
                        id="transfer-form"
                        phx-change="validate"
                        phx-submit="confirm-transfer">
            <:inner_block :let={f}>
              <div class="space-y-4">
                <div>
                  <label class="text-sm font-medium text-zinc-700" for="transfer_source_account_id">From account</label>
                  <select id="transfer_source_account_id"
                          name="transfer[source_account_id]"
                          class="input"
                          disabled={@locked?}>
                    <%= Phoenix.HTML.Form.options_for_select(account_options(@accounts), f[:source_account_id].value) %>
                  </select>
                  <p :for={error <- errors_on(@changeset, :source_account_id)} class="text-sm text-red-600"><%= error %></p>
                </div>

                <div>
                  <label class="text-sm font-medium text-zinc-700" for="transfer_destination_account_id">To account</label>
                  <select id="transfer_destination_account_id"
                          name="transfer[destination_account_id]"
                          class="input"
                          disabled={@locked?}>
                    <%= Phoenix.HTML.Form.options_for_select(account_options(@accounts), f[:destination_account_id].value) %>
                  </select>
                  <p :for={error <- errors_on(@changeset, :destination_account_id)} class="text-sm text-red-600"><%= error %></p>
                </div>

                <.input field={f[:amount]} label="Amount" type="number" step="0.01" min="0" disabled={@locked?} />
                <p :for={error <- errors_on(@changeset, :amount)} class="text-sm text-red-600"><%= error %></p>

                <.input field={f[:memo]} label="Memo" type="textarea" placeholder="Optional memo" disabled={@locked?} />
                <p :for={error <- errors_on(@changeset, :memo)} class="text-sm text-red-600"><%= error %></p>

                <div class="flex flex-wrap gap-2">
                  <button type="button" class="btn btn-outline" phx-click="request-step-up">Require step-up</button>
                  <button type="button" class="btn btn-outline" phx-click="step-up-completed">Step-up completed</button>
                  <button type="button" class="btn btn-ghost" phx-click="cancel-step-up">Reset</button>
                </div>

                <p class="rounded-md border border-zinc-200 bg-zinc-50 p-3 text-sm text-zinc-600">
                  <span class="font-medium text-zinc-800">Verification:</span>
                  <%= cond do %>
                    <% @locked? -> %> Interface locked. Unlock to continue.
                    <% @step_up_required? and @step_up_verified? -> %> Step-up complete. You may submit the transfer.
                    <% @step_up_required? -> %> Awaiting external verification event.
                    <% true -> %> No additional verification required.
                  <% end %>
                </p>

                <div class="flex justify-end">
                  <button type="submit" class="btn" disabled={@locked?}>Confirm transfer</button>
                </div>
              </div>
            </:inner_block>
          </.simple_form>
        </div>

        <div class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <h2 class="text-lg font-semibold text-zinc-900">Transfer history</h2>
          <p class="text-sm text-zinc-500">Recent confirmation details appear here after submission.</p>

          <div :if={@last_transfer} class="space-y-2 rounded-lg border border-zinc-100 bg-zinc-50 p-4">
            <p class="text-sm text-zinc-600">Last transfer</p>
            <p class="text-base font-semibold text-zinc-900"><%= @last_transfer.amount %></p>
            <p class="text-sm text-zinc-600">
              From <span class="font-medium text-zinc-800"><%= @last_transfer.source %></span>
              to <span class="font-medium text-zinc-800"><%= @last_transfer.destination %></span>
            </p>
            <p class="text-sm text-zinc-600">Memo: <%= @last_transfer.memo || "None" %></p>
            <p class="text-xs text-zinc-500">
              Confirmed at <%= @last_transfer.confirmed_at %>
            </p>
          </div>

          <div :if={!@last_transfer} class="rounded-lg border border-dashed border-zinc-200 p-6 text-center text-sm text-zinc-500">
            No transfers confirmed during this session.
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp ensure_step_up(%{step_up_required?: true, step_up_verified?: false}) do
    {:error, "Complete step-up verification before confirming the transfer."}
  end

  defp ensure_step_up(_assigns), do: :ok

  defp submit_transfer(%{assigns: %{current_user: current_user}} = socket, params) do
    Transfers.submit_transfer(current_user, params)
  end

  defp transfer_success(socket, %{transfer: %TransferRequest{} = transfer, source: source, destination: destination}) do
    formatted_amount = Accounts.format_money(transfer.amount, transfer.currency, [])

    socket
    |> put_flash(:info, "Transfer scheduled successfully.")
    |> assign(
      changeset: Transfers.change_transfer(socket.assigns.current_user, %{}),
      accounts: Accounts.list_accessible_accounts(socket.assigns.current_user),
      step_up_required?: false,
      step_up_verified?: false,
      last_transfer: %{
        amount: formatted_amount,
        source: transfer_source_name(transfer, source),
        destination: transfer_destination_name(transfer, destination),
        memo: transfer.memo,
        confirmed_at: Calendar.strftime(DateTime.utc_now(), "%b %d, %Y %H:%M UTC")
      }
    )
  end

  defp account_options(accounts) do
    Enum.map(accounts, fn account ->
      {account.name <> " (" <> account.currency <> ")", account.id}
    end)
  end

  defp errors_on(%Ecto.Changeset{} = changeset, field) do
    changeset
    |> Map.get(:errors)
    |> Keyword.get_values(field)
    |> Enum.map(&CoreComponents.translate_error/1)
  end

  defp transfer_source_name(%TransferRequest{source_account: %Account{name: name}}, _source), do: name
  defp transfer_source_name(_transfer, %Account{name: name}), do: name

  defp transfer_destination_name(%TransferRequest{destination_account: %Account{name: name}}, _dest),
    do: name

  defp transfer_destination_name(_transfer, %Account{name: name}), do: name
end
