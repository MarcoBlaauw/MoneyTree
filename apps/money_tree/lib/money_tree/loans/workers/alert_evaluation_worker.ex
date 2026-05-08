defmodule MoneyTree.Loans.Workers.AlertEvaluationWorker do
  @moduledoc """
  Evaluates Loan Center alert rules in the background.
  """

  use Oban.Worker, queue: :reporting, max_attempts: 3

  alias MoneyTree.Loans
  alias Oban.Job

  @impl Oban.Worker
  def perform(%Job{args: %{"rule_id" => rule_id, "user_id" => user_id}}) do
    Loans.evaluate_loan_alert_rule(user_id, rule_id)
  end

  def perform(%Job{args: %{"mortgage_id" => mortgage_id, "user_id" => user_id}}) do
    Loans.evaluate_loan_alert_rules(user_id, mortgage_id)
  end
end
