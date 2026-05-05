defmodule MoneyTree.AI.CategorizationWorker do
  @moduledoc """
  Runs AI categorization suggestion generation for a queued suggestion run.
  """

  use Oban.Worker, queue: :reporting, max_attempts: 3

  alias MoneyTree.AI
  alias Oban.Job

  @impl Oban.Worker
  def perform(%Job{args: %{"run_id" => run_id}}) when is_binary(run_id) do
    case AI.process_categorization_run(run_id) do
      :ok -> :ok
      {:error, :not_found} -> :discard
      {:error, _reason} -> :ok
    end
  end

  def perform(%Job{}), do: :discard
end
