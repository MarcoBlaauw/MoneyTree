defmodule MoneyTree.AI do
  @moduledoc """
  AI suggestion context with local-provider integration and review workflows.
  """

  import Ecto.Query, warn: false

  alias Decimal
  alias Ecto.Multi
  alias MoneyTree.Accounts
  alias MoneyTree.AI.CategorizationWorker
  alias MoneyTree.AI.Config
  alias MoneyTree.AI.Suggestion
  alias MoneyTree.AI.SuggestionRun
  alias MoneyTree.AI.UserPreference
  alias MoneyTree.ManualImports
  alias MoneyTree.ManualImports.Row, as: ManualImportRow
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction
  alias MoneyTree.Users.User
  alias Oban

  @prompt_version "categorization-v1"
  @schema_version "categorization-v1"
  @import_timeout_ms 120_000
  @import_retry_row_limit 25
  @import_prompt_category_limit 60
  @import_prompt_text_max_chars 160
  @loan_document_text_max_chars 20_000
  @loan_document_excerpt_max_chars 10_000

  @loan_document_extraction_fields ~w(
    current_balance
    current_interest_rate
    remaining_term_months
    original_loan_amount
    original_term_months
    monthly_payment_total
    monthly_principal_interest
    escrow_monthly
    pmi_monthly
    servicer_name
    lender_name
    product_type
    term_months
    interest_rate
    apr
    points
    lender_credit_amount
    estimated_closing_costs_low
    estimated_closing_costs_expected
    estimated_closing_costs_high
    estimated_cash_to_close_low
    estimated_cash_to_close_expected
    estimated_cash_to_close_high
    estimated_monthly_payment_low
    estimated_monthly_payment_expected
    estimated_monthly_payment_high
    quote_expires_at
    lock_expires_at
    statement_date
    next_payment_due_date
    payoff_good_through_date
  )

  @default_categories [
    "Groceries",
    "Dining",
    "Fuel",
    "Utilities",
    "Insurance",
    "Fees",
    "Income",
    "Transfer",
    "Uncategorized"
  ]

  @spec settings_snapshot(User.t() | binary()) :: map()
  def settings_snapshot(user) do
    preference = get_or_build_preference(user)

    provider_settings = Config.provider_settings(preference.provider)

    %{
      enabled_globally: Config.enabled?(),
      require_confirmation: Config.require_confirmation?(),
      local_ai_enabled: preference.local_ai_enabled,
      provider: preference.provider,
      ollama_base_url: preference.ollama_base_url || provider_settings.base_url,
      default_model: preference.default_model || provider_settings.model,
      allow_ai_for_categorization: preference.allow_ai_for_categorization,
      allow_ai_for_budget_recommendations: preference.allow_ai_for_budget_recommendations,
      allow_ai_pattern_detection: preference.allow_ai_pattern_detection,
      store_prompt_debug_data: preference.store_prompt_debug_data
    }
  end

  @spec update_settings(User.t() | binary(), map()) ::
          {:ok, UserPreference.t()} | {:error, Ecto.Changeset.t()}
  def update_settings(user, attrs) when is_map(attrs) do
    user_id = resolve_user_id(user)

    attrs =
      attrs
      |> stringify_keys()
      |> normalize_settings_aliases()

    preference = get_or_build_preference(user_id)

    params =
      attrs
      |> Map.take([
        "local_ai_enabled",
        "provider",
        "ollama_base_url",
        "default_model",
        "allow_ai_for_categorization",
        "allow_ai_for_budget_recommendations",
        "allow_ai_pattern_detection",
        "store_prompt_debug_data"
      ])
      |> Map.put("user_id", user_id)

    preference
    |> UserPreference.changeset(params)
    |> Repo.insert_or_update()
  end

  @spec list_models(User.t() | binary()) :: {:ok, [String.t()]} | {:error, term()}
  def list_models(user) do
    runtime = runtime_settings(user)
    provider_module(runtime.provider).list_models(runtime)
  end

  @spec test_connection(User.t() | binary(), map()) :: {:ok, map()} | {:error, term()}
  def test_connection(user, overrides \\ %{}) when is_map(overrides) do
    runtime = runtime_settings(user, overrides)
    provider = provider_module(runtime.provider)

    with {:ok, _} <- provider.health_check(runtime),
         {:ok, models} <- provider.list_models(runtime) do
      model_available? =
        runtime.model
        |> case do
          model when is_binary(model) and model != "" -> model in models
          _ -> false
        end

      {:ok,
       %{
         provider: runtime.provider,
         base_url: runtime.base_url,
         model: runtime.model,
         model_available: model_available?,
         models: models
       }}
    end
  end

  @spec extract_loan_document_fields(User.t() | binary(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def extract_loan_document_fields(user, text, opts \\ %{})

  def extract_loan_document_fields(user, text, opts) when is_binary(text) and is_map(opts) do
    opts = stringify_keys(opts)

    runtime =
      user
      |> runtime_settings(opts)
      |> ensure_min_timeout(@import_timeout_ms)

    with :ok <- ensure_ai_enabled(runtime),
         {:ok, prompt_text} <- normalize_document_text(text),
         prompt <- loan_document_extraction_prompt(prompt_text, opts),
         {:ok, response} <- provider_module(runtime.provider).generate_json(runtime, prompt, []),
         {:ok, normalized} <- normalize_loan_document_extraction_output(response) do
      {:ok,
       %{
         extraction_method: "ollama",
         model_name: runtime.model,
         raw_text_excerpt: String.slice(prompt_text, 0, @loan_document_excerpt_max_chars),
         extracted_payload: normalized.extracted_payload,
         field_confidence: normalized.field_confidence,
         source_citations: normalized.source_citations
       }}
    end
  end

  def extract_loan_document_fields(_user, _text, _opts), do: {:error, :invalid_text}

  @spec create_categorization_run(User.t() | binary(), map()) ::
          {:ok, SuggestionRun.t()} | {:error, term()}
  def create_categorization_run(user, opts \\ %{}) when is_map(opts) do
    runtime = runtime_settings(user)
    user_id = resolve_user_id(user)

    with :ok <- ensure_ai_enabled(runtime),
         :ok <- ensure_categorization_allowed(user_id),
         transactions <- candidate_transactions(user_id, opts),
         true <- transactions != [] or {:error, :no_transactions} do
      transaction_ids = Enum.map(transactions, & &1.id)

      params = %{
        user_id: user_id,
        provider: runtime.provider,
        model: runtime.model,
        feature: "categorization",
        status: "queued",
        input_scope: %{
          "transaction_ids" => transaction_ids,
          "transaction_count" => length(transaction_ids)
        },
        prompt_version: @prompt_version,
        schema_version: @schema_version
      }

      with {:ok, run} <- %SuggestionRun{} |> SuggestionRun.changeset(params) |> Repo.insert(),
           {:ok, _job} <- enqueue_categorization_run(run.id) do
        {:ok, run}
      end
    else
      false -> {:error, :no_transactions}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec create_import_categorization_run(User.t() | binary(), binary(), map()) ::
          {:ok, SuggestionRun.t()} | {:error, term()}
  def create_import_categorization_run(user, batch_id, opts \\ %{})
      when is_binary(batch_id) and is_map(opts) do
    runtime = runtime_settings(user)
    user_id = resolve_user_id(user)

    with :ok <- ensure_ai_enabled(runtime),
         :ok <- ensure_categorization_allowed(user_id),
         {:ok, _batch} <- ManualImports.get_batch(user_id, batch_id),
         rows <- candidate_import_rows(user_id, batch_id, opts),
         true <- rows != [] or {:error, :no_import_rows} do
      row_ids = Enum.map(rows, & &1.id)

      params = %{
        user_id: user_id,
        provider: runtime.provider,
        model: runtime.model,
        feature: "import_categorization",
        status: "queued",
        input_scope: %{
          "batch_id" => batch_id,
          "row_ids" => row_ids,
          "row_count" => length(row_ids)
        },
        prompt_version: @prompt_version,
        schema_version: @schema_version
      }

      with {:ok, run} <- %SuggestionRun{} |> SuggestionRun.changeset(params) |> Repo.insert(),
           {:ok, _job} <- enqueue_categorization_run(run.id) do
        {:ok, run}
      end
    else
      false -> {:error, :no_import_rows}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec process_categorization_run(binary()) :: :ok | {:error, term()}
  def process_categorization_run(run_id) when is_binary(run_id) do
    case Repo.get(SuggestionRun, run_id) do
      nil ->
        {:error, :not_found}

      %SuggestionRun{feature: "categorization"} = run ->
        process_categorization(run)

      %SuggestionRun{feature: "import_categorization"} = run ->
        process_import_categorization(run)

      _run ->
        {:error, :unsupported_feature}
    end
  end

  @spec list_runs(User.t() | binary(), keyword()) :: [SuggestionRun.t()]
  def list_runs(user, opts \\ []) do
    feature = Keyword.get(opts, :feature)
    status = Keyword.get(opts, :status)
    limit = Keyword.get(opts, :limit, 50)

    SuggestionRun
    |> where([run], run.user_id == ^resolve_user_id(user))
    |> maybe_filter_run_feature(feature)
    |> maybe_filter_run_status(status)
    |> order_by([run], desc: run.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec fetch_run(User.t() | binary(), binary()) ::
          {:ok, SuggestionRun.t()} | {:error, :not_found}
  def fetch_run(user, run_id) when is_binary(run_id) do
    run =
      from(run in SuggestionRun,
        where: run.id == ^run_id and run.user_id == ^resolve_user_id(user)
      )
      |> Repo.one()

    case run do
      %SuggestionRun{} = value -> {:ok, value}
      nil -> {:error, :not_found}
    end
  end

  def fetch_run(_user, _run_id), do: {:error, :not_found}

  @spec list_suggestions(User.t() | binary(), keyword()) :: [Suggestion.t()]
  def list_suggestions(user, opts \\ []) do
    status = Keyword.get(opts, :status)
    run_id = Keyword.get(opts, :run_id)
    target_type = Keyword.get(opts, :target_type)
    limit = Keyword.get(opts, :limit, 100)

    Suggestion
    |> where([suggestion], suggestion.user_id == ^resolve_user_id(user))
    |> maybe_filter_suggestion_status(status)
    |> maybe_filter_suggestion_run(run_id)
    |> maybe_filter_target_type(target_type)
    |> order_by([suggestion], desc: suggestion.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec accept_suggestion(User.t() | binary(), binary()) ::
          {:ok, Suggestion.t()} | {:error, term()}
  def accept_suggestion(user, suggestion_id) when is_binary(suggestion_id) do
    with {:ok, suggestion} <- fetch_suggestion(user, suggestion_id) do
      apply_suggestion(user, suggestion, suggestion.payload, "accepted")
    end
  end

  @spec apply_edited_suggestion(User.t() | binary(), binary(), map()) ::
          {:ok, Suggestion.t()} | {:error, term()}
  def apply_edited_suggestion(user, suggestion_id, edited_payload)
      when is_binary(suggestion_id) and is_map(edited_payload) do
    with {:ok, suggestion} <- fetch_suggestion(user, suggestion_id) do
      apply_suggestion(user, suggestion, edited_payload, "edited_and_accepted")
    end
  end

  @spec reject_suggestion(User.t() | binary(), binary()) ::
          {:ok, Suggestion.t()} | {:error, term()}
  def reject_suggestion(user, suggestion_id) when is_binary(suggestion_id) do
    user_id = resolve_user_id(user)

    with {:ok, suggestion} <- fetch_suggestion(user_id, suggestion_id) do
      suggestion
      |> Suggestion.changeset(%{
        status: "rejected",
        reviewed_by_user_id: user_id,
        reviewed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })
      |> Repo.update()
    end
  end

  @spec fetch_suggestion(User.t() | binary(), binary()) ::
          {:ok, Suggestion.t()} | {:error, :not_found}
  def fetch_suggestion(user, suggestion_id) when is_binary(suggestion_id) do
    suggestion =
      from(suggestion in Suggestion,
        where: suggestion.id == ^suggestion_id and suggestion.user_id == ^resolve_user_id(user)
      )
      |> Repo.one()

    case suggestion do
      %Suggestion{} = value -> {:ok, value}
      nil -> {:error, :not_found}
    end
  end

  def fetch_suggestion(_user, _suggestion_id), do: {:error, :not_found}

  defp process_categorization(%SuggestionRun{} = run) do
    started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    runtime = runtime_settings(run.user_id, %{"provider" => run.provider, "model" => run.model})

    with :ok <- ensure_ai_enabled(runtime),
         :ok <- ensure_categorization_allowed(run.user_id),
         {:ok, running_run} <- update_run_status(run, "running", %{started_at: started_at}),
         transactions <- run_transactions(running_run),
         true <- transactions != [] or {:error, :no_transactions},
         categories <- categories_for_user(run.user_id),
         prompt <- categorization_prompt(transactions, categories),
         {:ok, response} <- provider_module(runtime.provider).generate_json(runtime, prompt, []),
         {:ok, suggestions} <- normalize_categorization_output(response, transactions, categories),
         {:ok, _} <- persist_suggestions(running_run, suggestions),
         {:ok, _} <- complete_run(running_run, started_at) do
      :ok
    else
      false ->
        fail_run(run, started_at, "no_transactions")

      {:error, reason} ->
        fail_run(run, started_at, error_code(reason))
    end
  end

  defp process_import_categorization(%SuggestionRun{} = run) do
    started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    runtime =
      run.user_id
      |> runtime_settings(%{"provider" => run.provider, "model" => run.model})
      |> ensure_min_timeout(@import_timeout_ms)

    with :ok <- ensure_ai_enabled(runtime),
         :ok <- ensure_categorization_allowed(run.user_id),
         {:ok, running_run} <- update_run_status(run, "running", %{started_at: started_at}),
         rows <- run_import_rows(running_run),
         true <- rows != [] or {:error, :no_import_rows},
         categories <- limited_prompt_categories(categories_for_user(run.user_id)),
         {:ok, response} <- generate_import_categorization_response(runtime, rows, categories),
         {:ok, suggestions} <- normalize_import_categorization_output(response, rows, categories),
         {:ok, _} <- persist_suggestions(running_run, suggestions),
         {:ok, _} <- complete_run(running_run, started_at) do
      :ok
    else
      false ->
        fail_run(run, started_at, "no_import_rows")

      {:error, reason} ->
        fail_run(run, started_at, error_code(reason))
    end
  end

  defp generate_import_categorization_response(runtime, rows, categories) do
    prompt = import_categorization_prompt(rows, categories)

    case provider_module(runtime.provider).generate_json(runtime, prompt, []) do
      {:ok, response} ->
        {:ok, response}

      {:error, :timeout} ->
        retry_import_categorization_after_timeout(runtime, rows, categories)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_import_categorization_after_timeout(runtime, rows, categories) do
    if length(rows) > @import_retry_row_limit do
      reduced_rows = Enum.take(rows, @import_retry_row_limit)
      prompt = import_categorization_prompt(reduced_rows, categories)

      provider_module(runtime.provider).generate_json(runtime, prompt, [])
    else
      {:error, :timeout}
    end
  end

  defp persist_suggestions(run, suggestions) do
    Multi.new()
    |> Multi.delete_all(
      :delete_pending,
      from(suggestion in Suggestion,
        where: suggestion.ai_suggestion_run_id == ^run.id and suggestion.status == "pending"
      )
    )
    |> insert_suggestions(run, suggestions)
    |> Repo.transaction()
    |> case do
      {:ok, _changes} -> {:ok, :persisted}
      {:error, _operation, reason, _changes} -> {:error, reason}
    end
  end

  defp insert_suggestions(multi, run, suggestions) do
    Enum.with_index(suggestions)
    |> Enum.reduce(multi, fn {suggestion, index}, acc ->
      attrs =
        suggestion
        |> Map.put(:ai_suggestion_run_id, run.id)
        |> Map.put(:user_id, run.user_id)
        |> Map.put_new(:target_type, "transaction")
        |> Map.put_new(:suggestion_type, "set_category")
        |> Map.put(:status, "pending")

      Multi.insert(acc, "suggestion_#{index}", Suggestion.changeset(%Suggestion{}, attrs))
    end)
  end

  defp complete_run(run, started_at) do
    completed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    duration_ms =
      DateTime.diff(completed_at, started_at, :millisecond)
      |> max(0)

    update_run_status(run, "completed", %{completed_at: completed_at, duration_ms: duration_ms})
  end

  defp fail_run(run, started_at, code) do
    completed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    duration_ms =
      DateTime.diff(completed_at, started_at, :millisecond)
      |> max(0)

    _ =
      update_run_status(run, "failed", %{
        completed_at: completed_at,
        duration_ms: duration_ms,
        error_code: code,
        error_message_safe: code
      })

    {:error, code}
  end

  defp normalize_categorization_output(response, transactions, categories)
       when is_map(response) do
    with {:ok, suggestions} <- extract_suggestions(response) do
      normalize_categorization_suggestions(suggestions, transactions, categories)
    end
  end

  defp normalize_categorization_output(_response, _transactions, _categories),
    do: {:error, :invalid_output}

  defp normalize_categorization_suggestions(suggestions, transactions, categories)
       when is_list(suggestions) do
    transactions_by_id = Map.new(transactions, &{&1.id, &1})
    allowed_categories = MapSet.new(categories)
    category_lookup = category_lookup(categories)

    normalized =
      suggestions
      |> Enum.flat_map(fn suggestion ->
        with %{} <- suggestion,
             tx_id when is_binary(tx_id) <- get(suggestion, "transaction_id"),
             %Transaction{} <- Map.get(transactions_by_id, tx_id),
             category when is_binary(category) <- get(suggestion, "category"),
             category when is_binary(category) <-
               resolve_allowed_category(category, category_lookup),
             true <- MapSet.member?(allowed_categories, category),
             confidence <- normalize_confidence(get(suggestion, "confidence")) do
          [
            %{
              target_id: tx_id,
              payload: %{
                "category" => category,
                "reason" => get(suggestion, "reason")
              },
              confidence: confidence,
              reason: get(suggestion, "reason"),
              evidence: %{"source" => "ollama_categorization"}
            }
          ]
        else
          _ -> []
        end
      end)

    {:ok, normalized}
  end

  defp normalize_categorization_suggestions(_suggestions, _transactions, _categories),
    do: {:error, :invalid_output}

  defp normalize_import_categorization_output(response, rows, categories) when is_map(response) do
    with {:ok, suggestions} <- extract_suggestions(response) do
      normalize_import_categorization_suggestions(suggestions, rows, categories)
    end
  end

  defp normalize_import_categorization_output(_response, _rows, _categories),
    do: {:error, :invalid_output}

  defp normalize_import_categorization_suggestions(suggestions, rows, categories)
       when is_list(suggestions) do
    rows_by_id = Map.new(rows, &{&1.id, &1})
    allowed_categories = MapSet.new(categories)
    category_lookup = category_lookup(categories)

    normalized =
      suggestions
      |> Enum.flat_map(fn suggestion ->
        with %{} <- suggestion,
             row_id when is_binary(row_id) <- get(suggestion, "row_id"),
             %ManualImportRow{} <- Map.get(rows_by_id, row_id),
             category when is_binary(category) <- get(suggestion, "category"),
             category when is_binary(category) <-
               resolve_allowed_category(category, category_lookup),
             true <- MapSet.member?(allowed_categories, category),
             confidence <- normalize_confidence(get(suggestion, "confidence")) do
          [
            %{
              target_id: row_id,
              target_type: "manual_import_row",
              suggestion_type: "set_import_row_category",
              payload: %{
                "category" => category,
                "reason" => get(suggestion, "reason")
              },
              confidence: confidence,
              reason: get(suggestion, "reason"),
              evidence: %{"source" => "ollama_import_categorization"}
            }
          ]
        else
          _ -> []
        end
      end)

    {:ok, normalized}
  end

  defp normalize_import_categorization_suggestions(_suggestions, _rows, _categories),
    do: {:error, :invalid_output}

  defp normalize_loan_document_extraction_output(response) when is_map(response) do
    payload =
      response
      |> first_map_value(["fields", "extracted_payload", "payload"])
      |> normalize_loan_document_payload()

    if payload == %{} do
      {:error, :no_extracted_fields}
    else
      {:ok,
       %{
         extracted_payload: payload,
         field_confidence:
           response
           |> first_map_value(["confidence", "field_confidence", "confidences"])
           |> normalize_field_confidence(Map.keys(payload)),
         source_citations:
           response
           |> first_map_value(["citations", "source_citations", "evidence"])
           |> normalize_source_citations(Map.keys(payload))
       }}
    end
  end

  defp normalize_loan_document_extraction_output(_response), do: {:error, :invalid_output}

  defp normalize_loan_document_payload(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, value}, acc ->
      field = normalize_loan_document_field(key)

      if field in @loan_document_extraction_fields and not blank_value?(value) do
        Map.put(acc, field, normalize_document_field_value(field, value))
      else
        acc
      end
    end)
  end

  defp normalize_loan_document_payload(_value), do: %{}

  defp normalize_field_confidence(value, fields) when is_map(value) do
    fields = MapSet.new(fields)

    Enum.reduce(value, %{}, fn {key, value}, acc ->
      field = normalize_loan_document_field(key)

      if MapSet.member?(fields, field) do
        case normalize_confidence(value) do
          nil -> acc
          confidence -> Map.put(acc, field, Decimal.to_float(confidence))
        end
      else
        acc
      end
    end)
  end

  defp normalize_field_confidence(_value, _fields), do: %{}

  defp normalize_source_citations(value, fields) when is_map(value) do
    fields = MapSet.new(fields)

    Enum.reduce(value, %{}, fn {key, value}, acc ->
      field = normalize_loan_document_field(key)

      if MapSet.member?(fields, field) do
        Map.put(acc, field, normalize_citation_value(value))
      else
        acc
      end
    end)
  end

  defp normalize_source_citations(_value, _fields), do: %{}

  defp normalize_citation_value(value) when is_list(value) do
    value
    |> Enum.map(&normalize_citation_item/1)
    |> Enum.reject(&(&1 == %{}))
  end

  defp normalize_citation_value(value), do: normalize_citation_value([value])

  defp normalize_citation_item(value) when is_binary(value),
    do: %{"text" => String.slice(value, 0, 500)}

  defp normalize_citation_item(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, value}, acc ->
      key = to_string(key)

      if key in ["text", "page", "label"] and not blank_value?(value) do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  defp normalize_citation_item(_value), do: %{}

  defp normalize_loan_document_field(key) do
    key
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s-]+/, "_")
    |> loan_document_field_alias()
  end

  defp loan_document_field_alias("interest_rate"), do: "current_interest_rate"
  defp loan_document_field_alias("principal_balance"), do: "current_balance"
  defp loan_document_field_alias("unpaid_principal_balance"), do: "current_balance"
  defp loan_document_field_alias("monthly_payment"), do: "monthly_payment_total"
  defp loan_document_field_alias("pmi_mip_monthly"), do: "pmi_monthly"
  defp loan_document_field_alias("new_term_months"), do: "term_months"
  defp loan_document_field_alias("new_interest_rate"), do: "interest_rate"
  defp loan_document_field_alias("closing_costs"), do: "estimated_closing_costs_expected"
  defp loan_document_field_alias("cash_to_close"), do: "estimated_cash_to_close_expected"
  defp loan_document_field_alias("new_monthly_payment"), do: "estimated_monthly_payment_expected"
  defp loan_document_field_alias(field), do: field

  defp normalize_document_field_value(field, value)
       when field in ["remaining_term_months", "original_term_months"] do
    case value do
      value when is_integer(value) -> value
      value when is_binary(value) -> String.trim(value)
      value -> value
    end
  end

  defp normalize_document_field_value(_field, value) when is_binary(value), do: String.trim(value)
  defp normalize_document_field_value(_field, value), do: value

  defp first_map_value(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case get(map, key) do
        value when is_map(value) -> value
        _ -> nil
      end
    end) || %{}
  end

  defp normalize_document_text(text) when is_binary(text) do
    text =
      text
      |> String.trim()
      |> String.slice(0, @loan_document_text_max_chars)

    if text == "", do: {:error, :empty_text}, else: {:ok, text}
  end

  defp blank_value?(nil), do: true
  defp blank_value?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_value?(_value), do: false

  defp normalize_confidence(nil), do: nil

  defp normalize_confidence(value) do
    case Decimal.cast(value) do
      {:ok, decimal} ->
        min = Decimal.new("0")
        max = Decimal.new("1")

        cond do
          Decimal.compare(decimal, min) == :lt -> min
          Decimal.compare(decimal, max) == :gt -> max
          true -> decimal
        end

      :error ->
        nil
    end
  end

  defp categorization_prompt(transactions, categories) do
    transactions_payload =
      Enum.map(transactions, fn transaction ->
        %{
          transaction_id: transaction.id,
          posted_at: transaction.posted_at,
          amount: transaction.amount,
          description: transaction.description,
          merchant_name: transaction.merchant_name,
          account_type: transaction.account.type,
          direction: transaction_direction(transaction.amount)
        }
      end)

    Jason.encode!(%{
      instructions: [
        "You are a personal finance categorization assistant.",
        "Return JSON only with shape {\"suggestions\":[...]}",
        "Only use categories from allowed_categories.",
        "Do not invent transaction ids.",
        "Confidence must be between 0 and 1."
      ],
      allowed_categories: categories,
      transactions: transactions_payload,
      output_schema: %{
        suggestions: [
          %{
            transaction_id: "transaction_id",
            category: "allowed_category",
            confidence: 0.0,
            reason: "brief reason"
          }
        ]
      }
    })
  end

  defp import_categorization_prompt(rows, categories) do
    rows_payload =
      Enum.map(rows, fn row ->
        %{
          row_id: row.id,
          row_index: row.row_index,
          posted_at: row.posted_at,
          amount: row.amount,
          description: trim_prompt_text(row.description),
          merchant_name: trim_prompt_text(row.merchant_name),
          direction: trim_prompt_text(row.direction)
        }
      end)

    Jason.encode!(%{
      instructions: [
        "You are a personal finance import categorization assistant.",
        "Return JSON only with shape {\"suggestions\":[...]}",
        "Only use categories from allowed_categories.",
        "Do not invent row ids.",
        "Confidence must be between 0 and 1."
      ],
      allowed_categories: categories,
      rows: rows_payload,
      output_schema: %{
        suggestions: [
          %{
            row_id: "row_id",
            category: "allowed_category",
            confidence: 0.0,
            reason: "brief reason"
          }
        ]
      }
    })
  end

  defp loan_document_extraction_prompt(text, opts) do
    Jason.encode!(%{
      instructions: [
        "You extract mortgage document fields for user review.",
        "Return JSON only with shape {\"fields\":{},\"confidence\":{},\"citations\":{}}.",
        "Only include fields that are explicitly supported by the document text.",
        "Do not calculate, estimate, or infer missing financial values.",
        "Use decimal strings for money and rates. Use ISO-8601 dates when dates are present.",
        "Confidence values must be between 0 and 1.",
        "Citations should include short source snippets from the document text."
      ],
      document_type: get(opts, "document_type"),
      supported_fields: @loan_document_extraction_fields,
      field_aliases: %{
        interest_rate: "current_interest_rate",
        principal_balance: "current_balance",
        unpaid_principal_balance: "current_balance",
        monthly_payment: "monthly_payment_total",
        pmi_mip_monthly: "pmi_monthly"
      },
      loan_document_text: text,
      output_schema: %{
        fields: %{
          current_balance: "decimal string",
          current_interest_rate: "decimal rate, such as 0.0575",
          remaining_term_months: "integer",
          monthly_payment_total: "decimal string"
        },
        confidence: %{
          current_balance: 0.0
        },
        citations: %{
          current_balance: [
            %{
              text: "short supporting source snippet",
              page: "page number when known"
            }
          ]
        }
      }
    })
  end

  defp transaction_direction(amount) do
    case Decimal.cast(amount) do
      {:ok, decimal} ->
        cond do
          Decimal.compare(decimal, Decimal.new("0")) == :lt -> "expense"
          Decimal.compare(decimal, Decimal.new("0")) == :gt -> "income"
          true -> "neutral"
        end

      _ ->
        "neutral"
    end
  end

  defp run_transactions(%SuggestionRun{} = run) do
    ids = get(run.input_scope || %{}, "transaction_ids") || []

    from(transaction in Transaction,
      join: account in assoc(transaction, :account),
      where: transaction.id in ^ids and transaction.account_id == account.id,
      preload: [account: account]
    )
    |> Repo.all()
  end

  defp run_import_rows(%SuggestionRun{} = run) do
    scope = run.input_scope || %{}
    row_ids = get(scope, "row_ids") || []
    batch_id = get(scope, "batch_id")

    query =
      from(row in ManualImportRow,
        join: batch in assoc(row, :manual_import_batch),
        where: batch.user_id == ^run.user_id,
        where: row.id in ^row_ids
      )

    query =
      if is_binary(batch_id) do
        where(query, [row], row.manual_import_batch_id == ^batch_id)
      else
        query
      end

    query
    |> order_by([row], asc: row.row_index)
    |> Repo.all()
  end

  defp categories_for_user(user_id) do
    transaction_categories =
      from(transaction in Transaction,
        join: account in subquery(Accounts.accessible_accounts_query(user_id)),
        on: transaction.account_id == account.id,
        where: not is_nil(transaction.category),
        select: transaction.category,
        distinct: true
      )
      |> Repo.all()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    (transaction_categories ++ @default_categories)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp enqueue_categorization_run(run_id) do
    %{run_id: run_id}
    |> CategorizationWorker.new()
    |> Oban.insert()
  end

  defp apply_suggestion(user, suggestion, payload, status) when is_map(payload) do
    user_id = resolve_user_id(user)

    with :ok <- ensure_pending_or_reviewable(suggestion),
         category when is_binary(category) and category != "" <- get(payload, "category"),
         :ok <- apply_category_target(user_id, suggestion, category) do
      suggestion
      |> Suggestion.changeset(%{
        status: status,
        approved_payload: payload,
        reviewed_by_user_id: user_id,
        reviewed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        applied_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })
      |> Repo.update()
    else
      {:error, reason} ->
        mark_failed_suggestion(suggestion, user_id, reason)

      _ ->
        mark_failed_suggestion(suggestion, user_id, :invalid_payload)
    end
  end

  defp mark_failed_suggestion(suggestion, user_id, _reason) do
    suggestion
    |> Suggestion.changeset(%{
      status: "failed_to_apply",
      reviewed_by_user_id: user_id,
      reviewed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update()
  end

  defp ensure_pending_or_reviewable(%Suggestion{status: status})
       when status in ["pending", "failed_to_apply"],
       do: :ok

  defp ensure_pending_or_reviewable(_suggestion), do: {:error, :invalid_status}

  defp apply_category_target(user_id, %Suggestion{} = suggestion, category) do
    case {suggestion.target_type, suggestion.suggestion_type} do
      {"transaction", "set_category"} ->
        with {:ok, transaction} <- fetch_accessible_transaction(user_id, suggestion.target_id),
             {:ok, _updated_tx} <-
               update_transaction_category(transaction, category, suggestion.confidence) do
          :ok
        end

      {"manual_import_row", "set_import_row_category"} ->
        with {:ok, row} <- fetch_accessible_import_row(user_id, suggestion.target_id),
             {:ok, _updated_row} <-
               update_import_row_category(row, category, suggestion.confidence) do
          :ok
        end

      _ ->
        {:error, :unsupported_suggestion_type}
    end
  end

  defp update_transaction_category(%Transaction{} = transaction, category, confidence) do
    transaction
    |> Transaction.changeset(%{
      category: category,
      categorization_source: "model",
      categorization_confidence: confidence
    })
    |> Repo.update()
  end

  defp fetch_accessible_transaction(user, transaction_id)
       when is_binary(user) and is_binary(transaction_id) do
    transaction =
      from(transaction in Transaction,
        join: account in subquery(Accounts.accessible_accounts_query(user)),
        on: transaction.account_id == account.id,
        where: transaction.id == ^transaction_id
      )
      |> Repo.one()

    case transaction do
      %Transaction{} = value -> {:ok, value}
      nil -> {:error, :not_found}
    end
  end

  defp fetch_accessible_transaction(_user, _transaction_id), do: {:error, :not_found}

  defp update_import_row_category(%ManualImportRow{} = row, category, _confidence) do
    row
    |> ManualImportRow.changeset(%{
      category_name_snapshot: category
    })
    |> Repo.update()
  end

  defp fetch_accessible_import_row(user_id, row_id)
       when is_binary(user_id) and is_binary(row_id) do
    row =
      from(row in ManualImportRow,
        join: batch in assoc(row, :manual_import_batch),
        where: row.id == ^row_id and batch.user_id == ^user_id
      )
      |> Repo.one()

    case row do
      %ManualImportRow{} = value -> {:ok, value}
      nil -> {:error, :not_found}
    end
  end

  defp fetch_accessible_import_row(_user_id, _row_id), do: {:error, :not_found}

  defp candidate_transactions(user_id, opts) do
    limit =
      get(opts, "limit") ||
        Config.max_input_transactions()
        |> normalize_limit()

    from(transaction in Transaction,
      join: account in subquery(Accounts.accessible_accounts_query(user_id)),
      on: transaction.account_id == account.id,
      where: is_nil(transaction.category) or transaction.category == "Uncategorized",
      where: transaction.status == "posted",
      order_by: [desc: transaction.posted_at, desc: transaction.inserted_at],
      preload: [account: account],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp candidate_import_rows(user_id, batch_id, opts)
       when is_binary(user_id) and is_binary(batch_id) and is_map(opts) do
    limit =
      get(opts, "limit") ||
        Config.max_input_transactions()
        |> normalize_limit()

    from(row in ManualImportRow,
      join: batch in assoc(row, :manual_import_batch),
      where: batch.user_id == ^user_id,
      where: row.manual_import_batch_id == ^batch_id,
      where: row.parse_status in ["parsed", "warning"],
      where: row.review_decision == "accept",
      where:
        is_nil(row.category_name_snapshot) or row.category_name_snapshot == "" or
          row.category_name_snapshot == "Uncategorized",
      order_by: [asc: row.row_index],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp candidate_import_rows(_user_id, _batch_id, _opts), do: []

  defp ensure_ai_enabled(runtime) do
    if runtime.local_ai_enabled, do: :ok, else: {:error, :disabled_for_user}
  end

  defp ensure_categorization_allowed(user_id) do
    preference = get_or_build_preference(user_id)

    if preference.allow_ai_for_categorization do
      :ok
    else
      {:error, :categorization_disabled}
    end
  end

  defp runtime_settings(user, overrides \\ %{}) do
    snapshot = settings_snapshot(user)

    provider = get(overrides, "provider") || snapshot.provider
    default_provider_settings = Config.provider_settings(provider)

    %{
      provider: provider,
      local_ai_enabled: snapshot.local_ai_enabled,
      model: get(overrides, "model") || snapshot.default_model || default_provider_settings.model,
      base_url:
        get(overrides, "base_url") || snapshot.ollama_base_url ||
          default_provider_settings.base_url,
      timeout_ms: default_provider_settings.timeout_ms
    }
  end

  defp provider_module(provider), do: Config.provider_module(provider)

  defp get_or_build_preference(user) do
    user_id = resolve_user_id(user)

    Repo.get_by(UserPreference, user_id: user_id) ||
      %UserPreference{
        user_id: user_id,
        provider: Config.default_provider(),
        local_ai_enabled: false
      }
  end

  defp update_run_status(%SuggestionRun{} = run, status, attrs) do
    run
    |> SuggestionRun.changeset(Map.put(attrs, :status, status))
    |> Repo.update()
  end

  defp maybe_filter_run_feature(query, nil), do: query
  defp maybe_filter_run_feature(query, feature), do: where(query, [run], run.feature == ^feature)

  defp maybe_filter_run_status(query, nil), do: query
  defp maybe_filter_run_status(query, status), do: where(query, [run], run.status == ^status)

  defp maybe_filter_suggestion_status(query, nil), do: query

  defp maybe_filter_suggestion_status(query, status),
    do: where(query, [suggestion], suggestion.status == ^status)

  defp maybe_filter_suggestion_run(query, nil), do: query

  defp maybe_filter_suggestion_run(query, run_id),
    do: where(query, [suggestion], suggestion.ai_suggestion_run_id == ^run_id)

  defp maybe_filter_target_type(query, nil), do: query

  defp maybe_filter_target_type(query, target_type),
    do: where(query, [suggestion], suggestion.target_type == ^target_type)

  defp resolve_user_id(%User{id: user_id}), do: user_id
  defp resolve_user_id(user_id) when is_binary(user_id), do: user_id

  defp error_code({:http_error, status}), do: "http_#{status}"
  defp error_code({:transport_error, _reason}), do: "transport_error"
  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "unknown_error"

  defp get(map, key) when is_map(map) and is_binary(key),
    do: Map.get(map, key)

  defp get(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp stringify_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      normalized_key =
        case key do
          atom when is_atom(atom) -> Atom.to_string(atom)
          other -> other
        end

      Map.put(acc, normalized_key, value)
    end)
  end

  defp normalize_settings_aliases(attrs) do
    attrs
    |> maybe_copy_alias("base_url", "ollama_base_url")
    |> maybe_copy_alias("model", "default_model")
  end

  defp maybe_copy_alias(attrs, source, target) do
    case Map.get(attrs, source) do
      nil -> attrs
      value -> Map.put_new(attrs, target, value)
    end
  end

  defp normalize_limit(value) when is_integer(value) and value > 0, do: value

  defp normalize_limit(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _rest} when parsed > 0 -> parsed
      _ -> Config.max_input_transactions()
    end
  end

  defp normalize_limit(_value), do: Config.max_input_transactions()

  defp ensure_min_timeout(runtime, min_timeout_ms)
       when is_map(runtime) and is_integer(min_timeout_ms) do
    current_timeout = Map.get(runtime, :timeout_ms, min_timeout_ms)

    if is_integer(current_timeout) and current_timeout >= min_timeout_ms do
      runtime
    else
      Map.put(runtime, :timeout_ms, min_timeout_ms)
    end
  end

  defp ensure_min_timeout(runtime, _min_timeout_ms), do: runtime

  defp limited_prompt_categories(categories) when is_list(categories) do
    categories
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(@import_prompt_category_limit)
  end

  defp limited_prompt_categories(_categories), do: @default_categories

  defp trim_prompt_text(nil), do: nil

  defp trim_prompt_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, @import_prompt_text_max_chars)
  end

  defp trim_prompt_text(value), do: value |> to_string() |> trim_prompt_text()

  defp extract_suggestions(response) when is_list(response), do: {:ok, response}

  defp extract_suggestions(response) when is_map(response) do
    case extract_suggestions_from_map(response) do
      {:ok, suggestions} ->
        {:ok, suggestions}

      :error ->
        response
        |> extract_json_candidate()
        |> case do
          {:ok, decoded} -> extract_suggestions(decoded)
          :error -> {:error, :invalid_output}
        end
    end
  end

  defp extract_suggestions(response) when is_binary(response) do
    case extract_json_candidate(response) do
      {:ok, decoded} -> extract_suggestions(decoded)
      :error -> {:error, :invalid_output}
    end
  end

  defp extract_suggestions(_response), do: {:error, :invalid_output}

  defp extract_suggestions_from_map(response) when is_map(response) do
    direct_keys = [
      "suggestions",
      "results",
      "items",
      "predictions",
      "recommendations",
      "hints",
      "categorizations"
    ]

    container_keys = [
      "data",
      "output",
      "result",
      "message",
      "payload",
      "response"
    ]

    single_item_keys = ["suggestion", "item"]

    direct_match =
      Enum.find_value(direct_keys, fn key ->
        value = get(response, key)
        if is_list(value), do: {:ok, value}, else: nil
      end)

    nested_match =
      Enum.find_value(container_keys, fn key ->
        case get(response, key) do
          value when is_map(value) -> extract_suggestions_from_map(value)
          value when is_list(value) -> {:ok, value}
          _ -> nil
        end
      end)

    single_match =
      Enum.find_value(single_item_keys, fn key ->
        case get(response, key) do
          value when is_map(value) -> {:ok, [value]}
          _ -> nil
        end
      end)

    direct_match || nested_match || single_match || :error
  end

  defp extract_json_candidate(value) when is_map(value) do
    text_keys = ["response", "content", "text", "message"]

    Enum.find_value(text_keys, :error, fn key ->
      case get(value, key) do
        text when is_binary(text) -> parse_json_like(text)
        _ -> nil
      end
    end)
  end

  defp extract_json_candidate(value) when is_binary(value), do: parse_json_like(value)
  defp extract_json_candidate(_value), do: :error

  defp parse_json_like(text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" ->
        :error

      true ->
        case Jason.decode(trimmed) do
          {:ok, decoded} ->
            {:ok, decoded}

          {:error, _reason} ->
            with {:ok, extracted} <- decode_fenced_or_embedded_json(trimmed) do
              {:ok, extracted}
            else
              _ -> :error
            end
        end
    end
  end

  defp decode_fenced_or_embedded_json(text) when is_binary(text) do
    code_fence =
      Regex.run(~r/```(?:json)?\s*(\{[\s\S]*\}|\[[\s\S]*\])\s*```/i, text,
        capture: :all_but_first
      )

    candidates =
      case code_fence do
        [candidate] ->
          [candidate]

        _ ->
          [
            substring_between(text, "{", "}"),
            substring_between(text, "[", "]")
          ]
          |> Enum.reject(&is_nil/1)
      end

    Enum.find_value(candidates, {:error, :invalid_json}, fn candidate ->
      case Jason.decode(candidate) do
        {:ok, decoded} -> {:ok, decoded}
        {:error, _reason} -> nil
      end
    end)
  end

  defp substring_between(text, start_token, end_token)
       when is_binary(text) and is_binary(start_token) and is_binary(end_token) do
    start_index =
      case :binary.match(text, start_token) do
        {index, _length} -> index
        :nomatch -> nil
      end

    end_index =
      text
      |> :binary.matches(end_token)
      |> List.last()
      |> case do
        {index, _length} -> index
        nil -> nil
      end

    cond do
      is_nil(start_index) or is_nil(end_index) ->
        nil

      end_index < start_index ->
        nil

      true ->
        String.slice(text, start_index, end_index - start_index + String.length(end_token))
    end
  end

  defp category_lookup(categories) when is_list(categories) do
    Enum.reduce(categories, %{}, fn category, acc ->
      Map.put(acc, normalize_category_key(category), category)
    end)
  end

  defp resolve_allowed_category(category, lookup) when is_binary(category) and is_map(lookup) do
    normalized = normalize_category_key(category)

    Map.get(lookup, normalized) ||
      lookup
      |> Enum.find_value(fn {key, value} ->
        if String.contains?(key, normalized) or String.contains?(normalized, key),
          do: value,
          else: nil
      end)
  end

  defp resolve_allowed_category(_category, _lookup), do: nil

  defp normalize_category_key(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, " ")
    |> String.trim()
  end
end
