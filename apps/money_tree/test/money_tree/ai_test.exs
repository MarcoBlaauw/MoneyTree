defmodule MoneyTree.AITest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures

  alias Decimal
  alias MoneyTree.AI
  alias MoneyTree.ManualImports
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction

  setup do
    user = user_fixture()
    account = account_fixture(user, %{name: "Checking"})

    transaction =
      %Transaction{}
      |> Transaction.changeset(%{
        account_id: account.id,
        external_id: "tx-#{System.unique_integer([:positive])}",
        source: "manual_import",
        source_transaction_id: nil,
        source_reference: nil,
        source_fingerprint: "fp-#{System.unique_integer([:positive])}",
        normalized_fingerprint: "nfp-#{System.unique_integer([:positive])}",
        posted_at: ~U[2026-04-25 10:00:00Z],
        amount: Decimal.new("-42.10"),
        currency: "USD",
        description: "Trader Joe's",
        merchant_name: "TRADER JOES",
        category: nil,
        status: "posted"
      })
      |> Repo.insert!()

    %{user: user, account: account, transaction: transaction}
  end

  test "settings can be updated and tested", %{user: user} do
    assert %{local_ai_enabled: false, provider: "ollama"} = AI.settings_snapshot(user)

    assert {:ok, _preference} =
             AI.update_settings(user, %{
               "local_ai_enabled" => true,
               "default_model" => "test-model:latest"
             })

    assert {:ok, result} = AI.test_connection(user)
    assert result.model_available
    assert "test-model:latest" in result.models
  end

  test "categorization run creates pending suggestions", %{user: user, transaction: transaction} do
    assert {:ok, _preference} =
             AI.update_settings(user, %{
               "local_ai_enabled" => true,
               "allow_ai_for_categorization" => true
             })

    assert {:ok, run} = AI.create_categorization_run(user)

    reloaded_runs = AI.list_runs(user, feature: "categorization")
    assert Enum.any?(reloaded_runs, &(&1.id == run.id and &1.status == "completed"))

    suggestions = AI.list_suggestions(user, run_id: run.id)
    assert length(suggestions) >= 1

    suggestion = Enum.find(suggestions, &(&1.target_id == transaction.id))
    assert suggestion
    assert suggestion.suggestion_type == "set_category"
    assert suggestion.status == "pending"
  end

  test "accepting suggestion applies transaction category", %{
    user: user,
    transaction: transaction
  } do
    assert {:ok, _preference} =
             AI.update_settings(user, %{
               "local_ai_enabled" => true,
               "allow_ai_for_categorization" => true
             })

    {:ok, run} = AI.create_categorization_run(user)

    suggestion =
      AI.list_suggestions(user, run_id: run.id) |> Enum.find(&(&1.target_id == transaction.id))

    assert suggestion

    assert {:ok, accepted} = AI.accept_suggestion(user, suggestion.id)
    assert accepted.status == "accepted"

    updated_transaction = Repo.get!(Transaction, transaction.id)
    assert updated_transaction.category == "Groceries"
    assert updated_transaction.categorization_source == "model"
  end

  test "import categorization run creates row suggestions and applies accepted category", %{
    user: user,
    account: account
  } do
    assert {:ok, _preference} =
             AI.update_settings(user, %{
               "local_ai_enabled" => true,
               "allow_ai_for_categorization" => true
             })

    {:ok, batch} = ManualImports.create_batch(user, %{account_id: account.id})

    {:ok, _} =
      ManualImports.stage_rows(user, batch.id, [
        %{
          posted_at: ~U[2026-04-24 10:00:00Z],
          description: "Trader Joe's weekly groceries",
          merchant_name: "TRADER JOES",
          amount: Decimal.new("-73.11"),
          currency: "USD",
          direction: "expense",
          review_decision: "accept"
        }
      ])

    [row] = ManualImports.list_rows(user, batch.id)

    Process.put(
      :ai_test_provider_response,
      {:ok,
       %{
         "suggestions" => [
           %{
             "row_id" => row.id,
             "category" => "Groceries",
             "confidence" => 0.93,
             "reason" => "merchant and description indicate grocery spending"
           }
         ]
       }}
    )

    on_exit(fn ->
      Process.delete(:ai_test_provider_response)
    end)

    assert {:ok, run} = AI.create_import_categorization_run(user, batch.id)

    reloaded_runs = AI.list_runs(user, feature: "import_categorization")
    assert Enum.any?(reloaded_runs, &(&1.id == run.id and &1.status == "completed"))

    suggestions = AI.list_suggestions(user, run_id: run.id)
    assert length(suggestions) >= 1

    suggestion = Enum.find(suggestions, &(&1.target_id == row.id))
    assert suggestion
    assert suggestion.target_type == "manual_import_row"
    assert suggestion.suggestion_type == "set_import_row_category"
    assert suggestion.status == "pending"

    assert {:ok, accepted} = AI.accept_suggestion(user, suggestion.id)
    assert accepted.status == "accepted"

    [updated_row] = ManualImports.list_rows(user, batch.id)
    assert updated_row.category_name_snapshot == "Groceries"
  end

  test "import categorization accepts wrapped suggestions and normalizes category casing", %{
    user: user,
    account: account
  } do
    assert {:ok, _preference} =
             AI.update_settings(user, %{
               "local_ai_enabled" => true,
               "allow_ai_for_categorization" => true
             })

    {:ok, batch} = ManualImports.create_batch(user, %{account_id: account.id})

    {:ok, _} =
      ManualImports.stage_rows(user, batch.id, [
        %{
          posted_at: ~U[2026-04-24 10:00:00Z],
          description: "Costco run",
          merchant_name: "COSTCO",
          amount: Decimal.new("-120.00"),
          currency: "USD",
          direction: "expense",
          review_decision: "accept"
        }
      ])

    [row] = ManualImports.list_rows(user, batch.id)

    Process.put(
      :ai_test_provider_response,
      {:ok,
       %{
         "data" => %{
           "suggestions" => [
             %{
               "row_id" => row.id,
               "category" => "groceries",
               "confidence" => 0.87,
               "reason" => "merchant indicates grocery/warehouse spending"
             }
           ]
         }
       }}
    )

    on_exit(fn ->
      Process.delete(:ai_test_provider_response)
    end)

    assert {:ok, run} = AI.create_import_categorization_run(user, batch.id)

    suggestions = AI.list_suggestions(user, run_id: run.id)
    assert length(suggestions) >= 1

    suggestion = Enum.find(suggestions, &(&1.target_id == row.id))
    assert suggestion
    assert suggestion.payload["category"] == "Groceries"
  end

  test "import categorization accepts fenced json response payloads", %{
    user: user,
    account: account
  } do
    assert {:ok, _preference} =
             AI.update_settings(user, %{
               "local_ai_enabled" => true,
               "allow_ai_for_categorization" => true
             })

    {:ok, batch} = ManualImports.create_batch(user, %{account_id: account.id})

    {:ok, _} =
      ManualImports.stage_rows(user, batch.id, [
        %{
          posted_at: ~U[2026-04-24 10:00:00Z],
          description: "Whole Foods Market",
          merchant_name: "WHOLE FOODS",
          amount: Decimal.new("-85.30"),
          currency: "USD",
          direction: "expense",
          review_decision: "accept"
        }
      ])

    [row] = ManualImports.list_rows(user, batch.id)

    Process.put(
      :ai_test_provider_response,
      {:ok,
       %{
         "response" => """
         ```json
         {"predictions":[{"row_id":"#{row.id}","category":"Groceries","confidence":0.91,"reason":"grocery merchant"}]}
         ```
         """
       }}
    )

    on_exit(fn ->
      Process.delete(:ai_test_provider_response)
    end)

    assert {:ok, run} = AI.create_import_categorization_run(user, batch.id)

    reloaded = AI.list_runs(user, feature: "import_categorization")
    assert Enum.any?(reloaded, &(&1.id == run.id and &1.status == "completed"))

    suggestion =
      AI.list_suggestions(user, run_id: run.id)
      |> Enum.find(&(&1.target_id == row.id))

    assert suggestion
    assert suggestion.payload["category"] == "Groceries"
  end

  test "import categorization retries once with smaller row slice after timeout", %{
    user: user,
    account: account
  } do
    assert {:ok, _preference} =
             AI.update_settings(user, %{
               "local_ai_enabled" => true,
               "allow_ai_for_categorization" => true
             })

    {:ok, batch} = ManualImports.create_batch(user, %{account_id: account.id})

    rows =
      Enum.map(1..30, fn index ->
        %{
          posted_at: ~U[2026-04-24 10:00:00Z],
          description: "Merchant #{index}",
          merchant_name: "MERCHANT #{index}",
          amount: Decimal.new("-10.00"),
          currency: "USD",
          direction: "expense",
          review_decision: "accept"
        }
      end)

    {:ok, _} = ManualImports.stage_rows(user, batch.id, rows)

    [first_row | _] = ManualImports.list_rows(user, batch.id)

    Process.put(:ai_test_provider_response_queue, [
      {:error, :timeout},
      {:ok,
       %{
         "suggestions" => [
           %{
             "row_id" => first_row.id,
             "category" => "Groceries",
             "confidence" => 0.8,
             "reason" => "retry succeeded"
           }
         ]
       }}
    ])

    on_exit(fn ->
      Process.delete(:ai_test_provider_response_queue)
    end)

    assert {:ok, run} = AI.create_import_categorization_run(user, batch.id)

    reloaded_runs = AI.list_runs(user, feature: "import_categorization")
    assert Enum.any?(reloaded_runs, &(&1.id == run.id and &1.status == "completed"))

    suggestion =
      AI.list_suggestions(user, run_id: run.id)
      |> Enum.find(&(&1.target_id == first_row.id))

    assert suggestion
    assert suggestion.payload["category"] == "Groceries"
  end
end
