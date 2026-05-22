defmodule MoneyTreeWeb.LegacyBankConnectionController do
  use MoneyTreeWeb, :controller

  alias Ecto.Changeset
  alias MoneyTree.Institutions
  alias MoneyTree.Institutions.Connection

  @legacy_providers ~w(teller plaid)

  def index(%{assigns: %{current_user: current_user}} = conn, _params) do
    connections =
      current_user
      |> Institutions.list_connections_for_user(preload: [:institution, :accounts])
      |> Enum.filter(&(&1.provider in @legacy_providers))
      |> Enum.map(&serialize_connection/1)

    json(conn, %{data: %{connections: connections}})
  end

  def purge_credentials(%{assigns: %{current_user: current_user}} = conn, %{
        "connection_id" => connection_id
      })
      when is_binary(connection_id) do
    case Institutions.purge_legacy_credentials(current_user, connection_id) do
      {:ok, %Connection{} = connection} ->
        connection = Institutions.preload_defaults(connection)
        json(conn, %{data: %{connection: serialize_connection(connection)}})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "connection not found"})

      {:error, :not_legacy_provider} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "credentials can only be purged for Teller or Plaid connections"})

      {:error, %Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Changeset.traverse_errors(changeset, &translate_error/1)})
    end
  end

  def purge_credentials(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "connection_id is required"})
  end

  defp serialize_connection(%Connection{} = connection) do
    %{
      id: connection.id,
      provider: connection.provider,
      institution_name: connection.institution && connection.institution.name,
      account_count: length(connection.accounts || []),
      status: connection.metadata |> normalize_map() |> Map.get("status", "active"),
      credentials_present?: credentials_present?(connection),
      credentials_purged_at:
        connection.metadata |> normalize_map() |> Map.get("credentials_purged_at")
    }
  end

  defp credentials_present?(%Connection{} = connection) do
    Enum.any?([
      present?(connection.encrypted_credentials),
      present?(connection.webhook_secret),
      present?(connection.teller_enrollment_id),
      present?(connection.teller_user_id)
    ])
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_value), do: %{}

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
