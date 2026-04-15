defmodule MoneyTreeWeb.PlaidController do
  use MoneyTreeWeb, :controller

  @moduledoc """
  Issues Plaid Link tokens and exchanges public tokens into persisted connections.
  """

  alias Ecto.Association.NotLoaded
  alias Ecto.Changeset
  alias MoneyTree.Institutions
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Institutions.Institution
  alias MoneyTree.Repo
  require Logger

  def link_token(conn, params) do
    user = conn.assigns.current_user

    with {:ok, payload} <-
           plaid_client().create_link_token(build_link_token_request(user, params)) do
      json(conn, %{data: payload})
    else
      {:error, error} ->
        render_plaid_error(conn, error)
    end
  end

  def exchange(conn, %{"public_token" => public_token} = params) do
    user = conn.assigns.current_user

    with {:ok, institution_id} <- fetch_or_create_institution_id(params),
         {:ok, exchange_payload} <- plaid_client().exchange_public_token(public_token),
         {:ok, connection} <- persist_connection(user, institution_id, exchange_payload, params),
         :ok <- schedule_initial_sync(connection) do
      connection = Repo.preload(connection, :institution)
      json(conn, %{data: serialize_connection(connection)})
    else
      {:error, :missing_institution} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "institution_id or institution_name is required"})

      {:error, :institution_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "institution not found"})

      {:error, %Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Changeset.traverse_errors(changeset, &translate_error/1)})

      {:error, error} ->
        render_plaid_error(conn, error)
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

  defp build_link_token_request(user, params) do
    %{
      "user" => %{"client_user_id" => to_string(user.id)},
      "products" => normalize_string_list(params["products"] || params[:products]),
      "country_codes" => normalize_string_list(params["country_codes"] || params[:country_codes]),
      "language" => fetch_string(params, "language", "en"),
      "client_name" => fetch_string(params, "client_name", "MoneyTree"),
      "redirect_uri" => fetch_optional_string(params, "redirect_uri")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
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

  defp fetch_or_create_institution_id(params) do
    case Map.get(params, "institution_id") || Map.get(params, :institution_id) do
      nil ->
        ensure_institution_id_by_name(
          Map.get(params, "institution_name") || Map.get(params, :institution_name)
        )

      id ->
        {:ok, id}
    end
  end

  defp ensure_institution_id_by_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    if trimmed == "" do
      {:error, :missing_institution}
    else
      slug = normalize_slug(trimmed)
      external_id = "plaid:#{slug}"

      case Repo.get_by(Institution, external_id: external_id) do
        %Institution{id: id} ->
          {:ok, id}

        nil ->
          attrs = %{
            name: trimmed,
            slug: slug,
            external_id: external_id,
            metadata: %{"provider" => "plaid"}
          }

          %Institution{}
          |> Institution.changeset(attrs)
          |> Repo.insert()
          |> case do
            {:ok, institution} -> {:ok, institution.id}
            {:error, %Changeset{} = changeset} -> {:error, changeset}
          end
      end
    end
  end

  defp ensure_institution_id_by_name(_), do: {:error, :missing_institution}

  defp normalize_slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
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

  defp render_plaid_error(conn, %{type: :http, status: status} = error) do
    {http_status, message} = translate_http_error(status, error)
    conn |> put_status(http_status) |> json(%{error: message})
  end

  defp render_plaid_error(conn, %{type: :transport} = error) do
    Logger.warning("[plaid] transport error during request: #{inspect(error)}")

    conn
    |> put_status(:bad_gateway)
    |> json(%{error: transport_error_message(error)})
  end

  defp render_plaid_error(conn, %{type: :validation, details: details}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: get_error_message(details) || "plaid request invalid"})
  end

  defp render_plaid_error(conn, %{type: :unexpected}) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{error: "unexpected plaid error"})
  end

  defp render_plaid_error(conn, _error) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{error: "plaid request failed"})
  end

  defp translate_http_error(status, error) when status in 400..499 do
    message =
      error
      |> Map.get(:details, %{})
      |> get_error_message()
      |> default_error_message("plaid request invalid")

    {status, message}
  end

  defp translate_http_error(_status, error) do
    message =
      error
      |> Map.get(:details, %{})
      |> get_error_message()
      |> default_error_message("plaid upstream failure")

    {:bad_gateway, message}
  end

  defp get_error_message(details) when is_map(details) do
    details["message"] || details[:message] || details["error"] || details[:error]
  end

  defp get_error_message(_details), do: nil

  defp default_error_message(nil, fallback), do: fallback
  defp default_error_message(message, _fallback), do: message

  defp transport_error_message(error) do
    base = "plaid service unavailable"

    if Application.get_env(:money_tree, :dev_routes) == true do
      case Map.get(error, :reason) do
        nil -> base
        reason -> "#{base} (#{inspect(reason)})"
      end
    else
      base
    end
  end

  defp serialize_connection(%Connection{} = connection) do
    metadata = connection.metadata || %{}

    %{
      connection_id: connection.id,
      institution_id: connection.institution_id,
      institution_name:
        metadata["institution_name"] || metadata[:institution_name] ||
          loaded_institution_name(connection),
      metadata: metadata,
      provider: connection.provider
    }
  end

  defp loaded_institution_name(%Connection{institution: %NotLoaded{}}), do: nil
  defp loaded_institution_name(%Connection{institution: nil}), do: nil
  defp loaded_institution_name(%Connection{institution: institution}), do: institution.name

  defp normalize_string_list(nil), do: nil

  defp normalize_string_list(values) when is_binary(values) do
    values
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      list -> list
    end
  end

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(fn
      value when is_binary(value) -> String.trim(value)
      value when is_atom(value) -> value |> Atom.to_string() |> String.trim()
      value -> to_string(value)
    end)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      list -> list
    end
  end

  defp normalize_string_list(_), do: nil

  defp fetch_string(params, key, default) do
    case fetch_optional_string(params, key) do
      nil -> default
      value -> value
    end
  end

  defp fetch_optional_string(params, key) do
    value =
      case key do
        "language" -> Map.get(params, "language") || Map.get(params, :language)
        "client_name" -> Map.get(params, "client_name") || Map.get(params, :client_name)
        "redirect_uri" -> Map.get(params, "redirect_uri") || Map.get(params, :redirect_uri)
        _ -> Map.get(params, key)
      end

    case value do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end
end
