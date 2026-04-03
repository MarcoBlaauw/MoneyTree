defmodule MoneyTree.Obligations.CheckWorker do
  @moduledoc """
  Daily worker that evaluates active payment obligations and emits durable events.
  """

  use Oban.Worker, queue: :reporting, max_attempts: 3

  alias MoneyTree.Obligations
  alias Oban.Job

  @impl Oban.Worker
  def perform(%Job{args: args}) when is_map(args) do
    date =
      case Map.get(args, "date") do
        nil -> Date.utc_today()
        value -> Date.from_iso8601!(value)
      end

    Obligations.check_all(date)
  end
end
