defmodule MoneyTree.Loans do
  @moduledoc """
  Loan portfolio helpers used by the Phoenix LiveView dashboard.
  """

  import Ecto.Query, warn: false

  alias Decimal
  alias Ecto.Multi
  alias MoneyTree.Accounts
  alias MoneyTree.AI
  alias MoneyTree.Loans.AlertRule
  alias MoneyTree.Loans.LenderQuote
  alias MoneyTree.Loans.LoanDocument
  alias MoneyTree.Loans.LoanDocumentExtraction
  alias MoneyTree.Loans.RateObservation
  alias MoneyTree.Loans.RateSource
  alias MoneyTree.Loans.Workers.AlertEvaluationWorker
  alias MoneyTree.Loans.Workers.DocumentExtractionWorker
  alias MoneyTree.Loans.Workers.RateImportWorker
  alias MoneyTree.Notifications
  alias MoneyTree.Loans.RefinanceAnalysisResult
  alias MoneyTree.Loans.RefinanceCalculator
  alias MoneyTree.Loans.RefinanceFeeItem
  alias MoneyTree.Loans.RefinanceScenario
  alias MoneyTree.Mortgages
  alias MoneyTree.Mortgages.Mortgage
  alias MoneyTree.Repo
  alias MoneyTree.Transactions
  alias MoneyTree.Users.User

  @type autopay_info :: %{
          enabled?: boolean(),
          cadence: :monthly,
          funding_account: String.t(),
          next_run_on: Date.t(),
          payment_amount: String.t(),
          payment_amount_masked: String.t()
        }

  @type loan_overview :: %{
          account: map(),
          current_balance: String.t(),
          current_balance_masked: String.t(),
          next_due_date: Date.t(),
          autopay: autopay_info(),
          last_payment: String.t(),
          last_payment_masked: String.t()
        }

  @default_refinance_preload [:mortgage, :fee_items]
  @analysis_version "2026-05-06-v1"
  @readable_document_content_types ~w(text/plain text/markdown text/csv application/pdf image/png image/jpeg)
  @readable_document_extensions ~w(.txt .md .csv .pdf .png .jpg .jpeg)
  @mortgage_extraction_fields ~w(
    current_balance
    current_interest_rate
    remaining_term_months
    monthly_payment_total
    monthly_principal_interest
    original_loan_amount
    original_interest_rate
    original_term_months
    servicer_name
    lender_name
    home_value_estimate
    pmi_mip_monthly
    hoa_monthly
    flood_insurance_monthly
  )
  @lender_quote_extraction_fields ~w(
    lender_name
    quote_source
    quote_reference
    loan_type
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
    lock_available
    lock_expires_at
    quote_expires_at
    status
  )
  @refinance_scenario_extraction_fields ~w(
    product_type
    new_term_months
    new_interest_rate
    new_apr
    new_principal_amount
    cash_out_amount
    cash_in_amount
    roll_costs_into_loan
    points
    lender_credit_amount
    expected_years_before_sale_or_refi
    closing_date_assumption
  )
  @default_alert_preload [:mortgage]

  @doc """
  Returns human-friendly loan summaries, including autopay details.
  """
  @spec overview(User.t() | binary(), keyword()) :: [loan_overview()]
  def overview(user, opts \\ []) do
    lookback_days = Keyword.get(opts, :lookback_days, 45)
    funding_account = Keyword.get(opts, :default_funding_account, "Primary Checking")

    Accounts.list_accessible_accounts(user, preload: Keyword.get(opts, :preload, []))
    |> Enum.filter(&loan_account?/1)
    |> Enum.map(fn account ->
      balance_decimal = normalize_decimal(account.current_balance)
      currency = account.currency || "USD"

      autopay = autopay_details(account, funding_account, opts)
      next_due_date = autopay.next_run_on

      recent_activity = Transactions.net_activity_for_account(account, days: lookback_days)
      last_payment = Decimal.abs(recent_activity)

      %{
        account: %{
          id: account.id,
          name: account.name,
          currency: currency,
          type: account.type
        },
        current_balance: Accounts.format_money(balance_decimal, currency, opts),
        current_balance_masked: Accounts.mask_money(balance_decimal, currency, opts),
        next_due_date: next_due_date,
        autopay: autopay,
        last_payment: Accounts.format_money(last_payment, currency, opts),
        last_payment_masked: Accounts.mask_money(last_payment, currency, opts)
      }
    end)
  end

  @doc """
  Lists refinance scenarios for a mortgage owned by the user.
  """
  @spec list_refinance_scenarios(User.t() | binary(), Mortgage.t() | binary(), keyword()) :: [
          RefinanceScenario.t()
        ]
  def list_refinance_scenarios(user, mortgage_or_id, opts \\ []) do
    mortgage_id = normalize_id(mortgage_or_id)
    preload = Keyword.get(opts, :preload, @default_refinance_preload)

    RefinanceScenario
    |> where(
      [scenario],
      scenario.user_id == ^normalize_user_id(user) and scenario.mortgage_id == ^mortgage_id
    )
    |> order_by([scenario], desc: scenario.updated_at)
    |> maybe_preload_query(preload)
    |> Repo.all()
  end

  @doc """
  Fetches a refinance scenario scoped to the user.
  """
  @spec fetch_refinance_scenario(User.t() | binary(), binary(), keyword()) ::
          {:ok, RefinanceScenario.t()} | {:error, :not_found}
  def fetch_refinance_scenario(user, scenario_id, opts \\ [])

  def fetch_refinance_scenario(user, scenario_id, opts) when is_binary(scenario_id) do
    preload = Keyword.get(opts, :preload, @default_refinance_preload)

    case Ecto.UUID.cast(scenario_id) do
      {:ok, id} ->
        RefinanceScenario
        |> where(
          [scenario],
          scenario.id == ^id and scenario.user_id == ^normalize_user_id(user)
        )
        |> maybe_preload_query(preload)
        |> Repo.one()
        |> case do
          nil -> {:error, :not_found}
          %RefinanceScenario{} = scenario -> {:ok, scenario}
        end

      :error ->
        {:error, :not_found}
    end
  end

  def fetch_refinance_scenario(_user, _scenario_id, _opts), do: {:error, :not_found}

  @doc """
  Creates a mortgage-backed refinance scenario scoped to the current user.
  """
  @spec create_refinance_scenario(User.t() | binary(), Mortgage.t() | binary(), map(), keyword()) ::
          {:ok, RefinanceScenario.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def create_refinance_scenario(user, mortgage_or_id, attrs, opts \\ []) when is_map(attrs) do
    preload = Keyword.get(opts, :preload, @default_refinance_preload)

    with {:ok, mortgage} <- Mortgages.fetch_mortgage(user, normalize_id(mortgage_or_id)),
         changeset <-
           RefinanceScenario.changeset(
             %RefinanceScenario{},
             attrs
             |> normalize_attr_map()
             |> Map.put("user_id", normalize_user_id(user))
             |> Map.put("mortgage_id", mortgage.id)
           ),
         {:ok, scenario} <- Repo.insert(changeset) do
      {:ok, Repo.preload(scenario, preload)}
    end
  end

  @doc """
  Updates a refinance scenario owned by the current user.
  """
  @spec update_refinance_scenario(
          User.t() | binary(),
          RefinanceScenario.t() | binary(),
          map(),
          keyword()
        ) ::
          {:ok, RefinanceScenario.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def update_refinance_scenario(user, scenario_or_id, attrs, opts \\ [])

  def update_refinance_scenario(user, %RefinanceScenario{} = scenario, attrs, opts)
      when is_map(attrs) do
    preload = Keyword.get(opts, :preload, @default_refinance_preload)

    if scenario.user_id == normalize_user_id(user) do
      scenario
      |> RefinanceScenario.changeset(normalize_attr_map(attrs))
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, Repo.preload(updated, preload)}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:error, :not_found}
    end
  end

  def update_refinance_scenario(user, scenario_id, attrs, opts)
      when is_binary(scenario_id) and is_map(attrs) do
    with {:ok, scenario} <- fetch_refinance_scenario(user, scenario_id, preload: []),
         {:ok, updated} <- update_refinance_scenario(user, scenario, attrs, opts) do
      {:ok, updated}
    end
  end

  @doc """
  Deletes a refinance scenario owned by the current user.
  """
  @spec delete_refinance_scenario(User.t() | binary(), RefinanceScenario.t() | binary()) ::
          {:ok, RefinanceScenario.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}
  def delete_refinance_scenario(user, %RefinanceScenario{} = scenario) do
    if scenario.user_id == normalize_user_id(user) do
      Repo.delete(scenario)
    else
      {:error, :not_found}
    end
  end

  def delete_refinance_scenario(user, scenario_id) when is_binary(scenario_id) do
    with {:ok, scenario} <- fetch_refinance_scenario(user, scenario_id, preload: []) do
      delete_refinance_scenario(user, scenario)
    end
  end

  @doc """
  Adds a fee or cash-flow timing item to a refinance scenario.
  """
  @spec create_refinance_fee_item(
          User.t() | binary(),
          RefinanceScenario.t() | binary(),
          map(),
          keyword()
        ) ::
          {:ok, RefinanceFeeItem.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def create_refinance_fee_item(user, scenario_or_id, attrs, opts \\ []) when is_map(attrs) do
    preload = Keyword.get(opts, :preload, [])

    with {:ok, scenario} <- fetch_scenario_for_child_write(user, scenario_or_id),
         changeset <-
           RefinanceFeeItem.changeset(
             %RefinanceFeeItem{},
             attrs
             |> normalize_attr_map()
             |> Map.put("refinance_scenario_id", scenario.id)
           ),
         {:ok, fee_item} <- Repo.insert(changeset) do
      {:ok, Repo.preload(fee_item, preload)}
    end
  end

  @doc """
  Runs deterministic analysis for a stored refinance scenario and saves a snapshot.
  """
  @spec analyze_refinance_scenario(User.t() | binary(), RefinanceScenario.t() | binary()) ::
          {:ok, RefinanceAnalysisResult.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def analyze_refinance_scenario(user, scenario_or_id) do
    with {:ok, scenario} <- fetch_scenario_for_analysis(user, scenario_or_id) do
      true_refinance_cost = sum_fee_items(scenario.fee_items, :true_cost)
      cash_to_close_timing_cost = sum_fee_items(scenario.fee_items, :timing_cost)

      analysis =
        RefinanceCalculator.analyze(%{
          current_principal: scenario.mortgage.current_balance,
          current_rate: scenario.mortgage.current_interest_rate,
          current_remaining_term_months: scenario.mortgage.remaining_term_months,
          current_monthly_payment: scenario.mortgage.monthly_payment_total,
          new_principal: scenario.new_principal_amount,
          new_rate: scenario.new_interest_rate,
          new_term_months: scenario.new_term_months,
          true_refinance_cost: true_refinance_cost,
          cash_to_close_timing_cost: cash_to_close_timing_cost
        })

      attrs =
        analysis_result_attrs(
          user,
          scenario,
          analysis,
          true_refinance_cost,
          cash_to_close_timing_cost
        )

      %RefinanceAnalysisResult{}
      |> RefinanceAnalysisResult.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Lists deterministic refinance analysis snapshots scoped to the current user.
  """
  @spec list_refinance_analysis_results(User.t() | binary(), keyword()) :: [
          RefinanceAnalysisResult.t()
        ]
  def list_refinance_analysis_results(user, opts \\ []) do
    limit = Keyword.get(opts, :limit)

    RefinanceAnalysisResult
    |> where([result], result.user_id == ^normalize_user_id(user))
    |> maybe_filter_result_mortgage(opts)
    |> maybe_filter_result_scenario(opts)
    |> order_by([result], desc: result.computed_at)
    |> maybe_limit(limit)
    |> Repo.all()
  end

  @doc """
  Lists configured loan rate sources.
  """
  @spec list_rate_sources(keyword()) :: [RateSource.t()]
  def list_rate_sources(opts \\ []) do
    preload = Keyword.get(opts, :preload, [])

    RateSource
    |> order_by([source], asc: source.name)
    |> maybe_filter_rate_source_enabled(opts)
    |> maybe_preload_query(preload)
    |> Repo.all()
  end

  @doc """
  Fetches a loan rate source by id.
  """
  @spec fetch_rate_source(RateSource.t() | binary(), keyword()) ::
          {:ok, RateSource.t()} | {:error, :not_found}
  def fetch_rate_source(source_or_id, opts \\ [])

  def fetch_rate_source(%RateSource{id: id}, opts), do: fetch_rate_source(id, opts)

  def fetch_rate_source(source_id, opts) when is_binary(source_id) do
    preload = Keyword.get(opts, :preload, [])

    case Ecto.UUID.cast(source_id) do
      {:ok, id} ->
        RateSource
        |> where([source], source.id == ^id)
        |> maybe_preload_query(preload)
        |> Repo.one()
        |> case do
          nil -> {:error, :not_found}
          %RateSource{} = source -> {:ok, source}
        end

      :error ->
        {:error, :not_found}
    end
  end

  def fetch_rate_source(_source_id, _opts), do: {:error, :not_found}

  @doc """
  Creates a configured loan rate source.
  """
  @spec create_rate_source(map(), keyword()) ::
          {:ok, RateSource.t()} | {:error, Ecto.Changeset.t()}
  def create_rate_source(attrs, opts \\ []) when is_map(attrs) do
    preload = Keyword.get(opts, :preload, [])

    %RateSource{}
    |> RateSource.changeset(normalize_attr_map(attrs))
    |> Repo.insert()
    |> case do
      {:ok, source} -> {:ok, Repo.preload(source, preload)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Creates or returns the built-in manual rate source.
  """
  @spec get_or_create_manual_rate_source(keyword()) ::
          {:ok, RateSource.t()} | {:error, Ecto.Changeset.t()}
  def get_or_create_manual_rate_source(opts \\ []) do
    preload = Keyword.get(opts, :preload, [])

    RateSource
    |> where([source], source.provider_key == "manual")
    |> maybe_preload_query(preload)
    |> Repo.one()
    |> case do
      %RateSource{} = source ->
        {:ok, source}

      nil ->
        create_rate_source(
          %{
            provider_key: "manual",
            name: "Manual rate entry",
            source_type: "manual",
            enabled: true,
            requires_api_key: false,
            config: %{}
          },
          preload: preload
        )
    end
  end

  @doc """
  Creates or returns a configured public benchmark rate source.

  Public benchmark imports are deterministic in this phase: the source stores
  provider metadata and explicit observation rows in its config. A later provider
  adapter can update that config before the existing import worker consumes it.
  """
  @spec get_or_create_public_benchmark_rate_source(map(), keyword()) ::
          {:ok, RateSource.t()} | {:error, Ecto.Changeset.t()}
  def get_or_create_public_benchmark_rate_source(attrs \\ %{}, opts \\ []) when is_map(attrs) do
    preload = Keyword.get(opts, :preload, [])

    attrs =
      attrs
      |> normalize_attr_map()
      |> Map.put_new("provider_key", "public-mortgage-benchmark")
      |> Map.put_new("name", "Public mortgage benchmark")
      |> Map.put_new("source_type", "public_benchmark")
      |> Map.put_new("enabled", true)
      |> Map.put_new("requires_api_key", false)
      |> Map.put_new("config", %{})

    RateSource
    |> where([source], source.provider_key == ^attrs["provider_key"])
    |> maybe_preload_query(preload)
    |> Repo.one()
    |> case do
      %RateSource{} = source ->
        {:ok, source}

      nil ->
        create_rate_source(attrs, preload: preload)
    end
  end

  @doc """
  Lists benchmark or manually entered loan rate observations.
  """
  @spec list_rate_observations(keyword()) :: [RateObservation.t()]
  def list_rate_observations(opts \\ []) do
    preload = Keyword.get(opts, :preload, [:rate_source])
    limit = Keyword.get(opts, :limit)

    RateObservation
    |> maybe_filter_rate_observation_source(opts)
    |> maybe_filter_rate_observation_loan_type(opts)
    |> maybe_filter_rate_observation_product_type(opts)
    |> maybe_filter_rate_observation_term(opts)
    |> order_by([observation], desc: observation.observed_at)
    |> maybe_limit(limit)
    |> maybe_preload_query(preload)
    |> Repo.all()
  end

  @doc """
  Creates a rate observation under a configured source.

  Rates are stored as decimal fractions, so 6.50% is stored as 0.0650.
  """
  @spec create_rate_observation(RateSource.t() | binary(), map(), keyword()) ::
          {:ok, RateObservation.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def create_rate_observation(source_or_id, attrs, opts \\ []) when is_map(attrs) do
    preload = Keyword.get(opts, :preload, [:rate_source])
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, source} <- fetch_rate_source(source_or_id, preload: []) do
      %RateObservation{}
      |> RateObservation.changeset(
        attrs
        |> normalize_attr_map()
        |> Map.put("rate_source_id", source.id)
        |> Map.put_new("observed_at", now)
        |> Map.put_new("imported_at", now)
      )
      |> Repo.insert()
      |> case do
        {:ok, observation} -> {:ok, Repo.preload(observation, preload)}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc """
  Enqueues import for a configured benchmark rate source.
  """
  @spec enqueue_rate_import(RateSource.t() | binary()) ::
          {:ok, Oban.Job.t()} | {:error, :not_found} | {:error, term()}
  def enqueue_rate_import(source_or_id) do
    with {:ok, source} <- fetch_rate_source(source_or_id, preload: []) do
      %{rate_source_id: source.id}
      |> RateImportWorker.new()
      |> Oban.insert()
    end
  end

  @doc """
  Imports benchmark rate observations from a source's configured observations.

  This is intentionally deterministic in v1. Automated workers consume explicit
  source config entries instead of scraping or calling an external provider.
  """
  @spec process_rate_import_job(binary()) ::
          {:ok, %{source: RateSource.t(), imported: [RateObservation.t()]}}
          | {:error, :not_found | :disabled | :no_configured_observations}
          | {:error, Ecto.Changeset.t()}
  def process_rate_import_job(source_id) when is_binary(source_id) do
    with {:ok, source} <- fetch_rate_source(source_id, preload: []),
         :ok <- ensure_rate_source_enabled(source),
         {:ok, observations} <- configured_rate_observations(source) do
      import_rate_observations(source, observations)
    end
  end

  @doc """
  Fetches one benchmark or manually entered rate observation.
  """
  @spec fetch_rate_observation(RateObservation.t() | binary(), keyword()) ::
          {:ok, RateObservation.t()} | {:error, :not_found}
  def fetch_rate_observation(observation_or_id, opts \\ [])

  def fetch_rate_observation(%RateObservation{id: id}, opts), do: fetch_rate_observation(id, opts)

  def fetch_rate_observation(observation_id, opts) when is_binary(observation_id) do
    preload = Keyword.get(opts, :preload, [:rate_source])

    case Ecto.UUID.cast(observation_id) do
      {:ok, id} ->
        RateObservation
        |> where([observation], observation.id == ^id)
        |> maybe_preload_query(preload)
        |> Repo.one()
        |> case do
          nil -> {:error, :not_found}
          %RateObservation{} = observation -> {:ok, observation}
        end

      :error ->
        {:error, :not_found}
    end
  end

  def fetch_rate_observation(_observation_id, _opts), do: {:error, :not_found}

  @doc """
  Creates a draft refinance scenario from a benchmark rate observation.

  Observations are estimates, not offers. The created scenario is labeled as an
  estimated rate-observation scenario and remains editable before analysis.
  """
  @spec create_refinance_scenario_from_rate_observation(
          User.t() | binary(),
          Mortgage.t() | binary(),
          RateObservation.t() | binary(),
          map(),
          keyword()
        ) ::
          {:ok, RefinanceScenario.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def create_refinance_scenario_from_rate_observation(
        user,
        mortgage_or_id,
        observation_or_id,
        attrs \\ %{},
        opts \\ []
      )
      when is_map(attrs) do
    preload = Keyword.get(opts, :preload, @default_refinance_preload)

    with {:ok, mortgage} <- Mortgages.fetch_mortgage(user, normalize_id(mortgage_or_id)),
         {:ok, observation} <- fetch_rate_observation(observation_or_id, preload: [:rate_source]),
         changeset <-
           RefinanceScenario.changeset(
             %RefinanceScenario{},
             observation
             |> scenario_attrs_from_rate_observation(user, mortgage)
             |> Map.merge(normalize_attr_map(attrs))
           ),
         {:ok, scenario} <- Repo.insert(changeset) do
      {:ok, Repo.preload(scenario, preload)}
    end
  end

  @doc """
  Returns a rate source changeset for forms and tests.
  """
  @spec change_rate_source(RateSource.t(), map()) :: Ecto.Changeset.t()
  def change_rate_source(%RateSource{} = source, attrs \\ %{}) do
    RateSource.changeset(source, attrs)
  end

  @doc """
  Returns a rate observation changeset for forms and tests.
  """
  @spec change_rate_observation(RateObservation.t(), map()) :: Ecto.Changeset.t()
  def change_rate_observation(%RateObservation{} = observation, attrs \\ %{}) do
    RateObservation.changeset(observation, attrs)
  end

  @doc """
  Lists Loan Center alert rules for a mortgage owned by the current user.
  """
  @spec list_loan_alert_rules(User.t() | binary(), Mortgage.t() | binary(), keyword()) :: [
          AlertRule.t()
        ]
  def list_loan_alert_rules(user, mortgage_or_id, opts \\ []) do
    mortgage_id = normalize_id(mortgage_or_id)
    preload = Keyword.get(opts, :preload, @default_alert_preload)

    AlertRule
    |> where(
      [rule],
      rule.user_id == ^normalize_user_id(user) and rule.mortgage_id == ^mortgage_id
    )
    |> order_by([rule], desc: rule.active, asc: rule.kind, desc: rule.updated_at)
    |> maybe_preload_query(preload)
    |> Repo.all()
  end

  @doc """
  Fetches a Loan Center alert rule scoped to the current user.
  """
  @spec fetch_loan_alert_rule(User.t() | binary(), AlertRule.t() | binary(), keyword()) ::
          {:ok, AlertRule.t()} | {:error, :not_found}
  def fetch_loan_alert_rule(user, rule_or_id, opts \\ [])

  def fetch_loan_alert_rule(user, %AlertRule{id: id}, opts),
    do: fetch_loan_alert_rule(user, id, opts)

  def fetch_loan_alert_rule(user, rule_id, opts) when is_binary(rule_id) do
    preload = Keyword.get(opts, :preload, @default_alert_preload)

    case Ecto.UUID.cast(rule_id) do
      {:ok, id} ->
        AlertRule
        |> where([rule], rule.id == ^id and rule.user_id == ^normalize_user_id(user))
        |> maybe_preload_query(preload)
        |> Repo.one()
        |> case do
          nil -> {:error, :not_found}
          %AlertRule{} = rule -> {:ok, rule}
        end

      :error ->
        {:error, :not_found}
    end
  end

  def fetch_loan_alert_rule(_user, _rule_id, _opts), do: {:error, :not_found}

  @doc """
  Creates a Loan Center alert rule for a mortgage owned by the current user.
  """
  @spec create_loan_alert_rule(User.t() | binary(), Mortgage.t() | binary(), map(), keyword()) ::
          {:ok, AlertRule.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def create_loan_alert_rule(user, mortgage_or_id, attrs, opts \\ []) when is_map(attrs) do
    preload = Keyword.get(opts, :preload, @default_alert_preload)

    with {:ok, mortgage} <- Mortgages.fetch_mortgage(user, normalize_id(mortgage_or_id)),
         changeset <-
           AlertRule.changeset(
             %AlertRule{},
             attrs
             |> normalize_attr_map()
             |> normalize_alert_rule_attrs()
             |> Map.put("user_id", normalize_user_id(user))
             |> Map.put("mortgage_id", mortgage.id)
           ),
         {:ok, rule} <- Repo.insert(changeset) do
      {:ok, Repo.preload(rule, preload)}
    end
  end

  @doc """
  Updates a Loan Center alert rule owned by the current user.
  """
  @spec update_loan_alert_rule(User.t() | binary(), AlertRule.t() | binary(), map(), keyword()) ::
          {:ok, AlertRule.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def update_loan_alert_rule(user, rule_or_id, attrs, opts \\ [])

  def update_loan_alert_rule(user, %AlertRule{} = rule, attrs, opts) when is_map(attrs) do
    preload = Keyword.get(opts, :preload, @default_alert_preload)

    if rule.user_id == normalize_user_id(user) do
      rule
      |> AlertRule.changeset(attrs |> normalize_attr_map() |> normalize_alert_rule_attrs())
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, Repo.preload(updated, preload)}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:error, :not_found}
    end
  end

  def update_loan_alert_rule(user, rule_id, attrs, opts)
      when is_binary(rule_id) and is_map(attrs) do
    with {:ok, rule} <- fetch_loan_alert_rule(user, rule_id, preload: []),
         {:ok, updated} <- update_loan_alert_rule(user, rule, attrs, opts) do
      {:ok, updated}
    end
  end

  @doc """
  Deletes a Loan Center alert rule owned by the current user.
  """
  @spec delete_loan_alert_rule(User.t() | binary(), AlertRule.t() | binary()) ::
          {:ok, AlertRule.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def delete_loan_alert_rule(user, %AlertRule{} = rule) do
    if rule.user_id == normalize_user_id(user), do: Repo.delete(rule), else: {:error, :not_found}
  end

  def delete_loan_alert_rule(user, rule_id) when is_binary(rule_id) do
    with {:ok, rule} <- fetch_loan_alert_rule(user, rule_id, preload: []) do
      delete_loan_alert_rule(user, rule)
    end
  end

  @doc """
  Enqueues alert-rule evaluation for one mortgage-backed loan.
  """
  @spec enqueue_loan_alert_evaluation(User.t() | binary(), Mortgage.t() | binary()) ::
          {:ok, Oban.Job.t()} | {:error, :not_found | term()}
  def enqueue_loan_alert_evaluation(user, mortgage_or_id) do
    with {:ok, mortgage} <- Mortgages.fetch_mortgage(user, normalize_id(mortgage_or_id)) do
      %{"user_id" => normalize_user_id(user), "mortgage_id" => mortgage.id}
      |> AlertEvaluationWorker.new()
      |> Oban.insert()
    end
  end

  @doc """
  Enqueues scheduled evaluation for every active Loan Center alert rule.
  """
  @spec enqueue_all_loan_alert_evaluations() :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_all_loan_alert_evaluations do
    %{"scope" => "all_active"}
    |> AlertEvaluationWorker.new()
    |> Oban.insert()
  end

  @doc """
  Evaluates all active Loan Center alert rules for one mortgage-backed loan.
  """
  @spec evaluate_loan_alert_rules(User.t() | binary(), Mortgage.t() | binary()) ::
          {:ok, %{evaluated: non_neg_integer(), triggered: non_neg_integer()}}
          | {:error, :not_found | Ecto.Changeset.t()}
  def evaluate_loan_alert_rules(user, mortgage_or_id) do
    with {:ok, mortgage} <- Mortgages.fetch_mortgage(user, normalize_id(mortgage_or_id)) do
      mortgage
      |> list_active_alert_rules_for_mortgage(user)
      |> Enum.reduce_while({0, 0}, fn rule, {evaluated, triggered} ->
        case evaluate_loan_alert_rule(user, rule) do
          {:ok, %{triggered?: true}} -> {:cont, {evaluated + 1, triggered + 1}}
          {:ok, %{triggered?: false}} -> {:cont, {evaluated + 1, triggered}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:error, reason} -> {:error, reason}
        {evaluated, triggered} -> {:ok, %{evaluated: evaluated, triggered: triggered}}
      end
    end
  end

  @doc """
  Evaluates every active Loan Center alert rule.

  This is the scheduled evaluation entrypoint used by the alert worker. It
  preserves per-rule cooldown and notification dedupe behavior.
  """
  @spec evaluate_all_loan_alert_rules(keyword()) ::
          {:ok, %{evaluated: non_neg_integer(), triggered: non_neg_integer()}}
          | {:error, Ecto.Changeset.t()}
  def evaluate_all_loan_alert_rules(opts \\ []) do
    limit = Keyword.get(opts, :limit)

    AlertRule
    |> where([rule], rule.active == true)
    |> order_by([rule], asc: rule.inserted_at)
    |> maybe_limit(limit)
    |> Repo.all()
    |> Enum.reduce_while({0, 0}, fn rule, {evaluated, triggered} ->
      case evaluate_loan_alert_rule(rule.user_id, rule) do
        {:ok, %{triggered?: true}} -> {:cont, {evaluated + 1, triggered + 1}}
        {:ok, %{triggered?: false}} -> {:cont, {evaluated + 1, triggered}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      {evaluated, triggered} -> {:ok, %{evaluated: evaluated, triggered: triggered}}
    end
  end

  @doc """
  Evaluates one Loan Center alert rule and records a durable notification event if it triggers.
  """
  @spec evaluate_loan_alert_rule(User.t() | binary(), AlertRule.t() | binary()) ::
          {:ok, %{rule: AlertRule.t(), triggered?: boolean()}}
          | {:error, :not_found | Ecto.Changeset.t()}
  def evaluate_loan_alert_rule(user, rule_or_id) do
    with {:ok, rule} <- fetch_loan_alert_rule(user, rule_or_id, preload: [:mortgage]) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      result =
        if rule.active do
          evaluate_alert_rule_trigger(user, rule)
        else
          :not_triggered
        end

      with {:ok, evaluated_rule} <-
             update_loan_alert_rule(user, rule, %{"last_evaluated_at" => now}),
           {:ok, triggered?} <- maybe_record_alert_event(evaluated_rule, result, now),
           {:ok, updated_rule} <-
             maybe_mark_alert_rule_triggered(user, evaluated_rule, triggered?, now) do
        {:ok, %{rule: updated_rule, triggered?: triggered?}}
      end
    end
  end

  @doc """
  Returns a loan alert rule changeset for forms and tests.
  """
  @spec change_loan_alert_rule(AlertRule.t(), map()) :: Ecto.Changeset.t()
  def change_loan_alert_rule(%AlertRule{} = rule, attrs \\ %{}) do
    AlertRule.changeset(rule, attrs)
  end

  @doc """
  Lists loan document metadata for a mortgage owned by the current user.
  """
  @spec list_loan_documents(User.t() | binary(), Mortgage.t() | binary(), keyword()) :: [
          LoanDocument.t()
        ]
  def list_loan_documents(user, mortgage_or_id, opts \\ []) do
    mortgage_id = normalize_id(mortgage_or_id)
    preload = Keyword.get(opts, :preload, [])

    LoanDocument
    |> where(
      [document],
      document.user_id == ^normalize_user_id(user) and document.mortgage_id == ^mortgage_id
    )
    |> order_by([document], desc: document.uploaded_at)
    |> maybe_preload_query(preload)
    |> Repo.all()
  end

  @doc """
  Fetches one loan document scoped to the current user.
  """
  @spec fetch_loan_document(User.t() | binary(), LoanDocument.t() | binary(), keyword()) ::
          {:ok, LoanDocument.t()} | {:error, :not_found}
  def fetch_loan_document(user, document_or_id, opts \\ [])

  def fetch_loan_document(user, %LoanDocument{id: id}, opts),
    do: fetch_loan_document(user, id, opts)

  def fetch_loan_document(user, document_id, opts) when is_binary(document_id) do
    preload = Keyword.get(opts, :preload, [])

    case Ecto.UUID.cast(document_id) do
      {:ok, id} ->
        LoanDocument
        |> where(
          [document],
          document.id == ^id and document.user_id == ^normalize_user_id(user)
        )
        |> maybe_preload_query(preload)
        |> Repo.one()
        |> case do
          nil -> {:error, :not_found}
          %LoanDocument{} = document -> {:ok, document}
        end

      :error ->
        {:error, :not_found}
    end
  end

  def fetch_loan_document(_user, _document_id, _opts), do: {:error, :not_found}

  @doc """
  Creates loan document metadata for a mortgage owned by the current user.
  """
  @spec create_loan_document(User.t() | binary(), Mortgage.t() | binary(), map(), keyword()) ::
          {:ok, LoanDocument.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def create_loan_document(user, mortgage_or_id, attrs, opts \\ []) when is_map(attrs) do
    preload = Keyword.get(opts, :preload, [])

    with {:ok, mortgage} <- Mortgages.fetch_mortgage(user, normalize_id(mortgage_or_id)),
         changeset <-
           LoanDocument.changeset(
             %LoanDocument{},
             attrs
             |> normalize_attr_map()
             |> Map.put("user_id", normalize_user_id(user))
             |> Map.put("mortgage_id", mortgage.id)
             |> Map.put_new("uploaded_at", DateTime.utc_now())
           ),
         {:ok, document} <- Repo.insert(changeset) do
      {:ok, Repo.preload(document, preload)}
    end
  end

  @doc """
  Enqueues background extraction for a stored loan document file.
  """
  @spec enqueue_loan_document_extraction(User.t() | binary(), LoanDocument.t() | binary()) ::
          {:ok, Oban.Job.t()} | {:error, :not_found} | {:error, term()}
  def enqueue_loan_document_extraction(user, document_or_id) do
    with {:ok, document} <- fetch_loan_document(user, document_or_id, preload: []) do
      %{document_id: document.id, user_id: normalize_user_id(user)}
      |> DocumentExtractionWorker.new()
      |> Oban.insert()
    end
  end

  @doc """
  Runs document text extraction and stores an Ollama candidate for review.
  """
  @spec process_loan_document_extraction_job(binary(), binary()) ::
          :ok | {:error, term()}
  def process_loan_document_extraction_job(user_id, document_id)
      when is_binary(user_id) and is_binary(document_id) do
    with {:ok, document} <- fetch_loan_document(user_id, document_id, preload: []),
         :ok <- mark_loan_document_status(document, "extracting"),
         {:ok, raw_text} <- extract_text_from_stored_document(document),
         {:ok, extracted_text_storage_key} <- store_extracted_document_text(document, raw_text),
         {:ok, _extraction} <-
           create_ollama_loan_document_extraction(user_id, document, raw_text,
             extraction_attrs: %{"ocr_text_storage_key" => extracted_text_storage_key}
           ),
         :ok <- mark_loan_document_status(document, "pending_review") do
      :ok
    else
      {:error, :disabled_for_user} ->
        mark_document_status(user_id, document_id, "uploaded")
        :ok

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        mark_failed_document_extraction(user_id, document_id)
        {:error, reason}
    end
  end

  @doc """
  Lists extracted candidate data for a loan document owned by the current user.
  """
  @spec list_loan_document_extractions(
          User.t() | binary(),
          LoanDocument.t() | binary(),
          keyword()
        ) ::
          [LoanDocumentExtraction.t()]
  def list_loan_document_extractions(user, document_or_id, opts \\ []) do
    document_id = normalize_id(document_or_id)
    preload = Keyword.get(opts, :preload, [])

    LoanDocumentExtraction
    |> where(
      [extraction],
      extraction.user_id == ^normalize_user_id(user) and
        extraction.loan_document_id == ^document_id
    )
    |> order_by([extraction], desc: extraction.inserted_at)
    |> maybe_preload_query(preload)
    |> Repo.all()
  end

  @doc """
  Creates reviewable extracted candidate data for a loan document.
  """
  @spec create_loan_document_extraction(
          User.t() | binary(),
          LoanDocument.t() | binary(),
          map(),
          keyword()
        ) ::
          {:ok, LoanDocumentExtraction.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def create_loan_document_extraction(user, document_or_id, attrs, opts \\ [])
      when is_map(attrs) do
    preload = Keyword.get(opts, :preload, [])

    with {:ok, document} <- fetch_loan_document(user, document_or_id, preload: []),
         changeset <-
           LoanDocumentExtraction.changeset(
             %LoanDocumentExtraction{},
             attrs
             |> normalize_attr_map()
             |> Map.put("user_id", normalize_user_id(user))
             |> Map.put("mortgage_id", document.mortgage_id)
             |> Map.put("loan_document_id", document.id)
           ),
         {:ok, extraction} <- Repo.insert(changeset) do
      {:ok, Repo.preload(extraction, preload)}
    end
  end

  @doc """
  Extracts reviewable loan document fields with the configured local AI provider.

  The returned candidate remains pending review and does not update canonical mortgage records.
  """
  @spec create_ollama_loan_document_extraction(
          User.t() | binary(),
          LoanDocument.t() | binary(),
          String.t(),
          keyword()
        ) ::
          {:ok, LoanDocumentExtraction.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :not_found}
          | {:error, term()}
  def create_ollama_loan_document_extraction(user, document_or_id, raw_text, opts \\ [])
      when is_binary(raw_text) do
    preload = Keyword.get(opts, :preload, [])
    ai_opts = opts |> Keyword.get(:ai_opts, %{}) |> Map.new()
    extra_extraction_attrs = opts |> Keyword.get(:extraction_attrs, %{}) |> normalize_attr_map()

    with {:ok, document} <- fetch_loan_document(user, document_or_id, preload: []),
         {:ok, ai_extraction_attrs} <-
           AI.extract_loan_document_fields(
             user,
             raw_text,
             Map.put_new(ai_opts, "document_type", document.document_type)
           ) do
      create_loan_document_extraction(
        user,
        document,
        Map.merge(ai_extraction_attrs, extra_extraction_attrs),
        preload: preload
      )
    end
  end

  @doc """
  Fetches one extraction candidate scoped to the current user.
  """
  @spec fetch_loan_document_extraction(
          User.t() | binary(),
          LoanDocumentExtraction.t() | binary(),
          keyword()
        ) ::
          {:ok, LoanDocumentExtraction.t()} | {:error, :not_found}
  def fetch_loan_document_extraction(user, extraction_or_id, opts \\ [])

  def fetch_loan_document_extraction(user, %LoanDocumentExtraction{id: id}, opts) do
    fetch_loan_document_extraction(user, id, opts)
  end

  def fetch_loan_document_extraction(user, extraction_id, opts) when is_binary(extraction_id) do
    preload = Keyword.get(opts, :preload, [])

    case Ecto.UUID.cast(extraction_id) do
      {:ok, id} ->
        LoanDocumentExtraction
        |> where(
          [extraction],
          extraction.id == ^id and extraction.user_id == ^normalize_user_id(user)
        )
        |> maybe_preload_query(preload)
        |> Repo.one()
        |> case do
          nil -> {:error, :not_found}
          %LoanDocumentExtraction{} = extraction -> {:ok, extraction}
        end

      :error ->
        {:error, :not_found}
    end
  end

  def fetch_loan_document_extraction(_user, _extraction_id, _opts), do: {:error, :not_found}

  @doc """
  Marks an extraction candidate as user-confirmed without applying it to canonical records.
  """
  @spec confirm_loan_document_extraction(
          User.t() | binary(),
          LoanDocumentExtraction.t() | binary(),
          keyword()
        ) ::
          {:ok, LoanDocumentExtraction.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def confirm_loan_document_extraction(user, extraction_or_id, opts \\ []) do
    now = DateTime.utc_now()
    preload = Keyword.get(opts, :preload, [])

    with {:ok, extraction} <- fetch_loan_document_extraction(user, extraction_or_id, preload: []) do
      extraction
      |> LoanDocumentExtraction.changeset(%{
        "status" => "confirmed",
        "reviewed_at" => now,
        "confirmed_at" => now,
        "rejected_at" => nil
      })
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, Repo.preload(updated, preload)}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc """
  Marks an extraction candidate as user-rejected without applying it to canonical records.
  """
  @spec reject_loan_document_extraction(
          User.t() | binary(),
          LoanDocumentExtraction.t() | binary(),
          keyword()
        ) ::
          {:ok, LoanDocumentExtraction.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def reject_loan_document_extraction(user, extraction_or_id, opts \\ []) do
    now = DateTime.utc_now()
    preload = Keyword.get(opts, :preload, [])

    with {:ok, extraction} <- fetch_loan_document_extraction(user, extraction_or_id, preload: []) do
      extraction
      |> LoanDocumentExtraction.changeset(%{
        "status" => "rejected",
        "reviewed_at" => now,
        "confirmed_at" => nil,
        "rejected_at" => now
      })
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, Repo.preload(updated, preload)}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc """
  Applies confirmed extracted mortgage fields to the canonical mortgage baseline.

  Only confirmed extraction candidates can be applied, and only known mortgage
  fields are mapped. Unknown fields remain in the extraction payload for review.
  """
  @spec apply_loan_document_extraction_to_mortgage(
          User.t() | binary(),
          LoanDocumentExtraction.t() | binary()
        ) ::
          {:ok, Mortgage.t()}
          | {:error, :not_found | :not_confirmed | :no_applicable_fields}
          | {:error, Ecto.Changeset.t()}
  def apply_loan_document_extraction_to_mortgage(user, extraction_or_id) do
    with {:ok, extraction} <- fetch_loan_document_extraction(user, extraction_or_id, preload: []),
         :ok <- require_confirmed_extraction(extraction),
         {:ok, mortgage} <- Mortgages.fetch_mortgage(user, extraction.mortgage_id),
         {:ok, attrs} <- mortgage_attrs_from_extraction(extraction) do
      Mortgages.update_mortgage(
        user,
        mortgage,
        attrs
        |> Map.put("source", "document_extraction")
        |> Map.put("last_reviewed_at", DateTime.utc_now())
      )
    end
  end

  @doc """
  Creates a lender quote from confirmed extracted document fields.

  This preserves the review gate: pending extraction candidates cannot create
  lender quotes, and the source extraction id is retained in the quote payload.
  """
  @spec create_lender_quote_from_document_extraction(
          User.t() | binary(),
          LoanDocumentExtraction.t() | binary()
        ) ::
          {:ok, LenderQuote.t()}
          | {:error, :not_found | :not_confirmed | :no_applicable_quote_fields}
          | {:error, Ecto.Changeset.t()}
  def create_lender_quote_from_document_extraction(user, extraction_or_id) do
    with {:ok, extraction} <- fetch_loan_document_extraction(user, extraction_or_id, preload: []),
         :ok <- require_confirmed_extraction(extraction),
         {:ok, attrs} <- lender_quote_attrs_from_extraction(extraction) do
      create_lender_quote(user, extraction.mortgage_id, attrs)
    end
  end

  @doc """
  Creates a draft refinance scenario from confirmed extracted document fields.

  The extraction remains a candidate source. It can seed a scenario only after
  user confirmation, and the scenario still uses deterministic analysis.
  """
  @spec create_refinance_scenario_from_document_extraction(
          User.t() | binary(),
          LoanDocumentExtraction.t() | binary(),
          map(),
          keyword()
        ) ::
          {:ok, RefinanceScenario.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :not_found | :not_confirmed | :no_applicable_scenario_fields}
          | {:error, term()}
  def create_refinance_scenario_from_document_extraction(
        user,
        extraction_or_id,
        attrs \\ %{},
        opts \\ []
      )
      when is_map(attrs) do
    preload = Keyword.get(opts, :preload, @default_refinance_preload)

    with {:ok, extraction} <- fetch_loan_document_extraction(user, extraction_or_id, preload: []),
         :ok <- require_confirmed_extraction(extraction),
         {:ok, mortgage} <- Mortgages.fetch_mortgage(user, extraction.mortgage_id),
         {:ok, scenario_attrs, fee_attrs} <-
           refinance_scenario_attrs_from_extraction(user, mortgage, extraction, attrs) do
      Multi.new()
      |> Multi.insert(
        :scenario,
        RefinanceScenario.changeset(%RefinanceScenario{}, scenario_attrs)
      )
      |> insert_extraction_fee_items(fee_attrs)
      |> Repo.transaction()
      |> case do
        {:ok, %{scenario: scenario}} -> {:ok, Repo.preload(scenario, preload)}
        {:error, _operation, reason, _changes} -> {:error, reason}
      end
    end
  end

  @doc """
  Lists lender quotes for a mortgage owned by the current user.
  """
  @spec list_lender_quotes(User.t() | binary(), Mortgage.t() | binary(), keyword()) :: [
          LenderQuote.t()
        ]
  def list_lender_quotes(user, mortgage_or_id, opts \\ []) do
    mortgage_id = normalize_id(mortgage_or_id)
    preload = Keyword.get(opts, :preload, [])

    LenderQuote
    |> where(
      [quote],
      quote.user_id == ^normalize_user_id(user) and quote.mortgage_id == ^mortgage_id
    )
    |> order_by([quote], desc: quote.updated_at)
    |> maybe_preload_query(preload)
    |> Repo.all()
  end

  @doc """
  Fetches one lender quote scoped to the current user.
  """
  @spec fetch_lender_quote(User.t() | binary(), LenderQuote.t() | binary(), keyword()) ::
          {:ok, LenderQuote.t()} | {:error, :not_found}
  def fetch_lender_quote(user, quote_or_id, opts \\ [])

  def fetch_lender_quote(user, %LenderQuote{id: id}, opts), do: fetch_lender_quote(user, id, opts)

  def fetch_lender_quote(user, quote_id, opts) when is_binary(quote_id) do
    preload = Keyword.get(opts, :preload, [])

    case Ecto.UUID.cast(quote_id) do
      {:ok, id} ->
        LenderQuote
        |> where([quote], quote.id == ^id and quote.user_id == ^normalize_user_id(user))
        |> maybe_preload_query(preload)
        |> Repo.one()
        |> case do
          nil -> {:error, :not_found}
          %LenderQuote{} = quote -> {:ok, quote}
        end

      :error ->
        {:error, :not_found}
    end
  end

  def fetch_lender_quote(_user, _quote_id, _opts), do: {:error, :not_found}

  @doc """
  Creates a manual lender quote for a mortgage owned by the current user.
  """
  @spec create_lender_quote(User.t() | binary(), Mortgage.t() | binary(), map(), keyword()) ::
          {:ok, LenderQuote.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def create_lender_quote(user, mortgage_or_id, attrs, opts \\ []) when is_map(attrs) do
    preload = Keyword.get(opts, :preload, [])

    with {:ok, mortgage} <- Mortgages.fetch_mortgage(user, normalize_id(mortgage_or_id)),
         changeset <-
           LenderQuote.changeset(
             %LenderQuote{},
             attrs
             |> normalize_attr_map()
             |> Map.put("user_id", normalize_user_id(user))
             |> Map.put("mortgage_id", mortgage.id)
           ),
         {:ok, quote} <- Repo.insert(changeset) do
      {:ok, Repo.preload(quote, preload)}
    end
  end

  @doc """
  Updates a lender quote owned by the current user.
  """
  @spec update_lender_quote(User.t() | binary(), LenderQuote.t() | binary(), map(), keyword()) ::
          {:ok, LenderQuote.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def update_lender_quote(user, quote_or_id, attrs, opts \\ [])

  def update_lender_quote(user, %LenderQuote{} = quote, attrs, opts) when is_map(attrs) do
    preload = Keyword.get(opts, :preload, [])

    if quote.user_id == normalize_user_id(user) do
      quote
      |> LenderQuote.changeset(normalize_attr_map(attrs))
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, Repo.preload(updated, preload)}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:error, :not_found}
    end
  end

  def update_lender_quote(user, quote_id, attrs, opts)
      when is_binary(quote_id) and is_map(attrs) do
    with {:ok, quote} <- fetch_lender_quote(user, quote_id, preload: []),
         {:ok, updated} <- update_lender_quote(user, quote, attrs, opts) do
      {:ok, updated}
    end
  end

  @doc """
  Marks active lender quotes as expired when their expiration timestamp has passed.
  """
  @spec expire_lender_quotes(User.t() | binary(), Mortgage.t() | binary(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :not_found}
  def expire_lender_quotes(user, mortgage_or_id, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now() end)

    with {:ok, mortgage} <- Mortgages.fetch_mortgage(user, normalize_id(mortgage_or_id)) do
      {count, _rows} =
        LenderQuote
        |> where(
          [quote],
          quote.user_id == ^normalize_user_id(user) and quote.mortgage_id == ^mortgage.id and
            quote.status == "active" and not is_nil(quote.quote_expires_at) and
            quote.quote_expires_at < ^now
        )
        |> Repo.update_all(
          set: [
            status: "expired",
            updated_at: DateTime.utc_now()
          ]
        )

      {:ok, count}
    end
  end

  @doc """
  Converts a lender quote into a draft refinance scenario with quote-derived fee assumptions.

  The scenario uses the current mortgage balance as the principal baseline unless
  an explicit `new_principal_amount` override is provided.
  """
  @spec convert_lender_quote_to_refinance_scenario(
          User.t() | binary(),
          LenderQuote.t() | binary(),
          map(),
          keyword()
        ) ::
          {:ok, RefinanceScenario.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :not_found}
          | {:error, term()}
  def convert_lender_quote_to_refinance_scenario(user, quote_or_id, attrs \\ %{}, opts \\ [])
      when is_map(attrs) do
    preload = Keyword.get(opts, :preload, @default_refinance_preload)

    with {:ok, quote} <- fetch_lender_quote(user, quote_or_id, preload: []),
         {:ok, mortgage} <- Mortgages.fetch_mortgage(user, quote.mortgage_id) do
      scenario_attrs = scenario_attrs_from_quote(user, mortgage, quote, attrs)

      Multi.new()
      |> Multi.insert(
        :scenario,
        RefinanceScenario.changeset(%RefinanceScenario{}, scenario_attrs)
      )
      |> insert_quote_fee_items(quote)
      |> Multi.update(:quote, LenderQuote.changeset(quote, %{status: "converted"}))
      |> Repo.transaction()
      |> case do
        {:ok, %{scenario: scenario}} -> {:ok, Repo.preload(scenario, preload)}
        {:error, _operation, reason, _changes} -> {:error, reason}
      end
    end
  end

  @doc """
  Returns a scenario changeset for forms and tests.
  """
  @spec change_refinance_scenario(RefinanceScenario.t(), map()) :: Ecto.Changeset.t()
  def change_refinance_scenario(%RefinanceScenario{} = scenario, attrs \\ %{}) do
    RefinanceScenario.changeset(scenario, attrs)
  end

  @doc """
  Returns a fee-item changeset for forms and tests.
  """
  @spec change_refinance_fee_item(RefinanceFeeItem.t(), map()) :: Ecto.Changeset.t()
  def change_refinance_fee_item(%RefinanceFeeItem{} = fee_item, attrs \\ %{}) do
    RefinanceFeeItem.changeset(fee_item, attrs)
  end

  @doc """
  Returns a loan document changeset for forms and tests.
  """
  @spec change_loan_document(LoanDocument.t(), map()) :: Ecto.Changeset.t()
  def change_loan_document(%LoanDocument{} = document, attrs \\ %{}) do
    LoanDocument.changeset(document, attrs)
  end

  @doc """
  Returns a loan document extraction changeset for forms and tests.
  """
  @spec change_loan_document_extraction(LoanDocumentExtraction.t(), map()) :: Ecto.Changeset.t()
  def change_loan_document_extraction(%LoanDocumentExtraction{} = extraction, attrs \\ %{}) do
    LoanDocumentExtraction.changeset(extraction, attrs)
  end

  @doc """
  Returns a lender quote changeset for forms and tests.
  """
  @spec change_lender_quote(LenderQuote.t(), map()) :: Ecto.Changeset.t()
  def change_lender_quote(%LenderQuote{} = quote, attrs \\ %{}) do
    LenderQuote.changeset(quote, attrs)
  end

  defp autopay_details(account, funding_account, opts) do
    currency = account.currency || "USD"
    balance = normalize_decimal(account.current_balance)

    payment_amount =
      Keyword.get_lazy(opts, :payment_amount_fn, fn -> default_payment_amount(balance) end)
      |> apply_payment_amount(balance)

    next_run_on = compute_next_run(account, opts)
    enabled? = Decimal.compare(balance, Decimal.new("0")) == :gt

    %{
      enabled?: enabled?,
      cadence: :monthly,
      funding_account: Keyword.get(opts, :funding_account, funding_account),
      next_run_on: next_run_on,
      payment_amount: Accounts.format_money(payment_amount, currency, opts),
      payment_amount_masked: Accounts.mask_money(payment_amount, currency, opts)
    }
  end

  defp apply_payment_amount(fun, balance) when is_function(fun, 1), do: fun.(balance)
  defp apply_payment_amount(value, _balance), do: normalize_decimal(value)

  defp compute_next_run(account, opts) do
    base_date = Keyword.get(opts, :reference_date, Date.utc_today())
    cycle_day = Keyword.get(opts, :cycle_day, preferred_cycle_day(account))

    if cycle_day <= base_date.day do
      base_date
      |> Date.beginning_of_month()
      |> Date.add(32)
      |> Date.beginning_of_month()
      |> Date.add(cycle_day - 1)
    else
      base_date
      |> Date.beginning_of_month()
      |> Date.add(cycle_day - 1)
    end
  end

  defp preferred_cycle_day(account) do
    seed = account.id || account.external_id || account.name || "loan"
    rem(:erlang.phash2(seed), 27) + 1
  end

  defp default_payment_amount(balance) do
    balance
    |> Decimal.min(Decimal.new("750"))
    |> Decimal.max(Decimal.new("50"))
  end

  defp loan_account?(account) do
    type = account.type |> to_string() |> String.downcase()
    subtype = account.subtype |> to_string() |> String.downcase()

    String.contains?(type, "loan") or subtype in ["mortgage", "student", "auto", "loan"]
  end

  defp list_active_alert_rules_for_mortgage(%Mortgage{id: mortgage_id}, user) do
    AlertRule
    |> where(
      [rule],
      rule.user_id == ^normalize_user_id(user) and rule.mortgage_id == ^mortgage_id and
        rule.active == true
    )
    |> Repo.all()
    |> Repo.preload(:mortgage)
  end

  defp evaluate_alert_rule_trigger(user, %AlertRule{kind: "document_review_needed"} = rule) do
    pending_documents =
      user
      |> list_loan_documents(rule.mortgage_id, preload: [:extractions])
      |> Enum.filter(&document_needs_review?/1)

    case pending_documents do
      [] ->
        :not_triggered

      [document | _] ->
        {:triggered,
         %{
           title: "Loan document needs review",
           message:
             "#{document.original_filename} has extracted loan fields waiting for confirmation.",
           action: "Open Loan Center documents",
           severity: "warning",
           metadata: %{
             "loan_alert_rule_id" => rule.id,
             "mortgage_id" => rule.mortgage_id,
             "loan_document_id" => document.id,
             "document_type" => document.document_type
           }
         }}
    end
  end

  defp evaluate_alert_rule_trigger(user, %AlertRule{kind: "lender_quote_expiring"} = rule) do
    lead_days = alert_integer(rule.threshold_config, "lead_days", 7)
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, lead_days * 86_400, :second)

    quote =
      user
      |> list_lender_quotes(rule.mortgage_id)
      |> Enum.filter(&(&1.status == "active"))
      |> Enum.filter(&quote_expires_before?(&1, now, cutoff))
      |> Enum.sort_by(& &1.quote_expires_at, DateTime)
      |> List.first()

    if quote do
      {:triggered,
       %{
         title: "Lender quote expiring",
         message:
           "#{quote.lender_name} quote expires on #{Date.to_iso8601(DateTime.to_date(quote.quote_expires_at))}.",
         action: "Review lender quote",
         severity: "warning",
         metadata: %{
           "loan_alert_rule_id" => rule.id,
           "mortgage_id" => rule.mortgage_id,
           "lender_quote_id" => quote.id,
           "quote_expires_at" => DateTime.to_iso8601(quote.quote_expires_at),
           "lead_days" => lead_days
         }
       }}
    else
      :not_triggered
    end
  end

  defp evaluate_alert_rule_trigger(user, %AlertRule{} = rule) do
    threshold = alert_decimal(rule.threshold_config, "threshold")

    if threshold do
      rule.mortgage
      |> alert_scenario_rows(user)
      |> Enum.find_value(:not_triggered, &threshold_alert_event(rule, &1, threshold))
    else
      :not_triggered
    end
  end

  defp document_needs_review?(%LoanDocument{status: "pending_review"}), do: true

  defp document_needs_review?(%LoanDocument{extractions: extractions})
       when is_list(extractions) do
    Enum.any?(extractions, &(&1.status == "pending_review"))
  end

  defp document_needs_review?(_document), do: false

  defp quote_expires_before?(%LenderQuote{quote_expires_at: nil}, _now, _cutoff), do: false

  defp quote_expires_before?(%LenderQuote{quote_expires_at: expires_at}, now, cutoff) do
    DateTime.compare(expires_at, now) != :lt and DateTime.compare(expires_at, cutoff) != :gt
  end

  defp alert_scenario_rows(%Mortgage{} = mortgage, user) do
    user
    |> list_refinance_scenarios(mortgage, preload: [:fee_items])
    |> Enum.map(fn scenario ->
      true_refinance_cost = sum_fee_items(scenario.fee_items, :true_cost)
      cash_to_close_timing_cost = sum_fee_items(scenario.fee_items, :timing_cost)

      %{
        mortgage: mortgage,
        scenario: scenario,
        analysis:
          RefinanceCalculator.analyze(%{
            current_principal: mortgage.current_balance,
            current_rate: mortgage.current_interest_rate,
            current_remaining_term_months: mortgage.remaining_term_months,
            current_monthly_payment: mortgage.monthly_payment_total,
            new_principal: scenario.new_principal_amount,
            new_rate: scenario.new_interest_rate,
            new_term_months: scenario.new_term_months,
            true_refinance_cost: true_refinance_cost,
            cash_to_close_timing_cost: cash_to_close_timing_cost
          })
      }
    end)
  end

  defp threshold_alert_event(
         %AlertRule{kind: "monthly_payment_below_threshold"} = rule,
         row,
         threshold
       ) do
    value = row.analysis.payment_range.expected

    if Decimal.compare(value, threshold) != :gt do
      scenario_alert_event(rule, row, value, threshold, "Expected payment threshold reached")
    end
  end

  defp threshold_alert_event(
         %AlertRule{kind: "monthly_savings_above_threshold"} = rule,
         row,
         threshold
       ) do
    value = row.analysis.monthly_savings_range.expected

    if Decimal.compare(value, threshold) != :lt do
      scenario_alert_event(rule, row, value, threshold, "Expected savings threshold reached")
    end
  end

  defp threshold_alert_event(%AlertRule{kind: "break_even_below_months"} = rule, row, threshold) do
    value = row.analysis.break_even_range.expected

    if value && Decimal.compare(Decimal.new(value), threshold) != :gt do
      scenario_alert_event(
        rule,
        row,
        Decimal.new(value),
        threshold,
        "Break-even threshold reached"
      )
    end
  end

  defp threshold_alert_event(
         %AlertRule{kind: "full_term_cost_savings_above_threshold"} = rule,
         row,
         threshold
       ) do
    value = full_term_savings(row.analysis.full_term_finance_cost_delta)

    if Decimal.compare(value, threshold) != :lt do
      scenario_alert_event(rule, row, value, threshold, "Full-term savings threshold reached")
    end
  end

  defp threshold_alert_event(%AlertRule{kind: "rate_below_threshold"} = rule, row, threshold) do
    value = row.scenario.new_interest_rate

    if Decimal.compare(value, threshold) != :gt do
      scenario_alert_event(rule, row, value, threshold, "Rate threshold reached")
    end
  end

  defp threshold_alert_event(_rule, _row, _threshold), do: nil

  defp scenario_alert_event(rule, row, value, threshold, title) do
    {:triggered,
     %{
       title: title,
       message:
         "#{row.scenario.name} now matches #{rule.name}: #{Decimal.to_string(value, :normal)} versus #{Decimal.to_string(threshold, :normal)}.",
       action: "Review refinance scenario",
       severity: "info",
       metadata: %{
         "loan_alert_rule_id" => rule.id,
         "mortgage_id" => rule.mortgage_id,
         "refinance_scenario_id" => row.scenario.id,
         "observed_value" => Decimal.to_string(value, :normal),
         "threshold" => Decimal.to_string(threshold, :normal)
       }
     }}
  end

  defp full_term_savings(delta) do
    if Decimal.compare(delta, Decimal.new("0")) == :lt do
      Decimal.abs(delta)
    else
      Decimal.new("0")
    end
  end

  defp maybe_record_alert_event(rule, {:triggered, event_attrs}, now) do
    if alert_rule_in_cooldown?(rule, now) do
      {:ok, false}
    else
      do_record_alert_event(rule, event_attrs, now)
    end
  end

  defp maybe_record_alert_event(_rule, _result, _now), do: {:ok, false}

  defp do_record_alert_event(rule, event_attrs, now) do
    attrs =
      Map.merge(event_attrs, %{
        user_id: rule.user_id,
        kind: "loan_refinance_alert",
        status: rule.kind,
        event_date: Date.utc_today(),
        occurred_at: now,
        dedupe_key: loan_alert_dedupe_key(rule, event_attrs)
      })

    case Notifications.record_event(attrs) do
      {:ok, _event} -> {:ok, true}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp maybe_mark_alert_rule_triggered(user, rule, true, now) do
    update_loan_alert_rule(user, rule, %{"last_triggered_at" => now})
  end

  defp maybe_mark_alert_rule_triggered(_user, rule, false, _now), do: {:ok, rule}

  defp alert_rule_in_cooldown?(%AlertRule{last_triggered_at: nil}, _now), do: false

  defp alert_rule_in_cooldown?(%AlertRule{} = rule, now) do
    cooldown_hours = alert_integer(rule.delivery_preferences, "cooldown_hours", 24)

    DateTime.compare(DateTime.add(rule.last_triggered_at, cooldown_hours * 3_600, :second), now) ==
      :gt
  end

  defp loan_alert_dedupe_key(rule, event_attrs) do
    metadata = Map.get(event_attrs, :metadata, %{})

    source_id =
      Map.get(metadata, "refinance_scenario_id") ||
        Map.get(metadata, "lender_quote_id") ||
        Map.get(metadata, "loan_document_id") ||
        rule.mortgage_id

    ["loan_alert", rule.id, source_id, Date.to_iso8601(Date.utc_today())]
    |> Enum.join(":")
  end

  defp normalize_alert_rule_attrs(attrs) do
    attrs
    |> maybe_put_threshold_config("threshold_value", "threshold")
    |> maybe_put_threshold_config("lead_days", "lead_days")
  end

  defp maybe_put_threshold_config(attrs, source_key, config_key) do
    value = Map.get(attrs, source_key)

    attrs = Map.delete(attrs, source_key)

    if blank?(value) do
      attrs
    else
      config =
        attrs
        |> Map.get("threshold_config", %{})
        |> normalize_attr_map()
        |> Map.put(config_key, value)

      Map.put(attrs, "threshold_config", config)
    end
  end

  defp alert_decimal(config, key) do
    config
    |> normalize_attr_map()
    |> Map.get(key)
    |> Decimal.cast()
    |> case do
      {:ok, decimal} -> decimal
      :error -> nil
    end
  end

  defp alert_integer(config, key, default) do
    config
    |> normalize_attr_map()
    |> Map.get(key)
    |> case do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _ -> default
        end

      _ ->
        default
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp require_confirmed_extraction(%LoanDocumentExtraction{status: "confirmed"}), do: :ok
  defp require_confirmed_extraction(_extraction), do: {:error, :not_confirmed}

  defp extract_text_from_stored_document(%LoanDocument{} = document) do
    with :ok <- ensure_readable_document_type(document),
         {:ok, text} <-
           extract_text_from_file(document, stored_document_path(document.storage_key)) do
      {:ok, text}
    end
  end

  defp extract_text_from_file(%LoanDocument{} = document, path) do
    cond do
      pdf_document?(document) ->
        extract_pdf_text(path)

      image_document?(document) ->
        extract_image_text(path)

      true ->
        with {:ok, content} <- File.read(path), do: readable_text(content)
    end
  end

  defp pdf_document?(%LoanDocument{content_type: "application/pdf"}), do: true

  defp pdf_document?(%LoanDocument{original_filename: filename}) do
    filename
    |> to_string()
    |> Path.extname()
    |> String.downcase()
    |> Kernel.==(".pdf")
  end

  defp image_document?(%LoanDocument{content_type: content_type, original_filename: filename}) do
    extension =
      filename
      |> to_string()
      |> Path.extname()
      |> String.downcase()

    content_type in ~w(image/png image/jpeg) or extension in ~w(.png .jpg .jpeg)
  end

  defp ensure_readable_document_type(%LoanDocument{
         content_type: content_type,
         original_filename: filename
       }) do
    extension =
      filename
      |> to_string()
      |> Path.extname()
      |> String.downcase()

    if content_type in @readable_document_content_types or
         extension in @readable_document_extensions do
      :ok
    else
      {:error, :unsupported_document_text_extraction}
    end
  end

  defp stored_document_path(storage_key) do
    Path.join([System.tmp_dir!(), "money_tree", "uploads", storage_key])
  end

  defp store_extracted_document_text(%LoanDocument{} = document, text) when is_binary(text) do
    storage_key = extracted_text_storage_key(document)
    path = stored_document_path(storage_key)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, text) do
      {:ok, storage_key}
    end
  end

  defp extracted_text_storage_key(%LoanDocument{id: id}) do
    "loan-documents/#{id}/extracted-text.txt"
  end

  defp extract_pdf_text(path) do
    with {:ok, text} <- run_pdftotext(path),
         {:ok, readable} <- readable_text(text) do
      {:ok, readable}
    else
      {:error, :no_readable_text} -> extract_ocr_pdf_text(path)
      {:error, _reason} = error -> error
    end
  end

  defp extract_ocr_pdf_text(path) do
    try do
      with {:ok, ocr_path} <- run_ocrmypdf(path),
           {:ok, text} <- run_pdftotext(ocr_path),
           {:ok, readable} <- readable_text(text) do
        {:ok, readable}
      else
        {:error, _reason} = error -> error
      end
    after
      cleanup_ocr_path(path)
    end
  end

  defp extract_image_text(path) do
    with {:ok, text} <- run_tesseract(path),
         {:ok, readable} <- readable_text(text) do
      {:ok, readable}
    else
      {:error, _reason} = error -> error
    end
  end

  defp run_pdftotext(path) do
    with {:ok, executable} <- find_executable("pdftotext"),
         {output, 0} <- System.cmd(executable, ["-layout", path, "-"], stderr_to_stdout: true) do
      {:ok, output}
    else
      {:error, _reason} = error -> error
      {_output, _status} -> {:error, :pdf_text_extraction_failed}
    end
  end

  defp run_ocrmypdf(path) do
    with {:ok, executable} <- find_executable("ocrmypdf") do
      ocr_path = ocr_output_path(path)

      case System.cmd(
             executable,
             ["--force-ocr", "--quiet", path, ocr_path],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> {:ok, ocr_path}
        {_output, _status} -> {:error, :pdf_ocr_failed}
      end
    else
      {:error, _reason} = error -> error
    end
  end

  defp run_tesseract(path) do
    with {:ok, executable} <- find_executable("tesseract"),
         {output, 0} <-
           System.cmd(executable, [path, "stdout", "--psm", "6"], stderr_to_stdout: true) do
      {:ok, output}
    else
      {:error, _reason} = error -> error
      {_output, _status} -> {:error, :image_ocr_failed}
    end
  end

  defp find_executable(name) do
    case System.find_executable(name) do
      nil -> {:error, String.to_atom("#{name}_not_available")}
      executable -> {:ok, executable}
    end
  end

  defp ocr_output_path(path), do: "#{path}.ocr.pdf"

  defp cleanup_ocr_path(path) do
    path
    |> ocr_output_path()
    |> File.rm()
  end

  defp readable_text(content) when is_binary(content) do
    text =
      content
      |> String.replace(<<0>>, " ")
      |> String.replace(~r/[^\x09\x0A\x0D\x20-\x7E]/, " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if String.length(text) >= 20 do
      {:ok, text}
    else
      {:error, :no_readable_text}
    end
  end

  defp mark_loan_document_status(%LoanDocument{} = document, status) do
    document
    |> LoanDocument.changeset(%{status: status})
    |> Repo.update()
    |> case do
      {:ok, _document} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp mark_failed_document_extraction(user_id, document_id) do
    mark_document_status(user_id, document_id, "failed")
  end

  defp mark_document_status(user_id, document_id, status) do
    with {:ok, document} <- fetch_loan_document(user_id, document_id, preload: []) do
      mark_loan_document_status(document, status)
    end
  end

  defp scenario_attrs_from_quote(user, mortgage, quote, attrs) do
    attrs = normalize_attr_map(attrs)

    %{
      "user_id" => normalize_user_id(user),
      "mortgage_id" => quote.mortgage_id,
      "lender_quote_id" => quote.id,
      "name" => Map.get(attrs, "name") || "#{quote.lender_name} quote",
      "scenario_type" => "lender_quote",
      "product_type" => quote.product_type,
      "new_term_months" => quote.term_months,
      "new_interest_rate" => quote.interest_rate,
      "new_apr" => quote.apr,
      "new_principal_amount" =>
        Map.get(attrs, "new_principal_amount") || mortgage.current_balance,
      "points" => quote.points,
      "lender_credit_amount" => quote.lender_credit_amount,
      "rate_source_type" => "lender_quote",
      "status" => "draft"
    }
    |> Map.merge(Map.take(attrs, ["name", "new_principal_amount", "status"]))
  end

  defp scenario_attrs_from_rate_observation(
         %RateObservation{} = observation,
         user,
         %Mortgage{} = mortgage
       ) do
    source_type =
      case observation.rate_source do
        %RateSource{source_type: source_type} -> source_type
        _ -> "rate_observation"
      end

    %{
      "user_id" => normalize_user_id(user),
      "mortgage_id" => mortgage.id,
      "name" => default_rate_observation_scenario_name(observation),
      "scenario_type" => "rate_observation",
      "product_type" => observation.product_type || "fixed",
      "new_term_months" => observation.term_months,
      "new_interest_rate" => observation.rate,
      "new_apr" => observation.apr,
      "new_principal_amount" => mortgage.current_balance,
      "points" => observation.points,
      "rate_source_type" => source_type,
      "status" => "draft"
    }
  end

  defp default_rate_observation_scenario_name(%RateObservation{} = observation) do
    term_years = div(observation.term_months || 0, 12)

    rate =
      observation.rate
      |> Decimal.mult(Decimal.new("100"))
      |> Decimal.round(2)
      |> Decimal.to_string(:normal)

    "#{term_years}-year benchmark at #{rate}%"
  end

  defp insert_quote_fee_items(multi, quote) do
    multi
    |> maybe_insert_quote_closing_cost_item(quote)
    |> maybe_insert_quote_cash_timing_item(quote)
  end

  defp maybe_insert_quote_closing_cost_item(multi, quote) do
    if quote.estimated_closing_costs_expected do
      Multi.insert(multi, :quote_closing_costs, fn %{scenario: scenario} ->
        RefinanceFeeItem.changeset(%RefinanceFeeItem{}, %{
          refinance_scenario_id: scenario.id,
          category: "lender_quote_costs",
          name: "Estimated lender quote costs",
          low_amount: quote.estimated_closing_costs_low,
          expected_amount: quote.estimated_closing_costs_expected,
          high_amount: quote.estimated_closing_costs_high,
          kind: "fee",
          paid_at_closing: true,
          financed: false,
          is_true_cost: true,
          is_prepaid_or_escrow: false,
          required: false,
          sort_order: 0,
          notes: "Seeded from lender quote #{quote.lender_name}"
        })
      end)
    else
      multi
    end
  end

  defp maybe_insert_quote_cash_timing_item(multi, quote) do
    timing_cost = quote_cash_timing_cost(quote)

    if timing_cost && Decimal.compare(timing_cost, Decimal.new("0")) == :gt do
      Multi.insert(multi, :quote_cash_timing_costs, fn %{scenario: scenario} ->
        RefinanceFeeItem.changeset(%RefinanceFeeItem{}, %{
          refinance_scenario_id: scenario.id,
          category: "cash_to_close_timing",
          name: "Estimated prepaid and escrow timing costs",
          expected_amount: timing_cost,
          kind: "timing_cost",
          paid_at_closing: true,
          financed: false,
          is_true_cost: false,
          is_prepaid_or_escrow: true,
          required: false,
          sort_order: 1,
          notes: "Cash-to-close amount above quoted closing costs."
        })
      end)
    else
      multi
    end
  end

  defp quote_cash_timing_cost(%LenderQuote{
         estimated_cash_to_close_expected: %Decimal{} = cash_to_close,
         estimated_closing_costs_expected: %Decimal{} = closing_costs
       }) do
    Decimal.sub(cash_to_close, closing_costs)
  end

  defp quote_cash_timing_cost(_quote), do: nil

  defp mortgage_attrs_from_extraction(%LoanDocumentExtraction{extracted_payload: payload})
       when is_map(payload) do
    attrs =
      payload
      |> normalize_attr_map()
      |> normalize_mortgage_extraction_aliases()
      |> Map.take(@mortgage_extraction_fields)

    if attrs == %{} do
      {:error, :no_applicable_fields}
    else
      {:ok, attrs}
    end
  end

  defp mortgage_attrs_from_extraction(_extraction), do: {:error, :no_applicable_fields}

  defp lender_quote_attrs_from_extraction(%LoanDocumentExtraction{} = extraction)
       when is_map(extraction.extracted_payload) do
    attrs =
      extraction.extracted_payload
      |> normalize_attr_map()
      |> normalize_lender_quote_extraction_aliases()
      |> Map.take(@lender_quote_extraction_fields)

    if attrs == %{} do
      {:error, :no_applicable_quote_fields}
    else
      {:ok,
       attrs
       |> Map.put_new("quote_source", "document")
       |> Map.put_new("loan_type", "mortgage")
       |> Map.put_new("status", "active")
       |> Map.put(
         "raw_payload",
         %{
           "loan_document_extraction_id" => extraction.id,
           "source_citations" => extraction.source_citations || %{}
         }
       )}
    end
  end

  defp lender_quote_attrs_from_extraction(_extraction), do: {:error, :no_applicable_quote_fields}

  defp refinance_scenario_attrs_from_extraction(user, mortgage, extraction, attrs)
       when is_map(extraction.extracted_payload) do
    attrs = normalize_attr_map(attrs)

    extracted_attrs =
      extraction.extracted_payload
      |> normalize_attr_map()
      |> normalize_refinance_scenario_extraction_aliases()

    scenario_attrs =
      extracted_attrs
      |> Map.take(@refinance_scenario_extraction_fields)
      |> Map.put_new("new_principal_amount", mortgage.current_balance)
      |> Map.put("user_id", normalize_user_id(user))
      |> Map.put("mortgage_id", extraction.mortgage_id)
      |> Map.put_new("name", document_scenario_name(extracted_attrs))
      |> Map.put("scenario_type", "document_extraction")
      |> Map.put("rate_source_type", "document_extraction")
      |> Map.put_new("status", "draft")
      |> Map.merge(Map.take(attrs, ["name", "new_principal_amount", "status"]))

    if missing_refinance_scenario_inputs?(scenario_attrs) do
      {:error, :no_applicable_scenario_fields}
    else
      {:ok, scenario_attrs, extraction_fee_attrs(extracted_attrs)}
    end
  end

  defp refinance_scenario_attrs_from_extraction(_user, _mortgage, _extraction, _attrs),
    do: {:error, :no_applicable_scenario_fields}

  defp normalize_refinance_scenario_extraction_aliases(attrs) do
    attrs
    |> normalize_lender_quote_extraction_aliases()
    |> maybe_copy_alias("term_months", "new_term_months")
    |> maybe_copy_alias("interest_rate", "new_interest_rate")
    |> maybe_copy_alias("apr", "new_apr")
    |> maybe_copy_alias("loan_amount", "new_principal_amount")
    |> maybe_copy_alias("new_loan_amount", "new_principal_amount")
    |> maybe_copy_alias("principal_amount", "new_principal_amount")
  end

  defp missing_refinance_scenario_inputs?(attrs) do
    missing_or_blank?(Map.get(attrs, "new_term_months")) or
      missing_or_blank?(Map.get(attrs, "new_interest_rate")) or
      missing_or_blank?(Map.get(attrs, "new_principal_amount"))
  end

  defp missing_or_blank?(nil), do: true
  defp missing_or_blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp missing_or_blank?(_value), do: false

  defp document_scenario_name(attrs) do
    lender_name = attrs |> Map.get("lender_name") |> blank_string_to_nil()

    if lender_name do
      "#{lender_name} document scenario"
    else
      "Document refinance scenario"
    end
  end

  defp blank_string_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp blank_string_to_nil(_value), do: nil

  defp extraction_fee_attrs(attrs) do
    %{
      closing_costs_low: Map.get(attrs, "estimated_closing_costs_low"),
      closing_costs_expected: Map.get(attrs, "estimated_closing_costs_expected"),
      closing_costs_high: Map.get(attrs, "estimated_closing_costs_high"),
      cash_to_close_expected: Map.get(attrs, "estimated_cash_to_close_expected"),
      lender_name: Map.get(attrs, "lender_name")
    }
  end

  defp insert_extraction_fee_items(multi, fee_attrs) do
    multi
    |> maybe_insert_extraction_closing_cost_item(fee_attrs)
    |> maybe_insert_extraction_cash_timing_item(fee_attrs)
  end

  defp maybe_insert_extraction_closing_cost_item(multi, %{closing_costs_expected: nil}) do
    multi
  end

  defp maybe_insert_extraction_closing_cost_item(multi, fee_attrs) do
    Multi.insert(multi, :extraction_closing_costs, fn %{scenario: scenario} ->
      RefinanceFeeItem.changeset(%RefinanceFeeItem{}, %{
        refinance_scenario_id: scenario.id,
        category: "document_extraction_costs",
        name: "Extracted refinance costs",
        low_amount: fee_attrs.closing_costs_low,
        expected_amount: fee_attrs.closing_costs_expected,
        high_amount: fee_attrs.closing_costs_high,
        kind: "fee",
        paid_at_closing: true,
        financed: false,
        is_true_cost: true,
        is_prepaid_or_escrow: false,
        required: false,
        sort_order: 0,
        notes: extraction_fee_note(fee_attrs)
      })
    end)
  end

  defp maybe_insert_extraction_cash_timing_item(multi, fee_attrs) do
    timing_cost =
      cash_timing_cost(
        fee_attrs.cash_to_close_expected,
        fee_attrs.closing_costs_expected
      )

    if timing_cost && Decimal.compare(timing_cost, Decimal.new("0")) == :gt do
      Multi.insert(multi, :extraction_cash_timing_costs, fn %{scenario: scenario} ->
        RefinanceFeeItem.changeset(%RefinanceFeeItem{}, %{
          refinance_scenario_id: scenario.id,
          category: "cash_to_close_timing",
          name: "Extracted prepaid and escrow timing costs",
          expected_amount: timing_cost,
          kind: "timing_cost",
          paid_at_closing: true,
          financed: false,
          is_true_cost: false,
          is_prepaid_or_escrow: true,
          required: false,
          sort_order: 1,
          notes: "Cash-to-close amount above extracted closing costs."
        })
      end)
    else
      multi
    end
  end

  defp cash_timing_cost(cash_to_close, closing_costs) do
    with {:ok, cash_to_close} <- Decimal.cast(cash_to_close),
         {:ok, closing_costs} <- Decimal.cast(closing_costs) do
      Decimal.sub(cash_to_close, closing_costs)
    else
      _ -> nil
    end
  end

  defp extraction_fee_note(%{lender_name: lender_name}) when is_binary(lender_name) do
    "Seeded from confirmed document extraction for #{lender_name}"
  end

  defp extraction_fee_note(_fee_attrs), do: "Seeded from confirmed document extraction"

  defp normalize_mortgage_extraction_aliases(attrs) do
    attrs
    |> maybe_copy_alias("interest_rate", "current_interest_rate")
    |> maybe_copy_alias("principal_balance", "current_balance")
    |> maybe_copy_alias("unpaid_principal_balance", "current_balance")
    |> maybe_copy_alias("monthly_payment", "monthly_payment_total")
  end

  defp normalize_lender_quote_extraction_aliases(attrs) do
    attrs
    |> maybe_copy_alias("current_interest_rate", "interest_rate")
    |> maybe_copy_alias("new_interest_rate", "interest_rate")
    |> maybe_copy_alias("monthly_payment", "estimated_monthly_payment_expected")
    |> maybe_copy_alias("monthly_payment_total", "estimated_monthly_payment_expected")
    |> maybe_copy_alias("new_monthly_payment", "estimated_monthly_payment_expected")
    |> maybe_copy_alias("closing_costs", "estimated_closing_costs_expected")
    |> maybe_copy_alias("cash_to_close", "estimated_cash_to_close_expected")
    |> maybe_copy_alias("new_term_months", "term_months")
  end

  defp maybe_copy_alias(attrs, source_key, target_key) do
    if Map.has_key?(attrs, source_key) and not Map.has_key?(attrs, target_key) do
      Map.put(attrs, target_key, Map.fetch!(attrs, source_key))
    else
      attrs
    end
  end

  defp normalize_decimal(%Decimal{} = value), do: value

  defp normalize_decimal(value) do
    case Decimal.cast(value) do
      {:ok, decimal} -> decimal
      :error -> Decimal.new("0")
    end
  end

  defp fetch_scenario_for_child_write(user, %RefinanceScenario{} = scenario) do
    fetch_refinance_scenario(user, scenario.id, preload: [])
  end

  defp fetch_scenario_for_child_write(user, scenario_id) do
    fetch_refinance_scenario(user, scenario_id, preload: [])
  end

  defp fetch_scenario_for_analysis(user, %RefinanceScenario{} = scenario) do
    fetch_refinance_scenario(user, scenario.id, preload: [:mortgage, :fee_items])
  end

  defp fetch_scenario_for_analysis(user, scenario_id) do
    fetch_refinance_scenario(user, scenario_id, preload: [:mortgage, :fee_items])
  end

  defp sum_fee_items(fee_items, :true_cost) do
    Enum.reduce(fee_items, Decimal.new("0"), fn fee_item, acc ->
      if fee_item.is_true_cost and not fee_item.is_prepaid_or_escrow do
        add_signed_fee(acc, fee_item)
      else
        acc
      end
    end)
  end

  defp sum_fee_items(fee_items, :timing_cost) do
    Enum.reduce(fee_items, Decimal.new("0"), fn fee_item, acc ->
      if fee_item.is_prepaid_or_escrow or fee_item.kind == "timing_cost" do
        add_signed_fee(acc, fee_item)
      else
        acc
      end
    end)
  end

  defp add_signed_fee(acc, fee_item) do
    amount = fee_item_amount(fee_item)

    if fee_item.kind in ["lender_credit", "escrow_refund", "waived_fee", "other_credit"] do
      Decimal.sub(acc, amount)
    else
      Decimal.add(acc, amount)
    end
  end

  defp fee_item_amount(fee_item) do
    cond do
      match?(%Decimal{}, fee_item.expected_amount) -> fee_item.expected_amount
      match?(%Decimal{}, fee_item.fixed_amount) -> fee_item.fixed_amount
      true -> Decimal.new("0")
    end
  end

  defp analysis_result_attrs(
         user,
         scenario,
         analysis,
         true_refinance_cost,
         cash_to_close_timing_cost
       ) do
    %{
      user_id: normalize_user_id(user),
      mortgage_id: scenario.mortgage_id,
      refinance_scenario_id: scenario.id,
      analysis_version: @analysis_version,
      current_monthly_payment: analysis.current_monthly_payment,
      new_monthly_payment_low: analysis.payment_range.low,
      new_monthly_payment_expected: analysis.payment_range.expected,
      new_monthly_payment_high: analysis.payment_range.high,
      monthly_savings_low: analysis.monthly_savings_range.low,
      monthly_savings_expected: analysis.monthly_savings_range.expected,
      monthly_savings_high: analysis.monthly_savings_range.high,
      true_refinance_cost_low: analysis.true_refinance_cost_range.low,
      true_refinance_cost_expected: analysis.true_refinance_cost_range.expected,
      true_refinance_cost_high: analysis.true_refinance_cost_range.high,
      cash_to_close_low: analysis.cash_to_close_range.low,
      cash_to_close_expected: analysis.cash_to_close_range.expected,
      cash_to_close_high: analysis.cash_to_close_range.high,
      break_even_months_low: analysis.break_even_range.low,
      break_even_months_expected: analysis.break_even_range.expected,
      break_even_months_high: analysis.break_even_range.high,
      current_full_term_total_payment: analysis.current_full_term_total_payment,
      current_full_term_interest_cost: analysis.current_full_term_interest_cost,
      new_full_term_total_payment_expected: analysis.new_full_term_total_payment,
      new_full_term_interest_cost_expected: analysis.new_full_term_interest_cost,
      full_term_finance_cost_delta_expected: analysis.full_term_finance_cost_delta,
      warnings: analysis.warnings,
      assumptions: %{
        "true_refinance_cost_expected" => Decimal.to_string(true_refinance_cost),
        "cash_to_close_timing_cost_expected" => Decimal.to_string(cash_to_close_timing_cost),
        "new_term_months" => scenario.new_term_months,
        "new_interest_rate" => Decimal.to_string(scenario.new_interest_rate),
        "new_principal_amount" => Decimal.to_string(scenario.new_principal_amount)
      },
      computed_at: DateTime.utc_now()
    }
  end

  defp ensure_rate_source_enabled(%RateSource{enabled: true}), do: :ok
  defp ensure_rate_source_enabled(%RateSource{}), do: {:error, :disabled}

  defp configured_rate_observations(%RateSource{config: config}) when is_map(config) do
    case Map.get(config, "observations") || Map.get(config, :observations) do
      observations when is_list(observations) and observations != [] -> {:ok, observations}
      _value -> {:error, :no_configured_observations}
    end
  end

  defp configured_rate_observations(_source), do: {:error, :no_configured_observations}

  defp import_rate_observations(%RateSource{} = source, observations) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    multi =
      observations
      |> Enum.with_index()
      |> Enum.reduce(Multi.new(), fn {attrs, index}, multi ->
        Multi.insert(multi, {:observation, index}, rate_import_changeset(source, attrs, now))
      end)
      |> Multi.update(:source, rate_source_success_changeset(source, now))

    case Repo.transaction(multi) do
      {:ok, changes} ->
        imported =
          changes
          |> Enum.filter(fn {key, _value} -> match?({:observation, _index}, key) end)
          |> Enum.sort_by(fn {{:observation, index}, _value} -> index end)
          |> Enum.map(fn {_key, observation} -> Repo.preload(observation, :rate_source) end)

        {:ok, %{source: changes.source, imported: imported}}

      {:error, _operation, %Ecto.Changeset{} = changeset, _changes} ->
        mark_rate_source_import_error(source, inspect(changeset.errors))
        {:error, changeset}
    end
  end

  defp rate_import_changeset(source, attrs, now) do
    attrs = normalize_attr_map(attrs)

    RateObservation.changeset(
      %RateObservation{},
      attrs
      |> Map.put("rate_source_id", source.id)
      |> Map.put_new("provider_key", source.provider_key)
      |> Map.put_new("observed_at", now)
      |> Map.put_new("imported_at", now)
      |> Map.update("raw_payload", attrs, fn
        payload when is_map(payload) -> payload
        _value -> attrs
      end)
    )
  end

  defp rate_source_success_changeset(%RateSource{} = source, now) do
    RateSource.changeset(source, %{
      last_success_at: now,
      last_error_at: nil,
      last_error_message: nil
    })
  end

  defp mark_rate_source_import_error(%RateSource{} = source, message) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    source
    |> RateSource.changeset(%{
      last_error_at: now,
      last_error_message: String.slice(message, 0, 2_000)
    })
    |> Repo.update()

    :ok
  end

  defp maybe_preload_query(query, preload) when is_list(preload) and preload != [] do
    preload(query, ^preload)
  end

  defp maybe_preload_query(query, _), do: query

  defp maybe_filter_result_mortgage(query, opts) do
    case Keyword.get(opts, :mortgage_id) do
      nil -> query
      %Mortgage{id: id} -> where(query, [result], result.mortgage_id == ^id)
      id -> where(query, [result], result.mortgage_id == ^id)
    end
  end

  defp maybe_filter_result_scenario(query, opts) do
    case Keyword.get(opts, :refinance_scenario_id) do
      nil -> query
      %RefinanceScenario{id: id} -> where(query, [result], result.refinance_scenario_id == ^id)
      id -> where(query, [result], result.refinance_scenario_id == ^id)
    end
  end

  defp maybe_filter_rate_source_enabled(query, opts) do
    case Keyword.get(opts, :enabled) do
      nil -> query
      enabled when is_boolean(enabled) -> where(query, [source], source.enabled == ^enabled)
      _value -> query
    end
  end

  defp maybe_filter_rate_observation_source(query, opts) do
    case Keyword.get(opts, :rate_source_id) do
      nil -> query
      %RateSource{id: id} -> where(query, [observation], observation.rate_source_id == ^id)
      id -> where(query, [observation], observation.rate_source_id == ^id)
    end
  end

  defp maybe_filter_rate_observation_loan_type(query, opts) do
    case Keyword.get(opts, :loan_type) do
      nil -> query
      loan_type -> where(query, [observation], observation.loan_type == ^loan_type)
    end
  end

  defp maybe_filter_rate_observation_product_type(query, opts) do
    case Keyword.get(opts, :product_type) do
      nil -> query
      product_type -> where(query, [observation], observation.product_type == ^product_type)
    end
  end

  defp maybe_filter_rate_observation_term(query, opts) do
    case Keyword.get(opts, :term_months) do
      nil -> query
      term_months -> where(query, [observation], observation.term_months == ^term_months)
    end
  end

  defp maybe_limit(query, limit) when is_integer(limit) and limit > 0 do
    limit(query, ^limit)
  end

  defp maybe_limit(query, _limit), do: query

  defp normalize_attr_map(attrs) do
    attrs
    |> Map.new()
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, normalize_key(key), value)
    end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key

  defp normalize_id(%Mortgage{id: id}), do: id
  defp normalize_id(%RefinanceScenario{id: id}), do: id
  defp normalize_id(%LoanDocument{id: id}), do: id
  defp normalize_id(%LenderQuote{id: id}), do: id
  defp normalize_id(%RateSource{id: id}), do: id
  defp normalize_id(%RateObservation{id: id}), do: id
  defp normalize_id(id), do: id

  defp normalize_user_id(%User{id: user_id}), do: user_id
  defp normalize_user_id(user_id) when is_binary(user_id), do: user_id
end
