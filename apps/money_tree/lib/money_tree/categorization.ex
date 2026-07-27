defmodule MoneyTree.Categorization do
  @moduledoc """
  Rule-driven transaction categorization with manual overrides.
  """

  import Ecto.Query, warn: false

  alias Decimal
  alias MoneyTree.Accounts
  alias MoneyTree.Categorization.Category
  alias MoneyTree.Categorization.CategoryRule
  alias MoneyTree.Categorization.UserOverride
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction
  alias MoneyTree.Users.User

  @manual_priority 10_000
  @reserved_category_names ["uncategorized"]

  @type category_attrs :: %{
          optional(:name) => String.t(),
          optional(:kind) => String.t(),
          optional(:source) => String.t(),
          optional(:active) => boolean()
        }

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

  @spec list_categories(User.t() | binary()) :: [Category.t()]
  def list_categories(user) do
    Category
    |> where([category], category.user_id == ^user_id(user) and category.active == true)
    |> where([category], fragment("lower(?)", category.name) not in ^@reserved_category_names)
    |> order_by([category], asc: fragment("lower(?)", category.name))
    |> Repo.all()
  end

  @spec category_names(User.t() | binary()) :: [String.t()]
  def category_names(user) do
    user_id = user_id(user)

    registry_names =
      Category
      |> where([category], category.user_id == ^user_id and category.active == true)
      |> where([category], fragment("lower(?)", category.name) not in ^@reserved_category_names)
      |> select([category], category.name)
      |> Repo.all()

    transaction_names =
      Transaction
      |> join(
        :inner,
        [transaction],
        account in subquery(Accounts.accessible_accounts_query(user_id)),
        on: transaction.account_id == account.id
      )
      |> where([transaction], not is_nil(transaction.category))
      |> select([transaction], transaction.category)
      |> distinct(true)
      |> Repo.all()

    rule_names =
      CategoryRule
      |> where([rule], rule.user_id == ^user_id)
      |> select([rule], rule.category)
      |> Repo.all()

    (registry_names ++ transaction_names ++ rule_names)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or reserved_category?(&1)))
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.sort_by(&String.downcase/1)
  end

  @spec category_options(User.t() | binary()) :: [map()]
  def category_options(user) do
    user_id = user_id(user)

    registry =
      Category
      |> where([category], category.user_id == ^user_id and category.active == true)
      |> where([category], fragment("lower(?)", category.name) not in ^@reserved_category_names)
      |> Repo.all()
      |> Map.new(fn category ->
        {normalize_category_key(category.name),
         %{
           name: category.name,
           emoji: category.emoji || emoji_for_category(category.name, category.kind),
           kind: category.kind,
           source: category.source
         }}
      end)

    category_names(user_id)
    |> Enum.map(fn name ->
      key = normalize_category_key(name)

      Map.get(registry, key, %{
        name: name,
        emoji: emoji_for_category(name),
        kind: "expense",
        source: "inferred"
      })
    end)
  end

  @spec create_category(User.t() | binary(), map()) ::
          {:ok, Category.t()} | {:error, Ecto.Changeset.t()}
  def create_category(user, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> stringify_keys()
      |> Map.put("user_id", user_id(user))
      |> Map.put_new("source", "manual")

    if reserved_category?(Map.get(attrs, "name")) do
      changeset =
        %Category{}
        |> Category.changeset(attrs)
        |> Ecto.Changeset.add_error(:name, "is reserved for uncategorized transactions")

      {:error, changeset}
    else
      attrs
      |> put_category_emoji()
      |> insert_category()
    end
  end

  defp put_category_emoji(attrs) do
    attrs =
      case Map.get(attrs, "emoji") do
        emoji when is_binary(emoji) ->
          if String.trim(emoji) == "" do
            Map.put(
              attrs,
              "emoji",
              emoji_for_category(Map.get(attrs, "name"), Map.get(attrs, "kind"))
            )
          else
            attrs
          end

        _ ->
          Map.put(
            attrs,
            "emoji",
            emoji_for_category(Map.get(attrs, "name"), Map.get(attrs, "kind"))
          )
      end

    attrs
  end

  defp insert_category(attrs) do
    %Category{}
    |> Category.changeset(attrs)
    |> Repo.insert(
      on_conflict: [
        set: [
          active: true,
          kind: Map.get(attrs, "kind") || "expense",
          source: Map.get(attrs, "source") || "manual",
          emoji: Map.get(attrs, "emoji") || "🏷️",
          updated_at: DateTime.utc_now()
        ]
      ],
      conflict_target: {:unsafe_fragment, "(user_id, lower(name))"},
      returning: true
    )
  end

  @spec ensure_category(User.t() | binary(), String.t(), keyword()) ::
          {:ok, Category.t()} | {:error, Ecto.Changeset.t()} | :ok
  def ensure_category(user, category, opts \\ [])

  def ensure_category(_user, category, _opts) when not is_binary(category), do: :ok

  def ensure_category(user, category, opts) when is_binary(category) do
    category = String.trim(category)

    if category == "" or reserved_category?(category) do
      :ok
    else
      create_category(user, %{
        name: category,
        emoji: emoji_for_category(category, Keyword.get(opts, :kind, "expense")),
        kind: Keyword.get(opts, :kind, "expense"),
        source: Keyword.get(opts, :source, "manual")
      })
    end
  end

  @spec delete_category(User.t() | binary(), binary()) ::
          {:ok, Category.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def delete_category(user, category_id) do
    case Repo.get_by(Category, id: category_id, user_id: user_id(user)) do
      nil ->
        {:error, :not_found}

      category ->
        category
        |> Category.changeset(%{active: false})
        |> Repo.update()
    end
  end

  @spec create_rule(User.t() | binary(), map()) ::
          {:ok, CategoryRule.t()} | {:error, Ecto.Changeset.t()}
  def create_rule(user, attrs) do
    attrs =
      attrs
      |> Map.new()
      |> stringify_keys()
      |> Map.put("user_id", user_id(user))

    with {:ok, rule} <-
           %CategoryRule{}
           |> CategoryRule.changeset(attrs)
           |> Repo.insert() do
      _ = ensure_category(user, rule.category, source: rule.source || "manual")
      {:ok, rule}
    end
  end

  @spec delete_rule(User.t() | binary(), binary()) ::
          {:ok, CategoryRule.t()} | {:error, :not_found}
  def delete_rule(user, rule_id) do
    case Repo.get_by(CategoryRule, id: rule_id, user_id: user_id(user)) do
      nil -> {:error, :not_found}
      rule -> Repo.delete(rule)
    end
  end

  @spec clear_rules(User.t() | binary()) :: non_neg_integer()
  def clear_rules(user) do
    {count, _} =
      CategoryRule
      |> where([rule], rule.user_id == ^user_id(user))
      |> Repo.delete_all()

    count
  end

  @spec apply_to_transaction(Transaction.t()) ::
          {:ok, Transaction.t()} | {:error, Ecto.Changeset.t()}
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
    category = normalize_category_assignment(category)

    with %Transaction{} = transaction <- fetch_user_transaction(user_id, transaction_id),
         {:ok, _override} <- upsert_override_or_clear(transaction, category),
         {:ok, _rule} <- ensure_manual_rule_or_clear(user_id, transaction, category),
         _ <- ensure_category(user_id, category, source: "manual"),
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
      %UserOverride{} = override ->
        %{
          category: override.category,
          source: "manual",
          confidence: override.confidence || Decimal.new("1.0")
        }

      %CategoryRule{} = rule ->
        %{
          category: rule.category,
          source: "rule",
          confidence: rule.confidence
        }
    end
  end

  defp fetch_user_transaction(user_id, transaction_id) do
    Transaction
    |> join(:inner, [transaction], account in assoc(transaction, :account))
    |> where(
      [transaction, account],
      transaction.id == ^transaction_id and account.user_id == ^user_id
    )
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
    |> order_by([rule], desc: rule.priority, desc: rule.inserted_at)
    |> filter_rules_by_user(user_id)
  end

  defp filter_rules_by_user(query, nil), do: where(query, [rule], is_nil(rule.user_id))
  defp filter_rules_by_user(query, user_id), do: where(query, [rule], rule.user_id == ^user_id)

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

  defp keyword_matches?(
         %CategoryRule{description_keywords: keywords},
         %Transaction{} = transaction
       ) do
    text =
      [transaction.description, transaction.merchant_name]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

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
    category =
      if uncategorized_value?(transaction.category),
        do: "Uncategorized",
        else: transaction.category

    %{
      category: category,
      source: if(category == "Uncategorized", do: nil, else: "provider"),
      confidence: if(category == "Uncategorized", do: nil, else: Decimal.new("0.70"))
    }
  end

  defp apply_manual_decision(%Transaction{} = transaction, category) do
    attrs =
      if is_nil(category) do
        %{
          category: nil,
          categorization_source: nil,
          categorization_confidence: nil
        }
      else
        %{
          category: category,
          categorization_source: "manual",
          categorization_confidence: Decimal.new("1.0")
        }
      end

    transaction
    |> Transaction.changeset(attrs)
    |> Repo.update()
  end

  defp upsert_override_or_clear(%Transaction{} = transaction, nil) do
    case Repo.get_by(UserOverride, transaction_id: transaction.id) do
      nil -> {:ok, nil}
      override -> Repo.delete(override)
    end
  end

  defp upsert_override_or_clear(%Transaction{} = transaction, category) do
    upsert_override(transaction, category)
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

  defp ensure_manual_rule_or_clear(user_id, transaction, nil) do
    delete_matching_manual_rule(user_id, transaction)
    {:ok, nil}
  end

  defp ensure_manual_rule_or_clear(user_id, transaction, category) do
    ensure_manual_rule(user_id, transaction, category)
  end

  defp delete_matching_manual_rule(user_id, %Transaction{} = transaction) do
    regex =
      case transaction.merchant_name do
        merchant when is_binary(merchant) and merchant != "" ->
          "^" <> Regex.escape(merchant) <> "$"

        _ ->
          nil
      end

    CategoryRule
    |> where([rule], rule.user_id == ^user_id)
    |> where([rule], rule.source == "manual")
    |> where([rule], rule.priority == ^@manual_priority)
    |> where([rule], rule.merchant_regex == ^regex)
    |> Repo.delete_all()
  end

  defp ensure_manual_rule(user_id, %Transaction{} = transaction, category) do
    regex =
      case transaction.merchant_name do
        merchant when is_binary(merchant) and merchant != "" ->
          "^" <> Regex.escape(merchant) <> "$"

        _ ->
          nil
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

  defp stringify_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp normalize_category_key(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp reserved_category?(value), do: normalize_category_key(value) in @reserved_category_names

  defp uncategorized_value?(nil), do: true
  defp uncategorized_value?(value) when is_binary(value), do: reserved_category?(value)
  defp uncategorized_value?(_value), do: false

  defp normalize_category_assignment(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> nil
      reserved_category?(value) -> nil
      true -> value
    end
  end

  defp normalize_category_assignment(_value), do: nil

  defp emoji_for_category(category, kind \\ nil)

  defp emoji_for_category(category, kind) do
    normalized = normalize_category_key(category)

    cond do
      normalized =~ "grocery" or normalized =~ "market" -> "🛒"
      normalized =~ "dining" or normalized =~ "restaurant" or normalized =~ "coffee" -> "🍽️"
      normalized =~ "fuel" or normalized =~ "gas" -> "⛽"
      normalized =~ "utilit" or normalized =~ "electric" or normalized =~ "water" -> "💡"
      normalized =~ "insurance" -> "🛡️"
      normalized =~ "income" or kind == "income" -> "💵"
      normalized =~ "transfer" or kind == "transfer" -> "🔁"
      normalized =~ "credit card" -> "💳"
      normalized =~ "loan" or normalized =~ "mortgage" -> "🏦"
      normalized =~ "subscription" or normalized =~ "streaming" or normalized =~ "software" -> "🔄"
      normalized =~ "medical" or normalized =~ "hospital" or normalized =~ "health" -> "🏥"
      normalized =~ "fee" -> "🧾"
      true -> "🏷️"
    end
  end

  @spec recategorize_all(User.t() | binary()) :: non_neg_integer()
  def recategorize_all(user) do
    user
    |> Accounts.accessible_accounts_query()
    |> join(:inner, [account], transaction in Transaction,
      on: transaction.account_id == account.id
    )
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
