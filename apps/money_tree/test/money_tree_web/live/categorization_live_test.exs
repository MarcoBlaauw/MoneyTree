defmodule MoneyTreeWeb.CategorizationLiveTest do
  use MoneyTreeWeb.ConnCase, async: true

  import MoneyTree.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Decimal
  alias MoneyTree.AI.SuggestionRun
  alias MoneyTree.Categorization
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction

  setup :register_and_log_in_user

  test "users can manage categories and clear their rules", %{conn: conn, user: user} do
    account = account_fixture(user)

    %Transaction{}
    |> Transaction.changeset(%{
      account_id: account.id,
      external_id: "live-categorization",
      amount: Decimal.new("-19.99"),
      currency: "USD",
      posted_at: DateTime.utc_now(),
      description: "Streaming service",
      merchant_name: "Stream Co",
      status: "posted"
    })
    |> Repo.insert!()

    %Transaction{}
    |> Transaction.changeset(%{
      account_id: account.id,
      external_id: "live-categorized",
      amount: Decimal.new("-11.99"),
      currency: "USD",
      posted_at: DateTime.utc_now(),
      description: "Already categorized",
      merchant_name: "Categorized Co",
      category: "Dining",
      status: "posted"
    })
    |> Repo.insert!()

    {:ok, view, html} = live(conn, ~p"/app/transactions/categorization")

    assert html =~ "AI suggestions"
    assert html =~ "Completed batches"
    assert html =~ "Uncategorized transactions"
    refute html =~ "Already categorized"
    assert html =~ "Show details"
    assert html =~ "Categories"
    assert html =~ "Clear all rules"
    assert html =~ "<select"
    assert html =~ "phx-click=\"run-ai\""
    assert html =~ "aria-label=\"Category emoji\""
    refute html =~ "placeholder=\"Category\""
    refute html =~ "name=\"category[emoji]\" placeholder=\"Emoji\""

    view
    |> form("form[phx-submit=\"create-category\"]", %{
      "category" => %{"name" => "Subscriptions", "kind" => "expense"}
    })
    |> render_submit()

    assert render(view) =~ "Subscriptions"
    assert render(view) =~ "🔄"

    assert {:ok, _rule} =
             Categorization.create_rule(user, %{
               category: "Subscriptions",
               merchant_regex: "Stream",
               priority: 100
             })

    assert render_click(element(view, "button[phx-click=\"clear-rules\"]")) =~
             "Cleared 1 user rules"

    assert Categorization.list_rules(user) == []
  end

  test "AI run status details are collapsed and limited", %{conn: conn, user: user} do
    for index <- 1..6 do
      %SuggestionRun{}
      |> SuggestionRun.changeset(%{
        user_id: user.id,
        provider: "ollama",
        model: "batch-model-#{index}",
        feature: "categorization",
        status: "failed",
        input_scope: %{"transaction_count" => index},
        error_code: "timeout"
      })
      |> Repo.insert!()
    end

    {:ok, view, html} = live(conn, ~p"/app/transactions/categorization")

    assert html =~ "Show details"
    refute html =~ "batch-model-1"

    expanded = render_click(element(view, "button[phx-click=\"toggle-ai-status\"]"))

    assert expanded =~ "Hide details"
    assert expanded =~ "Showing latest 5 of 6 batches."
    assert expanded =~ "timeout"
  end
end
