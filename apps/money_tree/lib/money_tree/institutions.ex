defmodule MoneyTree.Institutions do
  @moduledoc """
  Context responsible for managing financial institutions, user connections, and related
  authorization helpers.

  The functions in this module enforce ownership semantics, returning data only when the
  provided user (or user identifier) is authorized to access a connection. Updates that must
  remain consistent leverage `Ecto.Multi` and database transactions, mirroring the style used
  in other contexts such as `MoneyTree.Accounts`.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ecto.Multi
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Institutions.Institution
  alias MoneyTree.Repo
  alias MoneyTree.Users.User

  @type user_ref :: User.t() | binary()

  @doc """
  Creates a new institution connection for the given user.

  An institution can be supplied as a struct or identifier. Additional attributes are merged
  with the required foreign keys before being persisted.
  """
  @spec create_connection(user_ref(), Institution.t() | binary(), map()) ::
          {:ok, Connection.t()} | {:error, Changeset.t() | :institution_not_found}
  def create_connection(user, institution, attrs \\ %{}) when is_map(attrs) do
    user_id = normalize_user_id(user)
    institution_id = normalize_institution_id(institution)

    with {:ok, _institution} <- ensure_institution_exists(institution_id) do
      params =
        attrs
        |> Map.new()
        |> Map.put(:user_id, user_id)
        |> Map.put(:institution_id, institution_id)
        |> maybe_put_default_webhook_secret()

      %Connection{}
      |> Connection.changeset(params)
      |> Repo.insert()
    end
  end

  @doc """
  Updates Teller enrollment and user identifiers for a connection owned by the user.
  """
  @spec update_connection_tokens(user_ref(), map()) ::
          {:ok, Connection.t()} | {:error, :not_found | Changeset.t()}
  def update_connection_tokens(user, attrs) when is_map(attrs) do
    with {:ok, connection} <-
           fetch_owned_connection(user, fetch_identifier!(attrs, :connection_id)) do
      updates =
        [:teller_enrollment_id, :teller_user_id]
        |> Enum.reduce(%{}, fn key, acc ->
          value = Map.get(attrs, key) || Map.get(attrs, to_string(key))

          if is_nil(value) do
            acc
          else
            Map.put(acc, key, value)
          end
        end)

      case updates do
        %{} ->
          {:ok, connection}

        _ ->
          connection
          |> Connection.changeset(updates)
          |> Repo.update()
      end
    end
  end

  @doc """
  Updates a connection owned by the given user with the provided attributes.
  """
  @spec update_connection(user_ref(), Connection.t() | binary(), map()) ::
          {:ok, Connection.t()} | {:error, :not_found | Changeset.t()}
  def update_connection(user, %Connection{} = connection, attrs) when is_map(attrs) do
    if connection.user_id == normalize_user_id(user) do
      connection
      |> Connection.changeset(attrs)
      |> Repo.update()
    else
      {:error, :not_found}
    end
  end

  def update_connection(user, connection_id, attrs)
      when is_binary(connection_id) and is_map(attrs) do
    with {:ok, connection} <- fetch_owned_connection(user, connection_id) do
      update_connection(user, connection, attrs)
    end
  end

  @doc """
  Rotates the webhook secret for the given connection, returning the updated record and the
  newly generated secret.
  """
  @spec rotate_webhook_secret(user_ref(), binary()) ::
          {:ok, Connection.t(), String.t()} | {:error, :not_found | Changeset.t()}
  def rotate_webhook_secret(user, connection_id) when is_binary(connection_id) do
    secret = generate_webhook_secret()

    Multi.new()
    |> Multi.run(:connection, fn _repo, _changes ->
      fetch_owned_connection(user, connection_id)
    end)
    |> Multi.update(:updated_connection, fn %{connection: connection} ->
      Connection.changeset(connection, %{webhook_secret: secret})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{updated_connection: connection}} ->
        {:ok, connection, secret}

      {:error, :connection, :not_found, _changes_so_far} ->
        {:error, :not_found}

      {:error, :updated_connection, %Changeset{} = changeset, _changes_so_far} ->
        {:error, changeset}
    end
  end

  @doc """
  Updates the sync cursor for a connection, recording when Teller last synced the account.
  """
  @spec mark_sync_state(user_ref(), map()) ::
          {:ok, Connection.t()} | {:error, :not_found | Changeset.t()}
  def mark_sync_state(user, attrs) when is_map(attrs) do
    connection_id = fetch_identifier!(attrs, :connection_id)
    cursor = Map.get(attrs, :cursor) || Map.get(attrs, "cursor")
    updated_at = Map.get(attrs, :synced_at) || Map.get(attrs, "synced_at") || DateTime.utc_now()

    with {:ok, connection} <- fetch_owned_connection(user, connection_id) do
      connection
      |> Connection.changeset(%{sync_cursor: cursor, sync_cursor_updated_at: updated_at})
      |> Repo.update()
    end
  end

  @doc """
  Marks a connection as revoked, storing the revocation timestamp and optional reason.
  """
  @spec mark_connection_revoked(user_ref(), binary(), keyword()) ::
          {:ok, Connection.t()} | {:error, :not_found | Changeset.t()}
  def mark_connection_revoked(user, connection_id, opts \\ []) when is_binary(connection_id) do
    reason = Keyword.get(opts, :reason)
    timestamp = Keyword.get(opts, :revoked_at, DateTime.utc_now())

    update_connection_metadata(user, connection_id, fn metadata ->
      metadata
      |> Map.put("status", "revoked")
      |> Map.put("revoked_at", DateTime.to_iso8601(timestamp))
      |> maybe_put_optional("revocation_reason", reason)
    end)
  end

  @doc """
  Clears the revoked status for a connection, restoring access when Teller confirms it.
  """
  @spec mark_connection_active(user_ref(), binary()) ::
          {:ok, Connection.t()} | {:error, :not_found | Changeset.t()}
  def mark_connection_active(user, connection_id) when is_binary(connection_id) do
    update_connection_metadata(user, connection_id, fn metadata ->
      metadata
      |> Map.delete("revocation_reason")
      |> Map.delete("revoked_at")
      |> Map.put("status", "active")
    end)
  end

  @doc """
  Retrieves an active connection for the given user by id, optionally preloading associations.
  """
  @spec get_active_connection_for_user(user_ref(), binary(), keyword()) ::
          {:ok, Connection.t()} | {:error, :not_found | :revoked}
  def get_active_connection_for_user(user, connection_id, opts \\ [])
      when is_binary(connection_id) do
    with {:ok, connection} <- fetch_owned_connection(user, connection_id, opts) do
      enforce_active(connection)
    end
  end

  @doc """
  Retrieves an active connection for a user by institution id.
  """
  @spec get_active_connection_for_institution(user_ref(), binary(), keyword()) ::
          {:ok, Connection.t()} | {:error, :not_found | :revoked}
  def get_active_connection_for_institution(user, institution_id, opts \\ [])
      when is_binary(institution_id) do
    query =
      from c in Connection,
        where: c.user_id == ^normalize_user_id(user) and c.institution_id == ^institution_id

    query
    |> apply_preloads(opts)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      connection -> enforce_active(connection)
    end
  end

  @doc """
  Retrieves a connection for the given user by institution id, regardless of status.
  """
  @spec get_connection_for_institution(user_ref(), binary(), keyword()) ::
          {:ok, Connection.t()} | {:error, :not_found}
  def get_connection_for_institution(user, institution_id, opts \\ [])
      when is_binary(institution_id) do
    query =
      from c in Connection,
        where: c.user_id == ^normalize_user_id(user) and c.institution_id == ^institution_id

    query
    |> apply_preloads(opts)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      connection -> {:ok, connection}
    end
  end

  @doc """
  Finds an active connection using the webhook secret reference (used by Teller webhooks).
  """
  @spec get_active_connection_by_webhook(String.t(), keyword()) ::
          {:ok, Connection.t()} | {:error, :not_found | :revoked}
  def get_active_connection_by_webhook(webhook_secret, opts \\ [])
      when is_binary(webhook_secret) do
    query =
      from c in Connection,
        where: c.webhook_secret == ^webhook_secret

    query
    |> apply_preloads(opts)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      connection -> enforce_active(connection)
    end
  end

  @doc """
  Lists all active connections for a user, optionally scoped to an institution.
  """
  @spec list_active_connections(user_ref(), keyword()) :: [Connection.t()]
  def list_active_connections(user, opts \\ []) do
    base_query =
      from c in Connection,
        where: c.user_id == ^normalize_user_id(user)

    query =
      case Keyword.get(opts, :institution_id) do
        nil ->
          base_query

        institution_id when is_binary(institution_id) ->
          from c in base_query, where: c.institution_id == ^institution_id
      end

    query
    |> apply_preloads(opts)
    |> Repo.all()
    |> Enum.reject(&revoked?/1)
  end

  @doc """
  Preloads accounts and institutions for the provided connection or collection of connections.
  """
  @spec preload_defaults(Connection.t() | [Connection.t()]) :: Connection.t() | [Connection.t()]
  def preload_defaults(connection_or_connections) do
    Repo.preload(connection_or_connections, [
      :institution,
      accounts: from(a in Account, order_by: a.name)
    ])
  end

  defp ensure_institution_exists(nil), do: {:error, :institution_not_found}

  defp ensure_institution_exists(institution_id) do
    case Repo.get(Institution, institution_id) do
      nil -> {:error, :institution_not_found}
      %Institution{} = institution -> {:ok, institution}
    end
  end

  defp update_connection_metadata(user, connection_id, fun) do
    Multi.new()
    |> Multi.run(:connection, fn _repo, _changes ->
      fetch_owned_connection(user, connection_id)
    end)
    |> Multi.update(:updated_connection, fn %{connection: connection} ->
      metadata = connection.metadata || %{}

      Connection.changeset(connection, %{metadata: fun.(metadata)})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{updated_connection: connection}} ->
        {:ok, connection}

      {:error, :connection, :not_found, _changes_so_far} ->
        {:error, :not_found}

      {:error, :updated_connection, %Changeset{} = changeset, _changes_so_far} ->
        {:error, changeset}
    end
  end

  defp fetch_owned_connection(user, connection_id, opts \\ []) when is_binary(connection_id) do
    preload = Keyword.get(opts, :preload, [])

    query =
      from c in Connection,
        where: c.id == ^connection_id and c.user_id == ^normalize_user_id(user),
        preload: ^preload

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %Connection{} = connection -> {:ok, connection}
    end
  end

  defp enforce_active(%Connection{} = connection) do
    if revoked?(connection) do
      {:error, :revoked}
    else
      {:ok, connection}
    end
  end

  defp revoked?(%Connection{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "status") == "revoked" || Map.has_key?(metadata, "revoked_at")
  end

  defp revoked?(_connection), do: false

  defp apply_preloads(query, opts) do
    preloads = Keyword.get(opts, :preload, [])

    case preloads do
      [] -> query
      _ -> from c in query, preload: ^preloads
    end
  end

  defp normalize_user_id(%User{id: id}) when is_binary(id), do: id
  defp normalize_user_id(id) when is_binary(id), do: id

  defp normalize_institution_id(%Institution{id: id}) when is_binary(id), do: id
  defp normalize_institution_id(id) when is_binary(id), do: id
  defp normalize_institution_id(_), do: nil

  defp fetch_identifier!(attrs, key) do
    Map.get(attrs, key) ||
      Map.get(attrs, to_string(key)) ||
      raise ArgumentError, "expected #{inspect(key)} to be present in attrs"
  end

  defp maybe_put_default_webhook_secret(attrs) do
    case Map.get(attrs, :webhook_secret) || Map.get(attrs, "webhook_secret") do
      nil -> Map.put(attrs, :webhook_secret, generate_webhook_secret())
      _ -> attrs
    end
  end

  defp generate_webhook_secret do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp maybe_put_optional(metadata, _key, nil), do: metadata

  defp maybe_put_optional(metadata, key, value) do
    Map.put(metadata, key, value)
  end
end
