defmodule MoneyTree.Synchronization do
  @moduledoc """
  Coordinates synchronization workflows triggered by Teller integrations.

  This module acts as an integration point so controllers and other contexts can
  schedule synchronization jobs without needing to know the specific worker
  implementation. Subsequent tasks can expand the underlying behaviour without
  changing the calling code.
  """

  alias MoneyTree.Institutions
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Teller.SyncWorker
  alias Oban

  @default_unique_period 60

  @spec schedule_initial_sync(Connection.t()) :: :ok | {:error, term()}
  def schedule_initial_sync(%Connection{} = connection) do
    enqueue_connection_sync(connection, "initial", unique_period: 300)
  end

  @spec schedule_incremental_sync(Connection.t(), keyword()) :: :ok | {:error, term()}
  def schedule_incremental_sync(%Connection{} = connection, opts \\ []) do
    enqueue_connection_sync(connection, "incremental", opts)
  end

  @spec dispatch_incremental_syncs(keyword()) :: :ok | {:error, term()}
  def dispatch_incremental_syncs(opts \\ []) do
    schedule_in = Keyword.get(opts, :schedule_in, 0)
    unique_period = Keyword.get(opts, :unique_period, @default_unique_period)

    Institutions.list_connections_for_sync()
    |> Enum.reduce_while(:ok, fn connection, acc ->
      case schedule_incremental_sync(connection,
             schedule_in: schedule_in,
             unique_period: unique_period
           ) do
        :ok -> {:cont, acc}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp enqueue_connection_sync(%Connection{} = connection, mode, opts) do
    args =
      %{
        "connection_id" => connection.id,
        "mode" => mode,
        "telemetry_metadata" => telemetry_metadata(connection, mode, opts)
      }

    job_opts =
      []
      |> maybe_put(:schedule_in, Keyword.get(opts, :schedule_in))
      |> Keyword.put(:unique,
        keys: [:connection_id, :mode],
        period: Keyword.get(opts, :unique_period, @default_unique_period)
      )

    args
    |> SyncWorker.new(job_opts)
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp telemetry_metadata(connection, mode, opts) do
    extra_metadata =
      opts
      |> Keyword.get(:telemetry_metadata, %{})
      |> Map.new()
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.into(%{}, fn {key, value} -> {normalize_key(key), value} end)

    base_metadata = %{
      "mode" => mode,
      "user_id" => connection.user_id,
      "institution_id" => connection.institution_id
    }

    Map.merge(base_metadata, extra_metadata)
  end

  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)
end
