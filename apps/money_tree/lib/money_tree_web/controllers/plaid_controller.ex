defmodule MoneyTreeWeb.PlaidController do
  use MoneyTreeWeb, :controller

  @moduledoc """
  Issues Plaid Link tokens and exchanges public tokens into persisted connections.
  """

  alias Ecto.Changeset
  alias Ecto.UUID
  alias MoneyTree.Institutions
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Repo

  def link_token(conn, params) do
    payload = build_payload(params)
    json(conn, %{data: payload})
  end

  def exchange(conn, %{"public_token" => public_token} = params) do
    user = conn.assigns.current_user

    with {:ok, institution_id} <- fetch_institution_id(params),
         {:ok, exchange_payload} <- plaid_client().exchange_public_token(public_token),
         {:ok, connection} <- persist_connection(user, institution_id, exchange_payload, params),
         :ok <- schedule_initial_sync(connection) do
      connection = Repo.preload(connection, :institution)
      json(conn, %{data: serialize_connection(connection)})
    else
      {:error, :missing_institution} ->
        conn |> put_status(:bad_request) |> json(%{error: "institution_id is required"})

      {:error, :institution_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "institution not found"})

      {:error, %Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Changeset.traverse_errors(changeset, &translate_error/1)})

      {:error, _error} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "plaid request failed"})
    end
  end

  def exchange(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "public_token is required"})
  end

  defp persist_connection(user, institution_id, exchange_payload, params) do
    metadata = build_metadata(params)

    attrs = %{
      encrypted_credentials: Jason.encode!(normalize_payload(exchange_payload)),
      provider: "plaid",
      provider_metadata: normalize_payload(exchange_payload),
      metadata: metadata
    }

    case Institutions.get_connection_for_institution(user, institution_id, provider: "plaid") do
      {:ok, %Connection{} = connection} -> Institutions.update_connection(user, connection, attrs)
      {:error, :not_found} -> Institutions.create_connection(user, institution_id, attrs)
    end
  end

  defp build_payload(params) do
    expiration =
      DateTime.utc_now()
      |> DateTime.add(15 * 60, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    %{
      link_token: generate_token("plaid-link"),
      expiration: expiration,
      request_id: UUID.generate(),
      metadata: sanitize_metadata(params)
    }
  end

  defp generate_token(prefix) do
    raw = :crypto.strong_rand_bytes(24)
    prefix <> "-" <> Base.url_encode64(raw, padding: false)
  end

  defp sanitize_metadata(params) do
    params
    |> Map.take(["products", "client_name", "language"])
    |> Enum.into(%{})
  end

  defp build_metadata(params) do
    %{"status" => "active", "provider" => "plaid"}
    |> maybe_put("institution_name", params["institution_name"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_payload(payload) when is_map(payload) do
    Enum.into(payload, %{}, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp normalize_payload(_), do: %{}

  defp fetch_institution_id(params) do
    case Map.get(params, "institution_id") || Map.get(params, :institution_id) do
      nil -> {:error, :missing_institution}
      id -> {:ok, id}
    end
  end

  defp plaid_client do
    Application.get_env(:money_tree, :plaid_client, MoneyTree.Plaid.Client)
  end

  defp schedule_initial_sync(%Connection{} = connection) do
    sync_module = Application.get_env(:money_tree, :synchronization, MoneyTree.Synchronization)
    sync_module.schedule_initial_sync(connection)
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  defp serialize_connection(%Connection{} = connection) do
    metadata = connection.metadata || %{}

    %{
      connection_id: connection.id,
      institution_id: connection.institution_id,
      institution_name: metadata["institution_name"],
      metadata: metadata,
      provider: connection.provider
    }
  end
end
