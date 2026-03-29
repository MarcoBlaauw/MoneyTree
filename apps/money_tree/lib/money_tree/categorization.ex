defmodule MoneyTree.Categorization do
  @moduledoc """
  Rule-driven transaction categorization with manual overrides.
  """

  import Ecto.Query, warn: false

  alias Decimal
  alias MoneyTree.Accounts
  alias MoneyTree.Categorization.CategoryRule
  alias MoneyTree.Categorization.UserOverride
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction
  alias MoneyTree.Users.User

  @manual_priority 10_000

  @type decision :: %{
          category: String.t(),
          source: String.t(),
          confidence: Decimal.t() | nil
        }

  @spec list_rules(User.t() | binary()) :: [CategoryRule.t()]
  def list_rules(user) do
    user_id = user_id(user)

    CategoryRule
    |> where([rule], rule.user_id == ^user_id)
    |> order_by([rule], desc: rule.priority, desc: rule.inserted_at)
    |> Repo.all()
  end

  @spec create_rule(User.t() | binary(), map()) :: {:ok, CategoryRule.t()} | {:error, Ecto.Changeset.t()}
  def create_rule(user, attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put(:user_id, user_id(user))

    %CategoryRule{}
    |> CategoryRule.changeset(attrs)
    |> Repo.insert()
  end

  @spec delete_rule(User.t() | binary(), binary()) :: {:ok, CategoryRule.t()} | {:error, :not_found}
  def delete_rule(user, rule_id) do
    case Repo.get_by(CategoryRule, id: rule_id, user_id: user_id(user)) do
      nil -> {:error, :not_found}
      rule -> Repo.delete(rule)
    end
  end

  @spec apply_to_transaction(Transaction.t()) :: {:ok, Transaction.t()} | {:error, Ecto.Changeset.t()}
  def apply_to_transaction(%Transaction{} = transaction) do
    transaction = Repo.preload(transaction, :account)
    decision = categorize(transaction)

    transaction
    |> Transaction.changeset(%{
      category: decision.category,
      categorization_source: decision.source,
      categorization_confidence: decision.confidence
    })
    |> Repo.update()
  end

  @spec recategorize_transaction(User.t() | binary(), binary(), String.t()) ::
          {:ok, Transaction.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def recategorize_transaction(user, transaction_id, category) do
    user_id = user_id(user)

    with %Transaction{} = transaction <- fetch_user_transaction(user_id, transaction_id),
         {:ok, _override} <- upsert_override(transaction, category),
         {:ok, _rule} <- ensure_manual_rule(user_id, transaction, category),
         {:ok, updated} <- apply_manual_decision(transaction, category) do
      {:ok, updated}
    else
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  @spec recategorize_by_rule(User.t() | binary(), binary()) ::
          {:ok, Transaction.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def recategorize_by_rule(user, transaction_id) do
    user_id = user_id(user)

    case fetch_user_transaction(user_id, transaction_id) do
      nil -> {:error, :not_found}
      transaction -> apply_to_transaction(transaction)
    end
  end

  @spec categorize(Transaction.t()) :: decision()
  def categorize(%Transaction{} = transaction) do
    transaction = Repo.preload(transaction, :account)

    with nil <- manual_override_for(transaction),
         nil <- first_matching_user_rule(transaction),
         nil <- first_matching_deterministic_rule(transaction) do
      provider_decision(transaction)
    else
      %UserOverride{} = override -> %{
        category: override.category,
        source: "manual",
        confidence: override.confidence || Decimal.new("1.0")
      }

      %CategoryRule{} = rule -> %{
        category: rule.category,
        source: "rule",
        confidence: rule.confidence
      }
    end
  end

  defp fetch_user_transaction(user_id, transaction_id) do
    Transaction
    |> join(:inner, [transaction], account in assoc(transaction, :account))
    |> where([transaction, account], transaction.id == ^transaction_id and account.user_id == ^user_id)
    |> preload([transaction, account], account: account)
    |> Repo.one()
  end

  defp manual_override_for(%Transaction{id: transaction_id}) do
    Repo.get_by(UserOverride, transaction_id: transaction_id)
  end

  defp first_matching_user_rule(%Transaction{} = transaction) do
    transaction.account.user_id
    |> rules_query()
    |> Repo.all()
    |> Enum.find(&match_rule?(&1, transaction))
  end

  defp first_matching_deterministic_rule(%Transaction{} = transaction) do
    rules_query(nil)
    |> Repo.all()
    |> Enum.find(&match_rule?(&1, transaction))
  end

  defp rules_query(user_id) do
    CategoryRule
    |> where([rule], rule.user_id == ^user_id)
    |> order_by([rule], desc: rule.priority, desc: rule.inserted_at)
  end

  defp match_rule?(%CategoryRule{} = rule, %Transaction{} = transaction) do
    merchant_matches?(rule, transaction) and
      keyword_matches?(rule, transaction) and
      amount_matches?(rule, transaction) and
      account_type_matches?(rule, transaction)
  end

  defp merchant_matches?(%CategoryRule{merchant_regex: nil}, _transaction), do: true

  defp merchant_matches?(%CategoryRule{merchant_regex: regex}, %Transaction{} = transaction) do
    with merchant when is_binary(merchant) and merchant != "" <- transaction.merchant_name,
         {:ok, compiled} <- Regex.compile(regex, "i") do
      Regex.match?(compiled, merchant)
    else
      _ -> false
    end
  end

  defp keyword_matches?(%CategoryRule{description_keywords: keywords}, _transaction)
       when not is_list(keywords) or keywords == [],
       do: true

  defp keyword_matches?(%CategoryRule{description_keywords: keywords}, %Transaction{} = transaction) do
    text = [transaction.description, transaction.merchant_name] |> Enum.reject(&is_nil/1) |> Enum.join(" ") |> String.downcase()

    Enum.any?(keywords, fn keyword ->
      keyword = keyword |> to_string() |> String.trim() |> String.downcase()
      keyword != "" and String.contains?(text, keyword)
    end)
  end

  defp amount_matches?(%CategoryRule{} = rule, %Transaction{} = transaction) do
    amount = abs_decimal(transaction.amount)

    min_ok =
      case rule.min_amount do
        nil -> true
        min -> Decimal.compare(amount, abs_decimal(min)) in [:gt, :eq]
      end

    max_ok =
      case rule.max_amount do
        nil -> true
        max -> Decimal.compare(amount, abs_decimal(max)) in [:lt, :eq]
      end

    min_ok and max_ok
  end

  defp account_type_matches?(%CategoryRule{account_types: types}, _transaction)
       when not is_list(types) or types == [],
       do: true

  defp account_type_matches?(%CategoryRule{account_types: types}, %Transaction{} = transaction) do
    transaction_type = transaction.account && transaction.account.type
    Enum.any?(types, &(&1 == transaction_type))
  end

  defp provider_decision(%Transaction{} = transaction) do
    category = transaction.category || "Uncategorized"

    %{
      category: category,
      source: "provider",
      confidence: if(is_binary(transaction.category), do: Decimal.new("0.70"), else: nil)
    }
  end

  defp apply_manual_decision(%Transaction{} = transaction, category) do
    transaction
    |> Transaction.changeset(%{
      category: category,
      categorization_source: "manual",
      categorization_confidence: Decimal.new("1.0")
    })
    |> Repo.update()
  end

  defp upsert_override(%Transaction{} = transaction, category) do
    attrs = %{
      transaction_id: transaction.id,
      category: category,
      source: "manual",
      confidence: Decimal.new("1.0")
    }

    %UserOverride{}
    |> UserOverride.changeset(attrs)
    |> Repo.insert(
      conflict_target: [:transaction_id],
      on_conflict: [
        set: [
          category: category,
          source: "manual",
          confidence: Decimal.new("1.0"),
          updated_at: DateTime.utc_now()
        ]
      ],
      returning: true
    )
  end

  defp ensure_manual_rule(user_id, %Transaction{} = transaction, category) do
    regex =
      case transaction.merchant_name do
        merchant when is_binary(merchant) and merchant != "" -> "^" <> Regex.escape(merchant) <> "$"
        _ -> nil
      end

    keywords =
      transaction.description
      |> tokenize_keywords()
      |> Enum.take(3)

    attrs = %{
      user_id: user_id,
      category: category,
      merchant_regex: regex,
      description_keywords: keywords,
      min_amount: abs_decimal(transaction.amount),
      max_amount: abs_decimal(transaction.amount),
      account_types: [transaction.account.type],
      priority: @manual_priority,
      source: "manual",
      confidence: Decimal.new("1.0")
    }

    %CategoryRule{}
    |> CategoryRule.changeset(attrs)
    |> Repo.insert()
  end

  defp tokenize_keywords(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.uniq()
  end

  defp tokenize_keywords(_), do: []

  defp abs_decimal(value) do
    case Decimal.cast(value) do
      {:ok, decimal} -> Decimal.abs(decimal)
      :error -> Decimal.new("0")
    end
  end

  defp user_id(%User{id: id}), do: id
  defp user_id(id) when is_binary(id), do: id

  @spec recategorize_all(User.t() | binary()) :: non_neg_integer()
  def recategorize_all(user) do
    user
    |> Accounts.accessible_accounts_query()
    |> join(:inner, [account], transaction in Transaction, on: transaction.account_id == account.id)
    |> select([_account, transaction], transaction)
    |> Repo.all()
    |> Enum.reduce(0, fn transaction, acc ->
      case apply_to_transaction(transaction) do
        {:ok, _} -> acc + 1
        {:error, _} -> acc
      end
    end)
  end
end
