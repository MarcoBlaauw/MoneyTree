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

  describe "category registry and rule maintenance" do
    test "categories are user scoped and user rules can be cleared without deleting system rules" do
      user = AccountsFixtures.user_fixture()
      other_user = AccountsFixtures.user_fixture()

      assert {:ok, category} =
               Categorization.create_category(user, %{name: " Subscriptions ", kind: "expense"})

      assert {:ok, _other_category} =
               Categorization.create_category(other_user, %{name: "Other", kind: "expense"})

      assert [listed] = Categorization.list_categories(user)
      assert listed.id == category.id
      assert listed.name == "Subscriptions"
      assert listed.emoji == "🔄"

      assert [%{name: "Subscriptions", emoji: "🔄"}] = Categorization.category_options(user)

      assert {:ok, _user_rule} =
               Categorization.create_rule(user, %{
                 category: "Subscriptions",
                 merchant_regex: "Netflix",
                 priority: 100
               })

      Repo.insert!(
        CategoryRule.changeset(%CategoryRule{}, %{
          category: "System",
          merchant_regex: "System",
          priority: 1,
          source: "rule"
        })
      )

      assert Categorization.clear_rules(user) == 1
      assert Categorization.list_rules(user) == []

      assert Repo.one(
               from rule in CategoryRule,
                 where: is_nil(rule.user_id) and rule.category == "System"
             )

      assert {:ok, hidden} = Categorization.delete_category(user, category.id)
      refute hidden.active
      assert Categorization.list_categories(user) == []
    end

    test "uncategorized is reserved and manual saves clear category state" do
      user = AccountsFixtures.user_fixture()
      account = AccountsFixtures.account_fixture(user, %{type: "depository"})

      transaction =
        %Transaction{}
        |> Transaction.changeset(%{
          account_id: account.id,
          external_id: "txn-reserved-uncategorized",
          amount: Decimal.new("-12.00"),
          currency: "USD",
          posted_at: DateTime.utc_now(),
          description: "Unknown merchant",
          merchant_name: "Unknown",
          category: "Dining",
          categorization_source: "manual",
          categorization_confidence: Decimal.new("1.0"),
          status: "posted"
        })
        |> Repo.insert!()

      assert {:error, changeset} =
               Categorization.create_category(user, %{name: "Uncategorized", kind: "expense"})

      assert "is reserved for uncategorized transactions" in errors_on(changeset).name

      assert {:ok, cleared} =
               Categorization.recategorize_transaction(user, transaction.id, "Uncategorized")

      assert is_nil(cleared.category)
      assert is_nil(cleared.categorization_source)
      assert is_nil(cleared.categorization_confidence)
      assert Categorization.list_categories(user) == []
      assert Categorization.list_rules(user) == []
      assert Repo.get_by(UserOverride, transaction_id: transaction.id) == nil
    end
  end
end
