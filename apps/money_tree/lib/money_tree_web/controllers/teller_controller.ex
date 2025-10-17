defmodule MoneyTreeWeb.TellerController do
  use MoneyTreeWeb, :controller

  alias Ecto.Association.NotLoaded
  alias Ecto.Changeset
  alias MoneyTree.Institutions
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Repo
  alias MoneyTreeWeb.RateLimiter

  @connect_token_limit 5
  @connect_token_period_seconds 60

  def connect_token(conn, params) do
    user = conn.assigns.current_user
    bucket = {:teller_connect_token, user.id, maybe_client_ip(conn)}

    with :ok <- RateLimiter.check(bucket, @connect_token_limit, @connect_token_period_seconds),
         {:ok, payload} <- teller_client().create_connect_token(params) do
      json(conn, %{data: payload})
    else
      {:error, :rate_limited} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "rate limit exceeded"})

      {:error, error} ->
        render_teller_error(conn, error)
    end
  end

  def exchange(conn, %{"public_token" => public_token} = params) do
    user = conn.assigns.current_user

    with {:ok, institution_id} <- fetch_institution_id(params),
         {:ok, exchange_payload} <- teller_client().exchange_public_token(public_token),
         {:ok, connection} <- persist_connection(user, institution_id, exchange_payload, params),
         :ok <- schedule_initial_sync(connection) do
      connection = Repo.preload(connection, :institution)

      json(conn, %{data: serialize_connection(connection)})
    else
      {:error, :missing_institution} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "institution_id is required"})

      {:error, :institution_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "institution not found"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "connection not found"})

      {:error, %Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Changeset.traverse_errors(changeset, &translate_error/1)})

      {:error, error} ->
        render_teller_error(conn, error)
    end
  end

  def exchange(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "public_token is required"})
  end

  def revoke(conn, %{"connection_id" => connection_id}) do
    user = conn.assigns.current_user

    case Institutions.mark_connection_revoked(user, connection_id, reason: "user_initiated") do
      {:ok, connection} ->
        json(conn, %{data: serialize_connection(connection)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "connection not found"})

      {:error, %Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Changeset.traverse_errors(changeset, &translate_error/1)})
    end
  end

  def revoke(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "connection_id is required"})
  end

  defp persist_connection(user, institution_id, exchange_payload, params) do
    metadata = build_metadata(params)

    attrs =
      build_connection_attrs(exchange_payload)
      |> Map.put(:metadata, metadata)

    case Institutions.get_connection_for_institution(user, institution_id) do
      {:ok, %Connection{} = connection} ->
        merged_metadata = merge_metadata(connection.metadata, metadata)

        updated_attrs = Map.put(attrs, :metadata, merged_metadata)

        Institutions.update_connection(user, connection, updated_attrs)

      {:error, :not_found} ->
        Institutions.create_connection(user, institution_id, attrs)
    end
  end

  defp build_connection_attrs(exchange_payload) do
    payload = normalize_payload(exchange_payload)

    %{
      encrypted_credentials: Jason.encode!(payload),
      teller_enrollment_id: Map.get(payload, "enrollment_id"),
      teller_user_id: Map.get(payload, "user_id")
    }
  end

  defp merge_metadata(existing, new_metadata) when is_map(existing) do
    existing
    |> Map.drop(["revocation_reason", "revoked_at"])
    |> Map.merge(new_metadata)
  end

  defp merge_metadata(_existing, new_metadata), do: new_metadata

  defp build_metadata(params) do
    %{}
    |> Map.put("status", "active")
    |> maybe_put("institution_name", params["institution_name"])
    |> Map.put("provider", "teller")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_payload(payload) when is_map(payload) do
    payload
    |> Enum.reduce(%{}, fn
      {key, value}, acc when is_atom(key) -> Map.put(acc, Atom.to_string(key), value)
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp normalize_payload(_payload), do: %{}

  defp fetch_institution_id(params) do
    case Map.get(params, "institution_id") || Map.get(params, :institution_id) do
      nil -> {:error, :missing_institution}
      id -> {:ok, id}
    end
  end

  defp teller_client do
    Application.get_env(:money_tree, :teller_client, MoneyTree.Teller.Client)
  end

  defp schedule_initial_sync(%Connection{} = connection) do
    sync_module = Application.get_env(:money_tree, :synchronization, MoneyTree.Synchronization)
    sync_module.schedule_initial_sync(connection)
  end

  defp render_teller_error(conn, %{type: :http, status: status} = error) do
    {http_status, message} = translate_http_error(status, error)

    conn
    |> put_status(http_status)
    |> json(%{error: message})
  end

  defp render_teller_error(conn, %{type: :transport}) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{error: "teller service unavailable"})
  end

  defp render_teller_error(conn, %{type: :unexpected}) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{error: "unexpected teller error"})
  end

  defp render_teller_error(conn, _error) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{error: "teller request failed"})
  end

  defp translate_http_error(status, error) when status in 400..499 do
    message =
      error
      |> Map.get(:details, %{})
      |> get_error_message()
      |> default_error_message("teller request invalid")

    {status, message}
  end

  defp translate_http_error(_status, error) do
    message =
      error
      |> Map.get(:details, %{})
      |> get_error_message()
      |> default_error_message("teller upstream failure")

    {:bad_gateway, message}
  end

  defp get_error_message(details) when is_map(details) do
    details["message"] || details[:message] || details["error"] || details[:error]
  end

  defp get_error_message(_details), do: nil

  defp default_error_message(nil, fallback), do: fallback
  defp default_error_message(message, _fallback), do: message

  defp maybe_client_ip(%Plug.Conn{remote_ip: nil}), do: nil

  defp maybe_client_ip(%Plug.Conn{remote_ip: tuple}) do
    tuple
    |> :inet.ntoa()
    |> to_string()
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
      institution_name:
        metadata["institution_name"] || metadata[:institution_name] ||
          loaded_institution_name(connection),
      metadata: metadata
    }
  end

  defp loaded_institution_name(%Connection{institution: %NotLoaded{}}), do: nil
  defp loaded_institution_name(%Connection{institution: nil}), do: nil
  defp loaded_institution_name(%Connection{institution: institution}), do: institution.name
end
