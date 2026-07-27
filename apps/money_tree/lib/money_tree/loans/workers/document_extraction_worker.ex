defmodule MoneyTree.Loans.Workers.DocumentExtractionWorker do
  @moduledoc """
  Extracts reviewable candidate fields from stored loan document text.
  """

  use Oban.Worker, queue: :reporting, max_attempts: 3

  alias MoneyTree.Loans
  alias Oban.Job

  @impl Oban.Worker
  def perform(%Job{args: %{"document_id" => document_id, "user_id" => user_id}})
      when is_binary(document_id) and is_binary(user_id) do
    case Loans.process_loan_document_extraction_job(user_id, document_id) do
      :ok -> :ok
      {:error, :not_found} -> :discard
      {:error, _reason} -> :ok
    end
  end

  def perform(%Job{}), do: :discard
end
