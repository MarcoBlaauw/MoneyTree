defmodule MoneyTreeWeb.AIControllerTest do
  use MoneyTreeWeb.ConnCase

  import MoneyTree.AccountsFixtures

  alias Decimal
  alias MoneyTree.ManualImports
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction
  alias MoneyTreeWeb.Auth

  @session_cookie Auth.session_cookie_name()

  describe "AI API" do
    test "settings, categorization run, and review flow", %{conn: conn} do
      user = user_fixture()
      %{token: token} = session_fixture(user)
      account = account_fixture(user)

      _transaction =
        %Transaction{}
        |> Transaction.changeset(%{
          account_id: account.id,
          external_id: "tx-#{System.unique_integer([:positive])}",
          source: "manual_import",
          source_fingerprint: "fp-#{System.unique_integer([:positive])}",
          normalized_fingerprint: "nfp-#{System.unique_integer([:positive])}",
          posted_at: ~U[2026-04-25 10:00:00Z],
          amount: Decimal.new("-18.40"),
          currency: "USD",
          description: "Whole Foods",
          merchant_name: "WHOLE FOODS",
          status: "posted"
        })
        |> Repo.insert!()

      authed_conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

      settings_conn = get(authed_conn, ~p"/api/ai/settings")
      assert %{"data" => %{"provider" => "ollama"}} = json_response(settings_conn, 200)

      update_conn =
        put(authed_conn, ~p"/api/ai/settings", %{
          "settings" => %{
            "local_ai_enabled" => true,
            "allow_ai_for_categorization" => true
          }
        })

      assert %{"data" => %{"local_ai_enabled" => true}} = json_response(update_conn, 200)

      models_conn = get(authed_conn, ~p"/api/ai/models")
      assert %{"data" => %{"models" => models}} = json_response(models_conn, 200)
      assert "test-model:latest" in models

      run_conn = post(authed_conn, ~p"/api/ai/categorization-runs")
      assert %{"data" => %{"id" => run_id}} = json_response(run_conn, 201)

      suggestions_conn = get(authed_conn, ~p"/api/ai/suggestions?run_id=#{run_id}")
      assert %{"data" => [suggestion | _]} = json_response(suggestions_conn, 200)
      assert suggestion["status"] == "pending"

      accept_conn = post(authed_conn, ~p"/api/ai/suggestions/#{suggestion["id"]}/accept")
      assert %{"data" => %{"status" => "accepted"}} = json_response(accept_conn, 200)

      {:ok, batch} = ManualImports.create_batch(user, %{account_id: account.id})

      {:ok, _} =
        ManualImports.stage_rows(user, batch.id, [
          %{
            posted_at: ~U[2026-04-25 11:00:00Z],
            description: "Costco groceries",
            merchant_name: "COSTCO",
            amount: Decimal.new("-92.18"),
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
               "confidence" => 0.88,
               "reason" => "merchant indicates groceries"
             }
           ]
         }}
      )

      on_exit(fn ->
        Process.delete(:ai_test_provider_response)
      end)

      import_run_conn =
        post(authed_conn, ~p"/api/ai/import-categorization-runs", %{"batch_id" => batch.id})

      assert %{"data" => %{"id" => import_run_id, "feature" => "import_categorization"}} =
               json_response(import_run_conn, 201)

      import_suggestions_conn = get(authed_conn, ~p"/api/ai/suggestions?run_id=#{import_run_id}")

      assert %{"data" => [import_suggestion | _]} = json_response(import_suggestions_conn, 200)
      assert import_suggestion["target_type"] == "manual_import_row"

      accept_import_conn =
        post(authed_conn, ~p"/api/ai/suggestions/#{import_suggestion["id"]}/accept")

      assert %{"data" => %{"status" => "accepted"}} = json_response(accept_import_conn, 200)

      [updated_row] = ManualImports.list_rows(user, batch.id)
      assert updated_row.category_name_snapshot == "Groceries"
    end

    test "requires authentication", %{conn: conn} do
      conn = get(conn, ~p"/api/ai/settings")
      assert conn.status == 401
    end
  end
end
