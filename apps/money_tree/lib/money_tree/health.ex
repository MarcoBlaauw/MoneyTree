defmodule MoneyTree.Health do
  @moduledoc """
  Helpers for reporting application health and operational metrics.
  """

  import Ecto.Query, only: [from: 2, select: 3, group_by: 3, where: 3]

  alias Ecto.Adapters.SQL
  alias MoneyTree.Repo
  alias Oban.Job

  @type check_status :: :ok | :degraded

  @doc """
  Returns a health summary covering database connectivity and Oban queue status.
  """
  @spec summary() :: map()
  def summary do
    database = database_check()
    queues = queue_checks()

    status =
      if database[:status] == "ok" and Enum.all?(queues, &healthy_queue?/1) do
        "ok"
      else
        "degraded"
      end

    %{
      status: status,
      checks: %{
        database: database,
        oban: queues
      },
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Collects lightweight metrics for database access and Oban queues.
  """
  @spec metrics() :: map()
  def metrics do
    %{
      database: database_check(),
      queues: queue_metrics()
    }
  end

  defp database_check do
    started_at = System.monotonic_time()

    case SQL.query(Repo, "SELECT 1", []) do
      {:ok, _result} ->
        duration =
          System.monotonic_time()
          |> Kernel.-(started_at)
          |> System.convert_time_unit(:native, :microsecond)

        %{
          status: "ok",
          latency_usec: duration
        }

      {:error, reason} ->
        %{
          status: "error",
          error: exception_message(reason)
        }
    end
  rescue
    exception ->
      %{
        status: "error",
        error: exception_message(exception)
      }
  end

  defp queue_checks do
    oban_config = Application.get_env(:money_tree, Oban, [])
    queue_names = queue_names(oban_config)

    cond do
      Keyword.get(oban_config, :testing) == :inline ->
        Enum.map(queue_names, fn queue ->
          %{queue: queue, status: "testing"}
        end)

      queue_names == [] ->
        []

      true ->
        Enum.map(queue_names, &check_queue/1)
    end
  end

  defp healthy_queue?(%{status: status}) do
    status in ["online", "testing", "idle"]
  end

  defp healthy_queue?(_), do: false

  defp check_queue(queue) do
    case oban_check(queue) do
      {:ok, state} ->
        %{
          queue: queue,
          status: queue_status(state),
          limit: Map.get(state, :limit),
          running: Map.get(state, :running),
          paused: Map.get(state, :paused, false)
        }

      {:error, :not_found} ->
        %{queue: queue, status: "unavailable"}

      {:error, reason} ->
        %{queue: queue, status: "error", error: inspect(reason)}
    end
  rescue
    exception ->
      %{queue: queue, status: "error", error: exception_message(exception)}
  end

  defp queue_metrics do
    oban_config = Application.get_env(:money_tree, Oban, [])
    queue_names = queue_names(oban_config)

    Enum.map(queue_names, fn queue ->
      counts =
        Job
        |> where([j], j.queue == ^queue)
        |> group_by([j], j.state)
        |> select([j], {j.state, count(j.id)})
        |> Repo.all()
        |> Enum.into(%{}, fn {state, count} -> {state, count} end)
        |> transform_state_keys()

      %{
        queue: queue,
        counts: counts
      }
    end)
  end

  defp queue_names(config) do
    config
    |> Keyword.get(:queues, [])
    |> case do
      false ->
        []

      nil ->
        []

      queues when is_list(queues) ->
        queues
        |> Enum.map(fn
          {queue, _limit} -> queue
          queue -> queue
        end)
        |> Enum.map(&to_string/1)
        |> Enum.uniq()
    end
  end

  defp oban_check(queue) do
    if function_exported?(Oban, :check_queue, 1) do
      Oban.check_queue(queue: to_existing_atom(queue))
    else
      {:error, :unsupported}
    end
  end

  defp to_existing_atom(queue) do
    String.to_existing_atom(queue)
  rescue
    ArgumentError -> String.to_atom(queue)
  end

  defp queue_status(%{paused: true}), do: "paused"
  defp queue_status(_state), do: "online"

  defp transform_state_keys(counts) do
    counts
    |> Enum.map(fn {state, count} -> {to_string(state), count} end)
    |> Enum.into(%{})
  end

  defp exception_message(%{message: message}), do: message
  defp exception_message(%{postgres: %{message: message}}), do: message
  defp exception_message(%{reason: reason}), do: inspect(reason)
  defp exception_message(message) when is_binary(message), do: message
  defp exception_message(other), do: inspect(other)
end
