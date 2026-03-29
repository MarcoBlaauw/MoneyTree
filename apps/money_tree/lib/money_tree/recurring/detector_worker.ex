defmodule MoneyTree.Recurring.DetectorWorker do
  @moduledoc """
  Runs recurring-series detection for a synced institution connection.
  """

  use Oban.Worker, queue: :reporting, max_attempts: 3

  alias MoneyTree.Recurring
  alias Oban.Job

  @impl Oban.Worker
  def perform(%Job{args: %{"connection_id" => connection_id}}) do
    case Recurring.detect_for_connection(connection_id) do
      {:ok, _summary} -> :ok
      {:error, :connection_not_found} -> :discard
    end
  end

  def perform(%Job{}), do: :discard
end
