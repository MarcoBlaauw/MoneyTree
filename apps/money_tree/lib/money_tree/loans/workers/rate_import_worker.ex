defmodule MoneyTree.Loans.Workers.RateImportWorker do
  @moduledoc """
  Imports configured benchmark rate observations for Loan Center.
  """

  use Oban.Worker, queue: :reporting, max_attempts: 3

  alias MoneyTree.Loans
  alias Oban.Job

  @impl Oban.Worker
  def perform(%Job{args: %{"provider" => "fred"}}) do
    case Loans.import_fred_market_rates() do
      {:ok, _summary} -> :ok
      {:error, :disabled} -> :discard
      {:error, _reason} -> :ok
    end
  end

  def perform(%Job{args: %{"rate_source_id" => rate_source_id}}) when is_binary(rate_source_id) do
    case Loans.process_rate_import_job(rate_source_id) do
      {:ok, _summary} -> :ok
      {:error, :not_found} -> :discard
      {:error, :disabled} -> :discard
      {:error, :no_configured_observations} -> :discard
      {:error, _reason} -> :ok
    end
  end

  def perform(%Job{}), do: :discard
end
