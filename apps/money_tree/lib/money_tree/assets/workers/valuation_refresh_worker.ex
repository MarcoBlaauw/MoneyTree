defmodule MoneyTree.Assets.Workers.ValuationRefreshWorker do
  @moduledoc """
  Dispatches baseline and weekly MarketCheck vehicle valuations.

  The dispatcher may run daily, but persisted cooldown and quota reservations
  ensure each vehicle makes at most one outgoing request per seven-day window.
  """

  use Oban.Worker,
    queue: :market_data,
    max_attempts: 1,
    unique: [period: 3_600, fields: [:worker, :args]]

  alias MoneyTree.Assets
  alias MoneyTree.Assets.ProviderRegistry
  alias MoneyTree.Repo
  alias Oban.Job

  @impl Oban.Worker
  def perform(%Job{args: %{"mode" => "dispatch", "provider" => provider}}) do
    if ProviderRegistry.configured?(provider) do
      Assets.list_provider_ready_vehicles()
      |> Enum.filter(&Assets.vehicle_valuation_due?(&1, provider))
      |> Enum.each(fn asset ->
        %{"asset_id" => asset.id, "provider" => provider}
        |> new()
        |> Oban.insert()
      end)

      :ok
    else
      :discard
    end
  end

  def perform(%Job{args: %{"asset_id" => asset_id, "provider" => provider}}) do
    case Repo.get(MoneyTree.Assets.Asset, asset_id) do
      nil ->
        :discard

      asset ->
        case Assets.refresh_vehicle_valuation(asset, provider: provider) do
          {:ok, _result} -> :ok
          {:error, _reason} -> :ok
        end
    end
  end

  def perform(%Job{}), do: :discard
end
