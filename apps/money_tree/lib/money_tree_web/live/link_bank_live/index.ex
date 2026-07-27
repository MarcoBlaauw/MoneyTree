defmodule MoneyTreeWeb.LinkBankLive.Index do
  @moduledoc """
  Bank-linking workspace: SimpleFIN Bridge (primary) and Plaid (legacy, optional).
  """

  use MoneyTreeWeb, :live_view

  alias Ecto.Changeset
  alias MoneyTree.BankSync.ProviderRegistry
  alias MoneyTree.Institutions
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Institutions.Institution
  alias MoneyTree.Repo
  alias MoneyTree.SimpleFin
  alias MoneyTree.SimpleFin.Redaction
  alias MoneyTree.Synchronization

  @max_events 50

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: current_user}} = socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Link bank",
       plaid_enabled?: ProviderRegistry.enabled?("plaid"),
       claim_form: to_form(%{"setup_token" => ""}, as: :simplefin),
       claiming?: false,
       claim_error: nil,
       pending_connection_id: nil,
       events: [],
       row_errors: %{}
     )
     |> load_connections(current_user)}
  end

  @impl true
  def handle_event("validate-claim", %{"simplefin" => params}, socket) do
    {:noreply, assign(socket, :claim_form, to_form(params, as: :simplefin))}
  end

  def handle_event(
        "claim-setup-token",
        %{"simplefin" => %{"setup_token" => setup_token}},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    socket = assign(socket, claiming?: true, claim_error: nil)

    with :ok <- ensure_enabled("simplefin"),
         {:ok, access_url} <- simplefin_client().claim_setup_token(setup_token),
         {:ok, validation} <- simplefin_client().get_balances(access_url),
         {:ok, institution} <- ensure_simplefin_institution(),
         {:ok, _connection} <-
           persist_simplefin_connection(current_user, institution, access_url, validation) do
      {:noreply,
       socket
       |> assign(claiming?: false, claim_form: to_form(%{"setup_token" => ""}, as: :simplefin))
       |> log_event(:success, "SimpleFIN connection claimed", %{
         accounts: length(List.wrap(validation["accounts"]))
       })
       |> load_connections(current_user)
       |> put_flash(:info, "SimpleFIN connection claimed. Review accounts below to import.")}
    else
      {:error, reason} ->
        message = simplefin_error_message(reason)

        {:noreply,
         socket
         |> assign(claiming?: false, claim_error: message)
         |> log_event(:error, "SimpleFIN claim failed", %{reason: inspect(reason)})}
    end
  end

  def handle_event(
        "confirm-import",
        %{"connection_id" => connection_id} = params,
        %{assigns: %{current_user: current_user}} = socket
      ) do
    account_ids = params |> Map.get("account_ids", []) |> List.wrap()

    with {:ok, %Connection{} = connection} <-
           Institutions.get_active_connection_for_user(current_user, connection_id),
         {:ok, connection} <- persist_import_review(connection, account_ids),
         :ok <- Synchronization.schedule_initial_sync(connection) do
      {:noreply,
       socket
       |> log_event(:success, "Import confirmed", %{accounts: length(account_ids)})
       |> load_connections(current_user)
       |> put_flash(:info, "Import confirmed. Sync scheduled.")}
    else
      _error ->
        {:noreply, log_event(socket, :error, "Unable to confirm import", %{})}
    end
  end

  def handle_event(
        "sync-connection",
        %{"connection_id" => connection_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    with {:ok, %Connection{} = connection} <-
           Institutions.get_active_connection_for_user(current_user, connection_id),
         :ok <- Synchronization.schedule_incremental_sync(connection) do
      {:noreply,
       socket
       |> log_event(:success, "Refresh scheduled", %{})
       |> put_flash(:info, "Refresh scheduled.")}
    else
      _error ->
        {:noreply, log_event(socket, :error, "Unable to schedule refresh", %{})}
    end
  end

  def handle_event(
        "revoke-connection",
        %{"connection_id" => connection_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    case Institutions.mark_connection_revoked(current_user, connection_id,
           reason: "user_initiated"
         ) do
      {:ok, _connection} ->
        {:noreply,
         socket
         |> log_event(:success, "Connection revoked", %{})
         |> load_connections(current_user)
         |> put_flash(:info, "Connection revoked.")}

      _error ->
        {:noreply, log_event(socket, :error, "Unable to revoke connection", %{})}
    end
  end

  def handle_event(
        "purge-legacy-credentials",
        %{"connection_id" => connection_id},
        %{assigns: %{current_user: current_user}} = socket
      ) do
    case Institutions.purge_legacy_credentials(current_user, connection_id) do
      {:ok, _connection} ->
        {:noreply,
         socket
         |> log_event(:success, "Legacy credentials purged", %{})
         |> load_connections(current_user)
         |> put_flash(:info, "Legacy credentials purged.")}

      _error ->
        {:noreply, log_event(socket, :error, "Unable to purge credentials", %{})}
    end
  end

  def handle_event(
        "start-plaid-link",
        _params,
        %{assigns: %{current_user: current_user, plaid_enabled?: true}} = socket
      ) do
    request = %{
      "user" => %{"client_user_id" => to_string(current_user.id)},
      "products" => ["transactions"],
      "country_codes" => ["US"],
      "language" => "en",
      "client_name" => "MoneyTree"
    }

    case plaid_client().create_link_token(request) do
      {:ok, %{"link_token" => link_token}} ->
        {:noreply,
         socket
         |> log_event(:info, "Plaid Link token issued", %{})
         |> push_event("plaid:open", %{link_token: link_token})}

      {:error, _reason} ->
        {:noreply,
         socket
         |> log_event(:error, "Unable to start Plaid Link", %{})
         |> put_flash(:error, "Unable to start Plaid Link right now.")}
    end
  end

  def handle_event("start-plaid-link", _params, socket), do: {:noreply, socket}

  def handle_event(
        "plaid-link-success",
        %{"public_token" => public_token} = params,
        %{assigns: %{current_user: current_user}} = socket
      ) do
    institution_name = get_in(params, ["metadata", "institution", "name"])

    with {:ok, institution_id} <- ensure_plaid_institution(institution_name),
         {:ok, payload} <- plaid_client().exchange_public_token(public_token),
         {:ok, connection} <-
           persist_plaid_connection(current_user, institution_id, payload, institution_name),
         :ok <- Synchronization.schedule_initial_sync(connection) do
      {:noreply,
       socket
       |> log_event(:success, "Plaid connection linked", %{institution: institution_name})
       |> load_connections(current_user)
       |> put_flash(:info, "Bank linked via Plaid.")}
    else
      _error ->
        {:noreply, log_event(socket, :error, "Unable to complete Plaid Link", %{})}
    end
  end

  def handle_event("plaid-link-exit", _params, socket) do
    {:noreply, log_event(socket, :info, "Plaid Link closed", %{})}
  end

  defp load_connections(socket, current_user) do
    connections =
      current_user
      |> Institutions.list_active_connections(preload: [:institution, :accounts])
      |> Institutions.preload_defaults()

    simplefin_connections = Enum.filter(connections, &(&1.provider == "simplefin"))

    legacy_connections =
      current_user
      |> Institutions.list_connections_for_user(preload: [:institution, :accounts])
      |> Enum.filter(&(&1.provider in ["teller", "plaid"]))

    socket
    |> assign(:simplefin_connections, simplefin_connections)
    |> assign(:legacy_connections, legacy_connections)
  end

  defp ensure_enabled(provider) do
    if ProviderRegistry.enabled?(provider), do: :ok, else: {:error, :disabled}
  end

  defp ensure_simplefin_institution do
    slug = "simplefin-bridge"
    external_id = "simplefin:#{slug}"

    case Repo.get_by(Institution, external_id: external_id) do
      %Institution{} = institution ->
        {:ok, institution}

      nil ->
        %Institution{}
        |> Institution.changeset(%{
          name: "SimpleFIN Bridge",
          slug: slug,
          external_id: external_id,
          metadata: %{"provider" => "simplefin"}
        })
        |> Repo.insert()
    end
  end

  defp persist_simplefin_connection(user, institution, access_url, validation) do
    credentials =
      Jason.encode!(%{
        "access_url" => access_url,
        "claimed_at" => DateTime.to_iso8601(DateTime.utc_now())
      })

    provider_metadata = %{
      "simplefin" => %{
        "connections" => Redaction.redact(validation["connections"] || []),
        "errors" => Redaction.redact(validation["errors"] || []),
        "import_review" => %{
          "status" => "pending",
          "discovered_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "account_count" => length(List.wrap(validation["accounts"])),
          "discovered_accounts" => serialize_simplefin_accounts(validation["accounts"])
        }
      }
    }

    attrs = %{
      encrypted_credentials: credentials,
      provider: "simplefin",
      provider_metadata: provider_metadata,
      metadata: %{"status" => "active", "provider" => "simplefin"}
    }

    case existing_simplefin_connection(user) do
      {:ok, %Connection{} = connection} ->
        Institutions.update_connection(
          user,
          connection,
          Map.put(attrs, :institution_id, institution.id)
        )

      {:error, :not_found} ->
        Institutions.create_connection(user, institution.id, attrs)
    end
  end

  defp existing_simplefin_connection(user) do
    user
    |> Institutions.list_active_connections()
    |> Enum.find(&(&1.provider == "simplefin"))
    |> case do
      %Connection{} = connection -> {:ok, connection}
      nil -> {:error, :not_found}
    end
  end

  defp serialize_simplefin_accounts(accounts) do
    accounts
    |> List.wrap()
    |> Enum.map(fn account ->
      %{
        "id" => account["id"],
        "name" => account["name"],
        "balance" => account["balance"]
      }
    end)
  end

  defp persist_import_review(%Connection{} = connection, account_ids) do
    SimpleFin.confirm_import(connection, account_ids)
  end

  defp ensure_plaid_institution(name) when is_binary(name) and name != "" do
    slug = normalize_slug(name)
    external_id = "plaid:#{slug}"

    case Repo.get_by(Institution, external_id: external_id) do
      %Institution{id: id} ->
        {:ok, id}

      nil ->
        %Institution{}
        |> Institution.changeset(%{
          name: name,
          slug: slug,
          external_id: external_id,
          metadata: %{"provider" => "plaid"}
        })
        |> Repo.insert()
        |> case do
          {:ok, institution} -> {:ok, institution.id}
          {:error, %Changeset{} = changeset} -> {:error, changeset}
        end
    end
  end

  defp ensure_plaid_institution(_name), do: {:error, :missing_institution}

  defp persist_plaid_connection(user, institution_id, payload, institution_name) do
    attrs = %{
      encrypted_credentials: Jason.encode!(normalize_payload(payload)),
      provider: "plaid",
      provider_metadata: normalize_payload(payload),
      metadata: %{
        "status" => "active",
        "provider" => "plaid",
        "institution_name" => institution_name
      }
    }

    case Institutions.get_connection_for_institution(user, institution_id, provider: "plaid") do
      {:ok, %Connection{} = connection} -> Institutions.update_connection(user, connection, attrs)
      {:error, :not_found} -> Institutions.create_connection(user, institution_id, attrs)
    end
  end

  defp normalize_payload(payload) when is_map(payload) do
    Enum.into(payload, %{}, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp normalize_payload(_payload), do: %{}

  defp normalize_slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  defp simplefin_error_message(:invalid_setup_token),
    do: "That setup token does not look valid. Please create a new one and try again."

  defp simplefin_error_message(:claim_forbidden),
    do: "SimpleFIN rejected this setup token. It may have expired or already been used."

  defp simplefin_error_message(:disabled), do: "SimpleFIN is disabled for new connections."
  defp simplefin_error_message(_reason), do: "Unable to claim this SimpleFIN setup token."

  defp log_event(socket, level, message, payload) do
    event = %{level: level, message: message, payload: payload, at: DateTime.utc_now()}
    events = Enum.take([event | socket.assigns.events], @max_events)
    assign(socket, :events, events)
  end

  defp simplefin_client,
    do: Application.get_env(:money_tree, :simplefin_client, MoneyTree.SimpleFin.Client)

  defp plaid_client, do: Application.get_env(:money_tree, :plaid_client, MoneyTree.Plaid.Client)

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-6">
      <.header title="Link bank" subtitle="Connect accounts via SimpleFIN Bridge or Plaid, and manage existing connections.">
      </.header>

      <div class="rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm">
        <h2 class="text-lg font-semibold text-zinc-900">SimpleFIN Bridge</h2>
        <p class="mt-1 text-sm text-zinc-500">
          Create a one-time setup token at your SimpleFIN provider, then paste it below. MoneyTree stores only the resulting Access URL.
        </p>

        <.form for={@claim_form} id="simplefin-claim-form" phx-change="validate-claim" phx-submit="claim-setup-token" class="mt-4 flex flex-wrap items-end gap-3">
          <div class="flex-1 min-w-[16rem]">
            <label class="text-sm font-medium text-zinc-700" for={@claim_form[:setup_token].id}>Setup token</label>
            <input type="text" id={@claim_form[:setup_token].id} name="simplefin[setup_token]" value={@claim_form[:setup_token].value} class="input mt-1 w-full" placeholder="Paste your SimpleFIN setup token" />
          </div>
          <button type="submit" class="btn" disabled={@claiming?}>
            <%= if @claiming?, do: "Claiming...", else: "Claim setup token" %>
          </button>
        </.form>
        <p :if={@claim_error} class="mt-3 text-sm text-rose-600" role="alert"><%= @claim_error %></p>
      </div>

      <div :for={connection <- @simplefin_connections} class="rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h3 class="text-base font-semibold text-zinc-900"><%= connection.institution && connection.institution.name %></h3>
            <p class="text-sm text-zinc-500"><%= length(connection.accounts || []) %> account(s) linked</p>
          </div>
          <div class="flex gap-2">
            <button type="button" class="btn btn-outline" phx-click="sync-connection" phx-value-connection_id={connection.id}>Refresh</button>
            <button type="button" class="btn btn-outline" phx-click="revoke-connection" phx-value-connection_id={connection.id}>Revoke</button>
          </div>
        </div>

        <.simplefin_import_review connection={connection} />
      </div>

      <div :if={@plaid_enabled?} class="rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm">
        <h2 class="text-lg font-semibold text-zinc-900">Plaid (legacy)</h2>
        <p class="mt-1 text-sm text-zinc-500">Connect a bank via the Plaid Link widget.</p>
        <div id="plaid-link-root" phx-hook="PlaidLink" class="mt-4">
          <button type="button" class="btn btn-outline" phx-click="start-plaid-link">Connect via Plaid</button>
        </div>
      </div>

      <div :if={@legacy_connections != []} class="rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm">
        <h2 class="text-lg font-semibold text-zinc-900">Legacy connections</h2>
        <p class="mt-1 text-sm text-zinc-500">Older Teller and Plaid connections. Purge stored credentials for connections you no longer use.</p>

        <ul class="mt-4 space-y-3">
          <li :for={connection <- @legacy_connections} class="flex items-center justify-between rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-3 text-sm">
            <div>
              <p class="font-medium text-zinc-900"><%= connection.institution && connection.institution.name %></p>
              <p class="text-xs uppercase tracking-wide text-zinc-500"><%= connection.provider %></p>
            </div>
            <button type="button" class="text-xs font-semibold text-zinc-700 underline" phx-click="purge-legacy-credentials" phx-value-connection_id={connection.id}>
              Purge credentials
            </button>
          </li>
        </ul>
      </div>

      <div :if={@events != []} class="rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm">
        <h3 class="text-sm font-semibold text-zinc-900">Activity</h3>
        <ul class="mt-3 space-y-2 text-sm">
          <li :for={event <- @events} class={event_class(event.level)}>
            <span class="font-medium"><%= event.message %></span>
            <span class="ml-2 text-xs text-zinc-500"><%= Calendar.strftime(event.at, "%H:%M:%S") %></span>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  attr :connection, :map, required: true

  defp simplefin_import_review(assigns) do
    review = get_in(assigns.connection.provider_metadata, ["simplefin", "import_review"]) || %{}
    pending_new_accounts = review["pending_new_accounts"] || []

    assigns =
      assigns
      |> assign(:review, review)
      |> assign(:pending_new_accounts, pending_new_accounts)

    ~H"""
    <div :if={@review["status"] == "pending"} class="mt-4 rounded-xl border border-amber-200 bg-amber-50 p-4">
      <p class="text-sm font-semibold text-amber-800">Review accounts to import</p>
      <form phx-submit="confirm-import" class="mt-3 space-y-2">
        <input type="hidden" name="connection_id" value={@connection.id} />
        <label :for={account <- @review["discovered_accounts"] || []} class="flex items-center gap-2 text-sm text-zinc-700">
          <input type="checkbox" name="account_ids[]" value={account["id"]} checked />
          <%= account["name"] %>
        </label>
        <button type="submit" class="btn">Confirm import</button>
      </form>
    </div>

    <div :if={@pending_new_accounts != []} class="mt-4 rounded-xl border border-amber-200 bg-amber-50 p-4">
      <p class="text-sm font-semibold text-amber-800">New accounts found at SimpleFIN</p>
      <p class="mt-1 text-xs text-amber-700">
        These accounts weren't part of your original import. Select which ones to add.
      </p>
      <form phx-submit="confirm-import" class="mt-3 space-y-2">
        <input type="hidden" name="connection_id" value={@connection.id} />
        <label :for={account <- @pending_new_accounts} class="flex items-center gap-2 text-sm text-zinc-700">
          <input type="checkbox" name="account_ids[]" value={account["id"]} checked />
          <%= account["name"] %>
        </label>
        <button type="submit" class="btn">Add selected accounts</button>
      </form>
    </div>
    """
  end

  defp event_class(:success), do: "text-emerald-700"
  defp event_class(:error), do: "text-rose-600"
  defp event_class(_level), do: "text-zinc-600"
end
