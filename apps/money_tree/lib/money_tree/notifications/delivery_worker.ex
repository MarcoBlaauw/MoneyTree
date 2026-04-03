defmodule MoneyTree.Notifications.DeliveryWorker do
  @moduledoc """
  Delivers durable notification events through configured adapters.
  """

  use Oban.Worker, queue: :mailers, max_attempts: 1

  alias MoneyTree.Notifications
  alias Oban.Job

  @impl Oban.Worker
  def perform(%Job{args: %{"event_id" => event_id}}) do
    case Notifications.deliver_event(event_id) do
      :ok -> :ok
      {:error, :event_not_found} -> :discard
      {:error, :already_resolved} -> :discard
      {:error, :not_due} -> :discard
      {:error, :suppressed} -> :discard
      {:error, :max_resends_exhausted} -> :discard
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Job{}), do: :discard
end
