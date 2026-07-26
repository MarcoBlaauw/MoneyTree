defmodule MoneyTreeWeb.SimpleFinController do
  use MoneyTreeWeb, :controller

  alias Ecto.Changeset
  alias MoneyTree.BankSync.ProviderRegistry
  alias MoneyTree.Institutions
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Institutions.Institution
  alias MoneyTree.Repo
  alias MoneyTree.SimpleFin.Redaction

  def config(conn, _params) do
    json(conn, %{
      data: %{
        enabled: ProviderRegistry.enabled?("simplefin"),
        create_url:
          simplefin_config(:create_url, "https://bridge.simplefin.org/simplefin/create"),
        primary_provider: ProviderRegistry.primary_provider(),
        providers: ProviderRegistry.list_enabled(),
        copy: %{
          title: "SimpleFIN Bridge",
          description:
            "SimpleFIN Bridge connects read-only financial data to MoneyTree using a setup token."
        }
      }
    })
  end

  def connections(conn, _params) do
    user = conn.assigns.current_user

    connections =
      user
      |> Institutions.list_active_connections(preload: [:institution, :accounts])
      |> Institutions.preload_defaults()
      |> Enum.filter(&(&1.provider == "simplefin"))
      |> Enum.map(&serialize_connection/1)

    json(conn, %{data: %{connections: connections}})
  end

  def claim(conn, %{"setup_token" => setup_token} = params) when is_binary(setup_token) do
    user = conn.assigns.current_user

    with :ok <- ensure_enabled(conn),
         {:ok, access_url} <- simplefin_client().claim_setup_token(setup_token),
         {:ok, validation} <- simplefin_client().get_balances(access_url),
         {:ok, institution} <- ensure_institution(validation, params),
         {:ok, connection} <- persist_connection(user, institution, access_url, validation) do
      json(conn, %{
        data: %{
          connection_id: connection.id,
          institution_id: institution.id,
          institution_name: institution.name,
          accounts: serialize_accounts(validation["accounts"]),
          connections: serialize_connections(validation["connections"]),
          errors: Redaction.redact(validation["errors"] || []),
          status: claim_status(validation),
          import_review: serialize_import_review(connection)
        }
      })
    else
      {:error, :disabled} ->
        disabled(conn)

      {:error, %Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Changeset.traverse_errors(changeset, &translate_error/1)})

      {:error, reason} ->
        render_simplefin_error(conn, reason)
    end
  end

  def claim(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "setup_token is required"})
  end

  def sync(conn, %{"connection_id" => connection_id}) when is_binary(connection_id) do
    user = conn.assigns.current_user

    with :ok <- ensure_enabled(conn),
         {:ok, %Connection{} = connection} <-
           Institutions.get_active_connection_for_user(user, connection_id),
         true <- connection.provider == "simplefin",
         :ok <- schedule_incremental_sync(connection) do
      json(conn, %{data: %{connection_id: connection.id, status: "scheduled"}})
    else
      {:error, :disabled} ->
        disabled(conn)

      false ->
        conn |> put_status(:not_found) |> json(%{error: "connection not found"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "connection not found"})

      {:error, reason} ->
        render_simplefin_error(conn, reason)
    end
  end

  def sync(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "connection_id is required"})
  end

  def confirm_import(conn, %{"connection_id" => connection_id, "account_ids" => account_ids})
      when is_binary(connection_id) and is_list(account_ids) do
    user = conn.assigns.current_user
    account_ids = account_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    with :ok <- ensure_enabled(conn),
         {:account_ids, true} <- {:account_ids, account_ids != []},
         {:ok, %Connection{} = connection} <-
           Institutions.get_active_connection_for_user(user, connection_id),
         true <- connection.provider == "simplefin",
         {:ok, connection} <- persist_import_review(connection, account_ids),
         :ok <- schedule_initial_sync(connection) do
      json(conn, %{
        data: %{
          connection_id: connection.id,
          status: "scheduled",
          import_review: serialize_import_review(connection)
        }
      })
    else
      {:error, :disabled} ->
        disabled(conn)

      {:account_ids, false} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Select at least one account to import."})

      false ->
        conn |> put_status(:not_found) |> json(%{error: "connection not found"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "connection not found"})

      {:error, %Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Changeset.traverse_errors(changeset, &translate_error/1)})

      {:error, reason} ->
        render_simplefin_error(conn, reason)
    end
  end

  def confirm_import(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "connection_id and account_ids are required"})
  end

  def revoke(conn, %{"connection_id" => connection_id}) when is_binary(connection_id) do
    user = conn.assigns.current_user

    case Institutions.get_active_connection_for_user(user, connection_id, preload: [:institution]) do
      {:ok, %Connection{provider: "simplefin"} = connection} ->
        with {:ok, _revoked} <-
               Institutions.mark_connection_revoked(user, connection_id, reason: "user_initiated") do
          json(conn, %{data: %{connection_id: connection.id, status: "revoked"}})
        end

      {:ok, %Connection{}} ->
        conn |> put_status(:not_found) |> json(%{error: "connection not found"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "connection not found"})
    end
  end

  def revoke(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "connection_id is required"})
  end

  defp ensure_enabled(_conn) do
    if ProviderRegistry.enabled?("simplefin"), do: :ok, else: {:error, :disabled}
  end

  defp disabled(conn) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{error: "SimpleFIN is disabled for new connections", data: %{enabled: false}})
  end

  defp ensure_institution(_validation, params) do
    name =
      params["institution_name"] ||
        "SimpleFIN Bridge"

    slug = normalize_slug(name)
    external_id = "simplefin:#{slug}"

    case Repo.get_by(Institution, external_id: external_id) do
      %Institution{} = institution ->
        {:ok, institution}

      nil ->
        %Institution{}
        |> Institution.changeset(%{
          name: name,
          slug: slug,
          external_id: external_id,
          metadata: %{"provider" => "simplefin"}
        })
        |> Repo.insert()
    end
  end

  defp persist_connection(user, institution, access_url, validation) do
    credentials =
      Jason.encode!(%{
        "access_url" => access_url,
        "claimed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "protocol_version" => to_string(simplefin_config(:protocol_version, "2"))
      })

    provider_metadata = %{
      "simplefin" => %{
        "protocol_versions" => ["1", "2"],
        "selected_protocol_version" => to_string(simplefin_config(:protocol_version, "2")),
        "connections" => Redaction.redact(validation["connections"] || []),
        "last_balances_only_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "errors" => Redaction.redact(validation["errors"] || []),
        "import_review" => %{
          "status" => "pending",
          "discovered_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "account_count" => length(List.wrap(validation["accounts"])),
          "discovered_accounts" => serialize_accounts(validation["accounts"])
        }
      }
    }

    attrs = %{
      encrypted_credentials: credentials,
      provider: "simplefin",
      provider_metadata: provider_metadata,
      metadata: %{"status" => "active", "provider" => "simplefin"}
    }

    case get_simplefin_connection(user) do
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

  defp get_simplefin_connection(user) do
    user
    |> Institutions.list_active_connections()
    |> Enum.find(&(&1.provider == "simplefin"))
    |> case do
      %Connection{} = connection -> {:ok, connection}
      nil -> {:error, :not_found}
    end
  end

  defp serialize_accounts(accounts) do
    accounts
    |> List.wrap()
    |> Enum.map(fn account ->
      %{
        id: account["id"],
        name: account["name"],
        currency: account["currency"],
        balance: account["balance"],
        available_balance: account["available-balance"],
        conn_id: account["conn_id"]
      }
    end)
  end

  defp serialize_connections(connections) do
    connections
    |> List.wrap()
    |> Enum.map(fn connection ->
      %{
        conn_id: connection["conn_id"],
        name: connection["name"],
        org_id: connection["org_id"],
        org_name: connection["org_name"],
        org_url: connection["org_url"],
        sfin_url: Redaction.redact(connection["sfin_url"])
      }
    end)
  end

  defp serialize_connection(%Connection{} = connection) do
    %{
      id: connection.id,
      provider: connection.provider,
      institution_name: connection.institution && connection.institution.name,
      account_count: length(connection.accounts || []),
      status: if(connection.last_sync_error, do: "needs_attention", else: "connected"),
      last_synced_at: format_datetime(connection.last_synced_at),
      last_sync_error: connection.last_sync_error,
      import_review: serialize_import_review(connection)
    }
  end

  defp serialize_import_review(%Connection{} = connection) do
    connection.provider_metadata
    |> get_in(["simplefin", "import_review"])
    |> case do
      review when is_map(review) ->
        %{
          status: review["status"],
          account_count: review["account_count"],
          selected_count: review["selected_count"],
          discovered_at: review["discovered_at"],
          confirmed_at: review["confirmed_at"],
          accounts: review["discovered_accounts"] || []
        }

      _ ->
        nil
    end
  end

  defp persist_import_review(%Connection{} = connection, account_ids) do
    current_review =
      connection.provider_metadata
      |> get_in(["simplefin", "import_review"])
      |> normalize_map()

    provider_metadata =
      put_simplefin_metadata(connection.provider_metadata, %{
        "import_review" =>
          Map.merge(current_review, %{
            "status" => "confirmed",
            "account_ids" => account_ids,
            "selected_count" => length(account_ids),
            "confirmed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          })
      })

    connection
    |> Connection.changeset(%{provider_metadata: provider_metadata})
    |> Repo.update()
  end

  defp claim_status(validation) do
    case List.wrap(validation["errors"]) do
      [] -> "connected"
      _errors -> "connected_with_provider_errors"
    end
  end

  defp render_simplefin_error(conn, :invalid_setup_token) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error:
        "That setup token does not look valid. Please create a new SimpleFIN setup token and try again."
    })
  end

  defp render_simplefin_error(conn, :insecure_claim_url) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error:
        "MoneyTree rejected this token because it did not point to a secure SimpleFIN endpoint."
    })
  end

  defp render_simplefin_error(conn, :claim_forbidden) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error:
        "SimpleFIN rejected this setup token. It may have expired, already been used, or been exposed. Please disable it in SimpleFIN and create a new one."
    })
  end

  defp render_simplefin_error(conn, :payment_required) do
    conn
    |> put_status(:payment_required)
    |> json(%{
      error:
        "SimpleFIN says this connection requires an active subscription before MoneyTree can sync it."
    })
  end

  defp render_simplefin_error(conn, :access_revoked) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error:
        "MoneyTree can no longer access this SimpleFIN connection. Please reconnect it from SimpleFIN."
    })
  end

  defp render_simplefin_error(conn, :quota_exceeded) do
    conn
    |> put_status(:too_many_requests)
    |> json(%{
      error:
        "MoneyTree already refreshed this connection recently. Try again after the next scheduled sync window."
    })
  end

  defp render_simplefin_error(conn, {:simplefin_errors, errors}) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{error: "SimpleFIN returned provider errors.", errors: Redaction.redact(errors)})
  end

  defp render_simplefin_error(conn, {:http_error, _status}) do
    conn |> put_status(:bad_gateway) |> json(%{error: "SimpleFIN request failed."})
  end

  defp render_simplefin_error(conn, _reason) do
    conn |> put_status(:bad_gateway) |> json(%{error: "SimpleFIN request failed."})
  end

  defp schedule_initial_sync(%Connection{} = connection) do
    synchronization =
      Application.get_env(:money_tree, :synchronization, MoneyTree.Synchronization)

    synchronization.schedule_initial_sync(connection)
  end

  defp schedule_incremental_sync(%Connection{} = connection) do
    synchronization =
      Application.get_env(:money_tree, :synchronization, MoneyTree.Synchronization)

    synchronization.schedule_incremental_sync(connection)
  end

  defp simplefin_client do
    Application.get_env(:money_tree, :simplefin_client, MoneyTree.SimpleFin.Client)
  end

  defp simplefin_config(key, default) do
    :money_tree
    |> Application.get_env(MoneyTree.SimpleFin, [])
    |> Keyword.get(key, default)
  end

  defp normalize_slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  defp put_simplefin_metadata(provider_metadata, updates) do
    provider_metadata = normalize_map(provider_metadata)
    current = provider_metadata |> Map.get("simplefin", %{}) |> normalize_map()
    Map.put(provider_metadata, "simplefin", Map.merge(current, updates))
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_value), do: %{}

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
end
