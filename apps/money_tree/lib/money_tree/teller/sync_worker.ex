defmodule MoneyTree.Teller.SyncWorker do
  @moduledoc """
  Oban worker responsible for orchestrating Teller synchronisation jobs.

  Jobs can target a specific connection or dispatch incremental syncs for all active
  connections when invoked with the `"mode" => "dispatch"` argument.
  """

  use Oban.Worker, queue: :default, max_attempts: 5

  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Repo
  alias MoneyTree.Synchronization
  alias MoneyTree.Teller.Synchronizer
  alias Oban.Job

  @max_snooze 300

  @impl Oban.Worker
  def perform(%Job{args: %{"mode" => "dispatch"} = args}) do
    schedule_opts = [schedule_in: Map.get(args, "schedule_in", 0)]
    Synchronization.dispatch_incremental_syncs(schedule_opts)
    :ok
  end

  def perform(%Job{args: %{"connection_id" => connection_id} = args, attempt: attempt}) do
    mode = Map.get(args, "mode", "incremental")
    telemetry_metadata = Map.get(args, "telemetry_metadata", %{}) |> Map.new()
    client = resolve_client(args)

    case Repo.get(Connection, connection_id) do
      nil ->
        :discard

      %Connection{} = connection ->
        opts =
          [mode: mode, telemetry_metadata: telemetry_metadata]
          |> maybe_put_client(client)

        case Synchronizer.sync(connection, opts) do
          {:ok, _result} ->
            :ok

          {:error, {:rate_limited, info}} ->
            snooze_for = snooze_duration(info, attempt)
            {:snooze, snooze_for}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def perform(%Job{}), do: :discard

  @impl Oban.Worker
  def backoff(%Job{attempt: attempt}) do
    base = :math.pow(2, attempt - 1) * 15
    trunc(min(base, @max_snooze))
  end

  defp maybe_put_client(opts, nil), do: opts
  defp maybe_put_client(opts, client), do: Keyword.put(opts, :client, client)

  defp resolve_client(%{"client" => client}) when is_binary(client) do
    case String.split(client, ".") do
      [] ->
        nil

      parts ->
        client_module = Module.concat(parts)

        if Code.ensure_loaded?(client_module) do
          client_module
        else
          nil
        end
    end
  end

  defp resolve_client(_args), do: nil

  defp snooze_duration(info, attempt) when is_map(info) do
    retry_after = Map.get(info, :retry_after) || Map.get(info, "retry_after")
    snooze_duration(retry_after, attempt)
  end

  defp snooze_duration(nil, attempt), do: backoff_value(attempt)

  defp snooze_duration(seconds, attempt) when is_integer(seconds) and seconds > 0 do
    seconds
    |> min(@max_snooze)
    |> max(backoff_value(attempt))
  end

  defp snooze_duration(seconds, attempt) when is_binary(seconds) do
    case Integer.parse(String.trim(seconds)) do
      {value, _rest} -> snooze_duration(value, attempt)
      :error -> backoff_value(attempt)
    end
  end

  defp snooze_duration(_other, attempt), do: backoff_value(attempt)

  defp backoff_value(attempt) do
    backoff(%Job{attempt: attempt})
  end
end
