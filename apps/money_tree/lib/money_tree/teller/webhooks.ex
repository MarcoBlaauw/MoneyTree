defmodule MoneyTree.Teller.Webhooks do
  @moduledoc """
  Utilities for recording Teller webhook metadata to guard against replay attacks.

  Processed webhook identifiers are stored on the connection metadata so repeated deliveries
  can be detected quickly without introducing a dedicated table. Entries are pruned as new
  events arrive to keep the metadata small.
  """

  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Repo

  @metadata_root "teller_webhook"
  @nonces_key "nonces"
  @default_retention 86_400

  @doc """
  Returns true when the nonce has already been recorded for the connection.
  """
  @spec nonce_processed?(Connection.t(), String.t()) :: boolean()
  def nonce_processed?(%Connection{} = connection, nonce) when is_binary(nonce) do
    connection
    |> fetch_webhook_metadata()
    |> Map.get(@nonces_key, %{})
    |> Map.has_key?(nonce)
  end

  @doc """
  Records webhook metadata on the connection, updating the nonce registry and audit fields.

  Options:

    * `:retention` – number of seconds to retain historical nonces (defaults to one day).
  """
  @spec record_event(Connection.t(), String.t(), DateTime.t(), map(), keyword()) ::
          {:ok, Connection.t()} | {:error, term()}
  def record_event(%Connection{} = connection, nonce, timestamp, payload, opts \\ [])
      when is_binary(nonce) and is_struct(timestamp, DateTime) and is_map(payload) do
    retention = Keyword.get(opts, :retention, @default_retention)

    metadata = connection.metadata || %{}
    webhook_metadata = fetch_webhook_metadata(connection)
    nonce_registry = Map.get(webhook_metadata, @nonces_key, %{})

    pruned_nonces = prune_nonces(nonce_registry, timestamp, retention)
    updated_nonces = Map.put(pruned_nonces, nonce, DateTime.to_iso8601(timestamp))

    updated_metadata =
      webhook_metadata
      |> Map.put(@nonces_key, updated_nonces)
      |> Map.put("last_event", Map.get(payload, :event) || Map.get(payload, "event"))
      |> Map.put("last_received_at", DateTime.to_iso8601(timestamp))

    new_metadata = Map.put(metadata, @metadata_root, updated_metadata)

    connection
    |> Connection.changeset(%{metadata: new_metadata})
    |> Repo.update()
  end

  defp prune_nonces(nonce_registry, _timestamp, retention) when retention <= 0, do: nonce_registry

  defp prune_nonces(nonce_registry, timestamp, retention) do
    nonce_registry
    |> Enum.filter(&nonce_within_retention?(&1, timestamp, retention))
    |> Enum.into(%{})
  end

  defp nonce_within_retention?({_nonce, recorded_at}, timestamp, retention) do
    case DateTime.from_iso8601(recorded_at) do
      {:ok, recorded, _} -> DateTime.diff(timestamp, recorded, :second) <= retention
      _ -> false
    end
  end

  defp fetch_webhook_metadata(%Connection{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, @metadata_root, %{})
  end

  defp fetch_webhook_metadata(_), do: %{}
end
