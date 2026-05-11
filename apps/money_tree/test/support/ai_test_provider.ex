defmodule MoneyTree.AI.TestProvider do
  @moduledoc false

  @behaviour MoneyTree.AI.Provider

  @impl MoneyTree.AI.Provider
  def health_check(_settings), do: {:ok, %{status: "ok"}}

  @impl MoneyTree.AI.Provider
  def list_models(_settings), do: {:ok, ["test-model:latest", "llama3.1:8b"]}

  @impl MoneyTree.AI.Provider
  def generate_json(_settings, prompt, _opts) do
    case next_queued_response() || Process.get(:ai_test_provider_response) do
      nil ->
        if String.contains?(prompt, "\"loan_document_text\"") do
          {:ok,
           %{
             "fields" => %{
               "principal_balance" => "390000.00",
               "interest_rate" => "0.0575",
               "remaining_term_months" => 348,
               "monthly_payment" => "2275.41"
             },
             "confidence" => %{
               "principal_balance" => 0.91,
               "interest_rate" => 0.84,
               "remaining_term_months" => 0.72,
               "monthly_payment" => 0.88
             },
             "citations" => %{
               "principal_balance" => [
                 %{"page" => 1, "text" => "Unpaid principal balance $390,000.00"}
               ]
             }
           }}
        else
          if String.contains?(prompt, "\"rows\"") do
            row_id = extract_row_id(prompt)

            {:ok,
             %{
               "suggestions" => [
                 %{
                   "row_id" => row_id,
                   "category" => "Groceries",
                   "confidence" => 0.82,
                   "reason" => "merchant appears grocery related"
                 }
               ]
             }}
          else
            transaction_id =
              Process.get(:ai_test_provider_transaction_id) || extract_transaction_id(prompt)

            {:ok,
             %{
               "suggestions" => [
                 %{
                   "transaction_id" => transaction_id,
                   "category" => "Groceries",
                   "confidence" => 0.82,
                   "reason" => "merchant appears grocery related"
                 }
               ]
             }}
          end
        end

      response ->
        response
    end
  end

  defp next_queued_response do
    case Process.get(:ai_test_provider_response_queue) do
      [next | rest] ->
        Process.put(:ai_test_provider_response_queue, rest)
        next

      _ ->
        nil
    end
  end

  defp extract_transaction_id(prompt) when is_binary(prompt) do
    with {:ok, %{"transactions" => [first | _]}} <- Jason.decode(prompt),
         %{"transaction_id" => id} when is_binary(id) <- first do
      id
    else
      _ -> "missing-transaction-id"
    end
  end

  defp extract_row_id(prompt) when is_binary(prompt) do
    with {:ok, %{"rows" => [first | _]}} <- Jason.decode(prompt),
         %{"row_id" => id} when is_binary(id) <- first do
      id
    else
      _ -> "missing-row-id"
    end
  end
end
