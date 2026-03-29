defmodule MoneyTree.CategorizationTest do
  use MoneyTree.DataCase, async: true

  import Ecto.Query

  alias Decimal
  alias MoneyTree.AccountsFixtures
  alias MoneyTree.Categorization
  alias MoneyTree.Categorization.CategoryRule
  alias MoneyTree.Categorization.UserOverride
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction

  describe "categorization precedence" do
    test "manual override > explicit user rule > deterministic rule > provider/default" do
      user = AccountsFixtures.user_fixture()
      account = AccountsFixtures.account_fixture(user, %{type: "depository"})

      transaction =
        %Transaction{}
        |> Transaction.changeset(%{
          account_id: account.id,
          external_id: "txn-precedence",
          amount: Decimal.new("-40.00"),
          currency: "USD",
          posted_at: DateTime.utc_now(),
          description: "Coffee beans",
          merchant_name: "Bean Market",
          category: "ProviderCategory",
          status: "posted"
        })
        |> Repo.insert!()

      assert {:ok, categorized} = Categorization.apply_to_transaction(transaction)
      assert categorized.category == "ProviderCategory"
      assert categorized.categorization_source == "provider"

      Repo.insert!(
        CategoryRule.changeset(%CategoryRule{}, %{
          category: "Deterministic",
          merchant_regex: "Bean",
          priority: 100,
          source: "rule",
          confidence: Decimal.new("0.8")
        })
      )

      assert {:ok, deterministic} = Categorization.apply_to_transaction(transaction)
      assert deterministic.category == "Deterministic"
      assert deterministic.categorization_source == "rule"

      assert {:ok, _rule} =
               Categorization.create_rule(user, %{
                 category: "UserRule",
                 merchant_regex: "Bean Market",
                 priority: 500,
                 source: "rule",
                 confidence: Decimal.new("0.9")
               })

      assert {:ok, explicit_user} = Categorization.apply_to_transaction(transaction)
      assert explicit_user.category == "UserRule"
      assert explicit_user.categorization_source == "rule"

      assert {:ok, manual} =
               Categorization.recategorize_transaction(user, transaction.id, "ManualChoice")

      assert manual.category == "ManualChoice"
      assert manual.categorization_source == "manual"

      override = Repo.get_by!(UserOverride, transaction_id: transaction.id)
      assert override.category == "ManualChoice"

      generated_rule =
        Repo.one!(
          from rule in CategoryRule,
            where: rule.user_id == ^user.id and rule.category == "ManualChoice",
            order_by: [desc: rule.priority]
        )

      assert generated_rule.priority >= 10_000

      similar_transaction =
        %Transaction{}
        |> Transaction.changeset(%{
          account_id: account.id,
          external_id: "txn-similar",
          amount: Decimal.new("-40.00"),
          currency: "USD",
          posted_at: DateTime.utc_now(),
          description: "Coffee beans purchase",
          merchant_name: "Bean Market",
          status: "posted"
        })
        |> Repo.insert!()

      assert {:ok, future_choice} = Categorization.apply_to_transaction(similar_transaction)
      assert future_choice.category == "ManualChoice"
    end
  end
end
