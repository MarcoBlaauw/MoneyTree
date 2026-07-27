defmodule MoneyTree.Assets do
  @moduledoc """
  Tools for managing tangible assets and aggregations for the dashboard.
  """

  import Ecto.Query, warn: false

  alias Decimal
  alias Ecto.Multi
  alias MoneyTree.Accounts
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Assets.Asset
  alias MoneyTree.Assets.AssetValuation
  alias MoneyTree.Assets.ProviderRegistry
  alias MoneyTree.Assets.ValuationProviderRun
  alias MoneyTree.Assets.VehicleProfile
  alias MoneyTree.Assets.Workers.ValuationRefreshWorker
  alias MoneyTree.Loans.Loan
  alias MoneyTree.Mortgages.Mortgage
  alias MoneyTree.Repo
  alias MoneyTree.Users.User

  @default_stale_after_days 90
  @marketcheck_calls_per_second 5
  @outgoing_provider_run_statuses ~w(started ok error rate_limited)
  @type asset_params :: map()
  @type summary :: %{
          assets: [map()],
          totals: [map()],
          total_count: non_neg_integer()
        }

  @default_preload [:account, :linked_loan, :linked_mortgage, :vehicle_profile]

  @doc """
  Lists assets the user can access.
  """
  @spec list_assets(User.t() | binary(), keyword()) :: [Asset.t()]
  def list_assets(user, opts \\ []) do
    preload = Keyword.get(opts, :preload, @default_preload)

    user
    |> accessible_assets_query(opts)
    |> maybe_preload_query(preload)
    |> Repo.all()
  end

  @doc """
  Fetches a single asset accessible to the user.
  """
  @spec fetch_asset(User.t() | binary(), binary(), keyword()) ::
          {:ok, Asset.t()} | {:error, :not_found}
  def fetch_asset(user, asset_id, opts \\ []) do
    preload = Keyword.get(opts, :preload, @default_preload)

    user
    |> accessible_assets_query(id: asset_id)
    |> maybe_preload_query(preload)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      %Asset{} = asset -> {:ok, asset}
    end
  end

  @doc """
  Returns an asset, raising if not found or inaccessible.
  """
  @spec get_asset!(User.t() | binary(), binary(), keyword()) :: Asset.t()
  def get_asset!(user, asset_id, opts \\ []) do
    case fetch_asset(user, asset_id, opts) do
      {:ok, asset} -> asset
      {:error, :not_found} -> raise Ecto.NoResultsError, queryable: Asset
    end
  end

  @doc """
  Creates a new asset owned by the user and optionally linked to an accessible account.
  """
  @spec create_asset(User.t() | binary(), asset_params(), keyword()) ::
          {:ok, Asset.t()} | {:error, Ecto.Changeset.t()} | {:error, :unauthorized}
  def create_asset(user, attrs, opts \\ []) do
    attrs =
      attrs
      |> Map.new()
      |> put_attr(:user_id, user_id(user))

    preload = Keyword.get(opts, :preload, @default_preload)
    account_id = extract_account_id(attrs)
    linked_loan_id = extract_id(attrs, :linked_loan_id)
    linked_mortgage_id = extract_id(attrs, :linked_mortgage_id)

    with :ok <- ensure_optional_account_access(user, account_id),
         :ok <- ensure_optional_debt_access(user, Loan, linked_loan_id),
         :ok <- ensure_optional_debt_access(user, Mortgage, linked_mortgage_id) do
      Multi.new()
      |> Multi.insert(:asset, Asset.changeset(%Asset{}, attrs))
      |> Multi.insert(:valuation, fn %{asset: asset} ->
        initial_valuation_changeset(asset)
      end)
      |> Multi.update(:cached_asset, fn %{asset: asset, valuation: valuation} ->
        Ecto.Changeset.change(asset,
          valuation_amount: valuation.amount,
          valuation_currency: valuation.currency,
          last_valued_on: valuation.valued_on
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{cached_asset: asset}} ->
          {:ok, maybe_preload(asset, preload)}

        {:error, _operation, %Ecto.Changeset{} = changeset, _changes} ->
          {:error, changeset}
      end
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  @doc """
  Updates an accessible asset, optionally moving it between accessible accounts.
  """
  @spec update_asset(User.t() | binary(), Asset.t(), asset_params(), keyword()) ::
          {:ok, Asset.t()} | {:error, Ecto.Changeset.t()} | {:error, :unauthorized}
  def update_asset(user, %Asset{} = asset, attrs, opts \\ []) do
    attrs =
      attrs
      |> Map.new()
      |> put_attr(:user_id, asset.user_id)

    preload = Keyword.get(opts, :preload, @default_preload)

    target_account_id = target_id(attrs, :account_id, asset.account_id)
    target_loan_id = target_id(attrs, :linked_loan_id, asset.linked_loan_id)
    target_mortgage_id = target_id(attrs, :linked_mortgage_id, asset.linked_mortgage_id)

    with :ok <- ensure_asset_access(user, asset),
         :ok <- ensure_optional_account_access(user, target_account_id),
         :ok <- ensure_optional_debt_access(user, Loan, target_loan_id),
         :ok <- ensure_optional_debt_access(user, Mortgage, target_mortgage_id),
         changeset <- Asset.changeset(asset, attrs) do
      valuation_changed? =
        Enum.any?(
          [:valuation_amount, :valuation_currency, :last_valued_on],
          &Ecto.Changeset.changed?(changeset, &1)
        )

      Multi.new()
      |> Multi.update(:asset, changeset)
      |> maybe_append_updated_valuation(valuation_changed?)
      |> Repo.transaction()
      |> case do
        {:ok, changes} ->
          updated = Map.get(changes, :cached_asset, changes.asset)
          {:ok, maybe_preload(updated, preload)}

        {:error, _operation, %Ecto.Changeset{} = changeset, _changes} ->
          {:error, changeset}
      end
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  @doc """
  Deletes an accessible asset.
  """
  @spec delete_asset(User.t() | binary(), Asset.t()) ::
          {:ok, Asset.t()} | {:error, :unauthorized} | {:error, Ecto.Changeset.t()}
  def delete_asset(user, %Asset{} = asset) do
    with :ok <- ensure_asset_access(user, asset),
         {:ok, deleted} <- Repo.delete(asset) do
      {:ok, deleted}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  @doc """
  Returns a changeset for tracking asset changes in forms.
  """
  @spec change_asset(Asset.t(), asset_params()) :: Ecto.Changeset.t()
  def change_asset(%Asset{} = asset, attrs \\ %{}) do
    Asset.changeset(asset, attrs)
  end

  @doc """
  Inserts an immutable valuation snapshot and refreshes the asset's cached latest value.
  """
  @spec record_valuation(User.t() | binary(), Asset.t(), map()) ::
          {:ok, %{asset: Asset.t(), valuation: AssetValuation.t()}}
          | {:error, :unauthorized | Ecto.Changeset.t()}
  def record_valuation(user, %Asset{} = asset, attrs) when is_map(attrs) do
    with :ok <- ensure_asset_access(user, asset) do
      valuation_attrs =
        attrs
        |> Map.new()
        |> put_attr(:asset_id, asset.id)
        |> put_new_attr(:currency, asset.valuation_currency)
        |> put_new_attr(:source, "manual")
        |> put_new_attr(:valued_on, Date.utc_today())

      Multi.new()
      |> Multi.insert(:valuation, AssetValuation.changeset(%AssetValuation{}, valuation_attrs))
      |> Multi.run(:latest_valuation, fn repo, _changes ->
        {:ok, latest_valuation(repo, asset.id)}
      end)
      |> Multi.update(:asset, fn %{latest_valuation: latest} ->
        Ecto.Changeset.change(asset,
          valuation_amount: latest.amount,
          valuation_currency: latest.currency,
          last_valued_on: latest.valued_on
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{asset: updated, valuation: valuation}} ->
          {:ok, %{asset: updated, valuation: valuation}}

        {:error, _operation, %Ecto.Changeset{} = changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Lists valuation snapshots newest first for an accessible asset.
  """
  @spec list_asset_valuations(User.t() | binary(), Asset.t()) ::
          {:ok, [AssetValuation.t()]} | {:error, :unauthorized}
  def list_asset_valuations(user, %Asset{} = asset) do
    with :ok <- ensure_asset_access(user, asset) do
      valuations =
        AssetValuation
        |> where([valuation], valuation.asset_id == ^asset.id)
        |> order_by([valuation],
          desc: valuation.valued_on,
          desc: valuation.inserted_at,
          desc: valuation.id
        )
        |> Repo.all()

      {:ok, valuations}
    end
  end

  @doc """
  Creates or updates the one-to-one vehicle profile for an accessible vehicle asset.
  """
  @spec upsert_vehicle_profile(User.t() | binary(), Asset.t(), map()) ::
          {:ok, VehicleProfile.t()}
          | {:error, :unauthorized | :not_vehicle | Ecto.Changeset.t()}
  def upsert_vehicle_profile(user, %Asset{} = asset, attrs) when is_map(attrs) do
    with :ok <- ensure_asset_access(user, asset),
         :ok <- ensure_vehicle(asset) do
      profile = Repo.get_by(VehicleProfile, asset_id: asset.id) || %VehicleProfile{}

      attrs =
        attrs
        |> Map.new()
        |> put_attr(:asset_id, asset.id)

      profile
      |> VehicleProfile.changeset(attrs)
      |> Repo.insert_or_update()
    end
  end

  @doc """
  Returns a changeset for a vehicle profile form.
  """
  def change_vehicle_profile(%VehicleProfile{} = profile, attrs \\ %{}) do
    VehicleProfile.changeset(profile, attrs)
  end

  @doc """
  Returns a changeset for a manual valuation form.
  """
  def change_asset_valuation(%Asset{} = asset, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new()
      |> put_attr(:asset_id, asset.id)
      |> put_new_attr(:currency, asset.valuation_currency)
      |> put_new_attr(:source, "manual")
      |> put_new_attr(:valued_on, Date.utc_today())

    AssetValuation.changeset(%AssetValuation{}, attrs)
  end

  @doc """
  Returns persisted monthly provider usage for the deployment-wide API key.

  Started requests count immediately and remain counted after failures. This is
  intentionally conservative because a remote request may consume quota even
  when its response cannot be persisted locally.
  """
  def provider_usage(provider_key \\ "marketcheck", opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    monthly_limit = Keyword.get(opts, :monthly_limit, ProviderRegistry.monthly_request_limit())
    request_month = month_start(now)

    used =
      ValuationProviderRun
      |> where(
        [run],
        run.provider_key == ^provider_key and run.request_month == ^request_month and
          run.status in ^@outgoing_provider_run_statuses
      )
      |> Repo.aggregate(:count, :id)

    %{
      provider_key: provider_key,
      request_month: request_month,
      used: used,
      limit: monthly_limit,
      remaining: max(monthly_limit - used, 0)
    }
  end

  @doc """
  Fetches a review-only VIN decode and price preview.

  The two provider calls share the normal deployment quota and rate controls.
  Results are kept separate from canonical asset data until
  `create_vehicle_from_preview/3` is explicitly called.
  """
  def preview_vehicle(user, attrs, opts \\ []) when is_map(attrs) do
    provider_key = Keyword.get(opts, :provider, "marketcheck")
    provider = Keyword.get(opts, :provider_module, ProviderRegistry.provider_module(provider_key))
    settings = Keyword.get(opts, :settings, ProviderRegistry.settings(provider_key))
    enabled? = Keyword.get(opts, :enabled, ProviderRegistry.enabled?(provider_key))
    now = Keyword.get(opts, :now, DateTime.utc_now())
    monthly_limit = Keyword.get(opts, :monthly_limit, ProviderRegistry.monthly_request_limit())

    with true <- enabled? || {:error, :disabled},
         true <- is_atom(provider) || {:error, :unknown_provider},
         true <- provider.configured?(settings) || {:error, :missing_api_key},
         {:ok, input} <- normalize_vehicle_preview_input(attrs),
         {:ok, decoded, _decode_run, decode_cached?} <-
           fetch_preview_part(
             user_id(user),
             provider_key,
             "vin_decode",
             input.vin,
             now,
             monthly_limit,
             fn -> provider.decode_vin(input.vin, settings) end
           ),
         {:ok, valuation, _valuation_run, valuation_cached?} <-
           fetch_preview_part(
             user_id(user),
             provider_key,
             "price_preview",
             "#{input.vin}:#{input.mileage}:#{input.market_region}",
             now,
             monthly_limit,
             fn ->
               provider.fetch_valuation(
                 %{
                   vin: input.vin,
                   mileage: input.mileage,
                   market_region: input.market_region
                 },
                 settings
               )
             end
           ) do
      {:ok,
       %{
         vin: input.vin,
         mileage: input.mileage,
         market_region: input.market_region,
         decoded: decoded,
         valuation: valuation,
         provider_key: provider_key,
         cached?: decode_cached? and valuation_cached?
       }}
    end
  end

  @doc """
  Persists a reviewed vehicle preview as one asset, profile, and provider valuation.
  """
  def create_vehicle_from_preview(user, preview, attrs)
      when is_map(preview) and is_map(attrs) do
    attrs = Map.new(attrs)
    owner_id = user_id(user)
    account_id = extract_account_id(attrs)
    linked_loan_id = extract_id(attrs, :linked_loan_id)
    linked_mortgage_id = extract_id(attrs, :linked_mortgage_id)
    valued_on = Date.utc_today()

    asset_attrs =
      attrs
      |> put_attr(:user_id, owner_id)
      |> put_attr(:asset_type, "vehicle")
      |> put_new_attr(:category, "vehicle")
      |> put_attr(:valuation_amount, preview.valuation.value)
      |> put_attr(:valuation_currency, "USD")
      |> put_new_attr(:ownership_type, "individual")
      |> put_attr(:last_valued_on, valued_on)

    profile_attrs = %{
      encrypted_vin: preview.vin,
      year: preview.decoded.year,
      make: preview.decoded.make,
      model: preview.decoded.model,
      trim: preview.decoded.trim,
      body_style: preview.decoded.body_style,
      mileage: preview.mileage,
      mileage_as_of: valued_on,
      market_region: preview.market_region
    }

    with :ok <- ensure_optional_account_access(user, account_id),
         :ok <- ensure_optional_debt_access(user, Loan, linked_loan_id),
         :ok <- ensure_optional_debt_access(user, Mortgage, linked_mortgage_id) do
      Multi.new()
      |> Multi.insert(:asset, Asset.changeset(%Asset{}, asset_attrs))
      |> Multi.insert(:vehicle_profile, fn %{asset: asset} ->
        VehicleProfile.changeset(
          %VehicleProfile{},
          Map.put(profile_attrs, :asset_id, asset.id)
        )
      end)
      |> Multi.insert(:valuation, fn %{asset: asset} ->
        AssetValuation.changeset(%AssetValuation{}, %{
          asset_id: asset.id,
          amount: preview.valuation.value,
          currency: "USD",
          source: "provider",
          provider_key: preview.provider_key,
          valued_on: valued_on,
          mileage: preview.mileage,
          value_low: Map.get(preview.valuation, :value_low),
          value_high: Map.get(preview.valuation, :value_high),
          confidence: Map.get(preview.valuation, :confidence),
          raw_response: preview.valuation.raw,
          manually_overridden: false
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{asset: asset}} ->
          {:ok, maybe_preload(asset, @default_preload)}

        {:error, _operation, %Ecto.Changeset{} = changeset, _changes} ->
          {:error, changeset}
      end
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  @doc """
  Returns whether an asset may make another provider request.

  The check is repeated transactionally while reserving quota, so this
  read-only helper is suitable for dispatch filtering but is not the budget
  enforcement boundary.
  """
  def vehicle_valuation_due?(%Asset{} = asset, provider_key \\ "marketcheck", opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    interval_days =
      Keyword.get(opts, :refresh_interval_days, ProviderRegistry.refresh_interval_days())

    provider_request_due?(asset.id, provider_key, now, interval_days) and
      not recent_manual_override?(asset.id, now, interval_days)
  end

  @doc """
  Fetches and persists one provider valuation under the hard monthly budget.
  """
  def refresh_vehicle_valuation(%Asset{} = asset, opts \\ []) do
    provider_key = Keyword.get(opts, :provider, "marketcheck")
    provider = Keyword.get(opts, :provider_module, ProviderRegistry.provider_module(provider_key))
    settings = Keyword.get(opts, :settings, ProviderRegistry.settings(provider_key))
    enabled? = Keyword.get(opts, :enabled, ProviderRegistry.enabled?(provider_key))
    now = Keyword.get(opts, :now, DateTime.utc_now())
    monthly_limit = Keyword.get(opts, :monthly_limit, ProviderRegistry.monthly_request_limit())

    interval_days =
      Keyword.get(opts, :refresh_interval_days, ProviderRegistry.refresh_interval_days())

    with true <- enabled? || {:error, :disabled},
         true <- is_atom(provider) || {:error, :unknown_provider},
         true <- provider.configured?(settings) || {:error, :missing_api_key},
         {:ok, refreshed_asset} <- fetch_asset(asset.user_id, asset.id),
         {:ok, vehicle_attrs} <- vehicle_provider_attrs(refreshed_asset),
         {:ok, run} <-
           reserve_provider_request(refreshed_asset, provider_key,
             now: now,
             monthly_limit: monthly_limit,
             refresh_interval_days: interval_days
           ) do
      fetch_and_persist_provider_valuation(
        provider,
        vehicle_attrs,
        settings,
        refreshed_asset,
        provider_key,
        run,
        now
      )
    end
  end

  @doc """
  Enqueues one vehicle valuation job when MarketCheck is configured.
  """
  def enqueue_vehicle_valuation_refresh(%Asset{} = asset) do
    if ProviderRegistry.configured?("marketcheck") do
      %{"asset_id" => asset.id, "provider" => "marketcheck"}
      |> ValuationRefreshWorker.new()
      |> Oban.insert()
    else
      {:error, :disabled}
    end
  end

  @doc """
  Lists vehicle assets that have enough provider input for dispatch checks.
  """
  def list_provider_ready_vehicles do
    Asset
    |> where([asset], asset.asset_type == "vehicle")
    |> join(:inner, [asset], profile in assoc(asset, :vehicle_profile))
    |> where(
      [_asset, profile],
      not is_nil(profile.encrypted_vin) and not is_nil(profile.mileage) and
        not is_nil(profile.market_region)
    )
    |> preload([_asset, profile], vehicle_profile: profile)
    |> Repo.all()
  end

  @doc """
  Builds formatted summaries for dashboard consumption.
  """
  @spec dashboard_summary(User.t() | binary(), keyword()) :: summary()
  def dashboard_summary(user, opts \\ []) do
    assets = list_assets(user, Keyword.put(opts, :preload, @default_preload))

    summaries = Enum.map(assets, &build_asset_summary(&1, opts))

    totals =
      summaries
      |> Enum.group_by(& &1.asset.valuation_currency)
      |> Enum.map(fn {currency, items} ->
        gross_value = sum_summary_decimals(items, :gross_value_amount)
        linked_debt = sum_summary_decimals(items, :linked_debt_amount)
        net_equity = Decimal.sub(gross_value, linked_debt)

        %{
          currency: currency,
          asset_count: length(items),
          gross_value_amount: gross_value,
          linked_debt_amount: linked_debt,
          net_equity_amount: net_equity,
          gross_value: Accounts.format_money(gross_value, currency, opts),
          gross_value_masked: Accounts.mask_money(gross_value, currency, opts),
          linked_debt: Accounts.format_money(linked_debt, currency, opts),
          linked_debt_masked: Accounts.mask_money(linked_debt, currency, opts),
          net_equity: Accounts.format_money(net_equity, currency, opts),
          net_equity_masked: Accounts.mask_money(net_equity, currency, opts),
          # Compatibility for dashboard consumers while they move to explicit gross/net labels.
          valuation: Accounts.format_money(gross_value, currency, opts),
          valuation_masked: Accounts.mask_money(gross_value, currency, opts)
        }
      end)
      |> Enum.sort_by(& &1.currency)

    %{
      assets: summaries,
      totals: totals,
      total_count: length(summaries)
    }
  end

  defp accessible_assets_query(user, opts) do
    account_subquery = Accounts.accessible_accounts_query(user)
    owner_id = user_id(user)

    Asset
    |> where(
      [asset],
      asset.user_id == ^owner_id or
        asset.account_id in subquery(from account in account_subquery, select: account.id)
    )
    |> maybe_filter_account(opts)
    |> maybe_filter_id(opts)
    |> order_by([asset], desc: asset.updated_at)
  end

  defp maybe_filter_account(query, opts) do
    case Keyword.get(opts, :account_id) do
      nil -> query
      %Account{id: account_id} -> where(query, [asset], asset.account_id == ^account_id)
      account_id -> where(query, [asset], asset.account_id == ^account_id)
    end
  end

  defp maybe_filter_id(query, opts) do
    case Keyword.get(opts, :id) do
      nil -> query
      id -> where(query, [asset], asset.id == ^id)
    end
  end

  defp maybe_preload_query(query, preload) when is_list(preload) and preload != [] do
    preload(query, ^preload)
  end

  defp maybe_preload_query(query, _), do: query

  defp ensure_optional_account_access(_user, nil), do: :ok

  defp ensure_optional_account_access(user, %Account{id: id}),
    do: ensure_optional_account_access(user, id)

  defp ensure_optional_account_access(user, account_id) when is_binary(account_id) do
    case Accounts.fetch_accessible_account(user, account_id) do
      {:ok, _account} -> :ok
      {:error, :not_found} -> {:error, :unauthorized}
    end
  end

  defp ensure_optional_account_access(_user, _other), do: {:error, :unauthorized}

  defp ensure_optional_debt_access(_user, _schema, nil), do: :ok

  defp ensure_optional_debt_access(user, schema, id)
       when schema in [Loan, Mortgage] and is_binary(id) do
    owner_id = user_id(user)

    if Repo.exists?(
         from record in schema, where: record.id == ^id and record.user_id == ^owner_id
       ),
       do: :ok,
       else: {:error, :unauthorized}
  end

  defp ensure_optional_debt_access(_user, _schema, _id), do: {:error, :unauthorized}

  defp ensure_asset_access(user, %Asset{id: asset_id}) do
    if Repo.exists?(accessible_assets_query(user, id: asset_id)),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp extract_account_id(attrs) do
    cond do
      Map.has_key?(attrs, :account_id) -> normalize_account_id(Map.get(attrs, :account_id))
      Map.has_key?(attrs, "account_id") -> normalize_account_id(Map.get(attrs, "account_id"))
      true -> nil
    end
  end

  defp normalize_account_id(%Account{id: id}), do: id

  defp normalize_account_id(id) when is_binary(id) do
    case String.trim(id) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_account_id(_), do: nil

  defp extract_id(attrs, key) do
    attrs
    |> Map.get(key, Map.get(attrs, Atom.to_string(key)))
    |> normalize_id()
  end

  defp normalize_id(%{id: id}) when is_binary(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case String.trim(id) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_id(_id), do: nil

  defp target_id(attrs, key, current_id) do
    if Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key)),
      do: extract_id(attrs, key),
      else: current_id
  end

  defp user_id(%User{id: id}), do: id
  defp user_id(id) when is_binary(id), do: id

  defp put_attr(attrs, key, value) do
    if string_keyed?(attrs),
      do: Map.put(attrs, Atom.to_string(key), value),
      else: Map.put(attrs, key, value)
  end

  defp put_new_attr(attrs, key, value) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) or Map.has_key?(attrs, string_key) -> attrs
      string_keyed?(attrs) -> Map.put(attrs, string_key, value)
      true -> Map.put(attrs, key, value)
    end
  end

  defp string_keyed?(attrs), do: Enum.any?(Map.keys(attrs), &is_binary/1)

  defp ensure_vehicle(%Asset{asset_type: "vehicle"}), do: :ok
  defp ensure_vehicle(%Asset{}), do: {:error, :not_vehicle}

  defp latest_valuation(repo, asset_id) do
    AssetValuation
    |> where([valuation], valuation.asset_id == ^asset_id)
    |> order_by([valuation],
      desc: valuation.valued_on,
      desc: valuation.inserted_at,
      desc: valuation.id
    )
    |> limit(1)
    |> repo.one!()
  end

  defp persist_provider_valuation(asset, normalized, provider_key, run, now, started_at) do
    attrs = %{
      amount: normalized.value,
      currency: "USD",
      source: "provider",
      provider_key: provider_key,
      valued_on: DateTime.to_date(now),
      confidence: Map.get(normalized, :confidence),
      mileage: asset.vehicle_profile.mileage,
      value_low: Map.get(normalized, :value_low),
      value_high: Map.get(normalized, :value_high),
      raw_response: normalized.raw,
      manually_overridden: false
    }

    case record_valuation(asset.user_id, asset, attrs) do
      {:ok, result} ->
        completed_run = finish_provider_run(run, "ok", now, started_at, nil)
        {:ok, Map.put(result, :provider_run, completed_run)}

      {:error, reason} ->
        _run = finish_provider_run(run, "error", now, started_at, reason)
        {:error, reason}
    end
  end

  defp fetch_and_persist_provider_valuation(
         provider,
         vehicle_attrs,
         settings,
         asset,
         provider_key,
         run,
         now
       ) do
    started_at = System.monotonic_time(:millisecond)

    case provider.fetch_valuation(vehicle_attrs, settings) do
      {:ok, normalized} ->
        persist_provider_valuation(asset, normalized, provider_key, run, now, started_at)

      {:error, reason} ->
        _run =
          finish_provider_run(run, provider_run_error_status(reason), now, started_at, reason)

        {:error, reason}
    end
  end

  defp fetch_preview_part(
         user_id,
         provider_key,
         request_kind,
         fingerprint_source,
         now,
         monthly_limit,
         fetch_fun
       ) do
    fingerprint = request_fingerprint(request_kind, fingerprint_source)

    case cached_preview_response(user_id, provider_key, request_kind, fingerprint, now) do
      {:ok, response, run} ->
        {:ok, response, run, true}

      :miss ->
        fetch_uncached_preview(
          user_id,
          provider_key,
          request_kind,
          fingerprint,
          now,
          monthly_limit,
          fetch_fun
        )
    end
  end

  defp fetch_uncached_preview(
         user_id,
         provider_key,
         request_kind,
         fingerprint,
         now,
         monthly_limit,
         fetch_fun
       ) do
    with {:ok, run} <-
           reserve_preview_request(
             user_id,
             provider_key,
             request_kind,
             fingerprint,
             now,
             monthly_limit
           ) do
      started_at = System.monotonic_time(:millisecond)
      complete_preview_fetch(fetch_fun.(), request_kind, run, now, started_at)
    end
  end

  defp complete_preview_fetch({:ok, response}, request_kind, run, now, started_at) do
    response_data = encode_preview_response(request_kind, response)
    completed_run = finish_provider_run(run, "ok", now, started_at, nil, response_data)
    {:ok, response, completed_run, false}
  end

  defp complete_preview_fetch({:error, reason}, _request_kind, run, now, started_at) do
    status = provider_run_error_status(reason)
    _run = finish_provider_run(run, status, now, started_at, reason)
    {:error, reason}
  end

  defp reserve_preview_request(
         user_id,
         provider_key,
         request_kind,
         fingerprint,
         now,
         monthly_limit
       ) do
    monthly_limit = min(monthly_limit, ProviderRegistry.hard_monthly_limit())
    request_month = month_start(now)
    lock_key = "#{provider_key}:#{Date.to_iso8601(request_month)}"
    recent_cutoff = DateTime.add(now, -60, :second)

    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [lock_key])

      reserve_preview_request_locked(%{
        user_id: user_id,
        provider_key: provider_key,
        request_kind: request_kind,
        fingerprint: fingerprint,
        now: now,
        recent_cutoff: recent_cutoff,
        request_month: request_month,
        monthly_limit: monthly_limit
      })
    end)
    |> case do
      {:ok, run} -> {:ok, run}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reserve_preview_request_locked(args) do
    cond do
      recent_preview_request?(args) ->
        Repo.rollback(:provider_request_recent)

      not provider_rate_window_available?(args.provider_key, args.now) ->
        Repo.rollback(:provider_rate_window_full)

      true ->
        insert_reserved_provider_run(
          %{
            user_id: args.user_id,
            provider_key: args.provider_key,
            request_kind: args.request_kind,
            request_fingerprint: args.fingerprint,
            requested_at: args.now,
            request_month: args.request_month
          },
          args.provider_key,
          args.now,
          args.monthly_limit
        )
    end
  end

  defp recent_preview_request?(%{
         user_id: user_id,
         provider_key: provider_key,
         request_kind: request_kind,
         fingerprint: fingerprint,
         recent_cutoff: recent_cutoff
       }) do
    Repo.exists?(
      from run in ValuationProviderRun,
        where:
          run.user_id == ^user_id and run.provider_key == ^provider_key and
            run.request_kind == ^request_kind and
            run.request_fingerprint == ^fingerprint and
            run.status in ^@outgoing_provider_run_statuses and
            run.requested_at > ^recent_cutoff
    )
  end

  defp cached_preview_response(user_id, provider_key, request_kind, fingerprint, now) do
    cutoff = DateTime.add(now, -1, :day)

    ValuationProviderRun
    |> where(
      [run],
      run.user_id == ^user_id and run.provider_key == ^provider_key and
        run.request_kind == ^request_kind and run.request_fingerprint == ^fingerprint and
        run.status == "ok" and not is_nil(run.response_data) and run.completed_at > ^cutoff
    )
    |> order_by([run], desc: run.completed_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> :miss
      run -> {:ok, decode_preview_response(request_kind, run.response_data), run}
    end
  end

  defp encode_preview_response("vin_decode", response) do
    %{
      "year" => response.year,
      "make" => response.make,
      "model" => response.model,
      "trim" => response.trim,
      "body_style" => response.body_style
    }
  end

  defp encode_preview_response("price_preview", response) do
    %{
      "value" => Decimal.to_string(response.value, :normal),
      "value_low" => decimal_to_string(Map.get(response, :value_low)),
      "value_high" => decimal_to_string(Map.get(response, :value_high)),
      "confidence" => Map.get(response, :confidence),
      "raw" => response.raw
    }
  end

  defp decode_preview_response("vin_decode", response) do
    %{
      year: response["year"],
      make: response["make"],
      model: response["model"],
      trim: response["trim"],
      body_style: response["body_style"]
    }
  end

  defp decode_preview_response("price_preview", response) do
    %{
      value: Decimal.new(response["value"]),
      value_low: string_to_decimal(response["value_low"]),
      value_high: string_to_decimal(response["value_high"]),
      confidence: response["confidence"],
      raw: response["raw"] || %{}
    }
  end

  defp request_fingerprint(request_kind, source) do
    :crypto.hash(:sha256, "#{request_kind}:#{source}")
    |> Base.encode16(case: :lower)
  end

  defp normalize_vehicle_preview_input(attrs) do
    vin =
      attrs
      |> attr_value(:vin)
      |> to_string()
      |> String.trim()
      |> String.upcase()

    market_region =
      attrs
      |> attr_value(:market_region)
      |> to_string()
      |> String.trim()

    mileage =
      attrs
      |> attr_value(:mileage)
      |> normalize_non_negative_integer()

    cond do
      not Regex.match?(~r/^[A-HJ-NPR-Z0-9]{17}$/, vin) ->
        {:error, :invalid_vin}

      is_nil(mileage) ->
        {:error, :invalid_mileage}

      not Regex.match?(~r/^\d{5}$/, market_region) ->
        {:error, :invalid_market_region}

      true ->
        {:ok, %{vin: vin, mileage: mileage, market_region: market_region}}
    end
  end

  defp attr_value(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp normalize_non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp normalize_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> nil
    end
  end

  defp normalize_non_negative_integer(_value), do: nil

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(%Decimal{} = value), do: Decimal.to_string(value, :normal)

  defp string_to_decimal(nil), do: nil
  defp string_to_decimal(value), do: Decimal.new(value)

  defp reserve_provider_request(asset, provider_key, opts) do
    now = Keyword.fetch!(opts, :now)

    monthly_limit =
      Keyword.fetch!(opts, :monthly_limit) |> min(ProviderRegistry.hard_monthly_limit())

    interval_days = Keyword.fetch!(opts, :refresh_interval_days)
    request_month = month_start(now)
    lock_key = "#{provider_key}:#{Date.to_iso8601(request_month)}"

    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [lock_key])

      reserve_provider_request_locked(
        asset,
        provider_key,
        now,
        interval_days,
        request_month,
        monthly_limit
      )
    end)
    |> case do
      {:ok, run} -> {:ok, run}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reserve_provider_request_locked(
         asset,
         provider_key,
         now,
         interval_days,
         request_month,
         monthly_limit
       ) do
    cond do
      not provider_request_due?(asset.id, provider_key, now, interval_days) ->
        Repo.rollback(:not_due)

      recent_manual_override?(asset.id, now, interval_days) ->
        Repo.rollback(:manual_override_recent)

      not provider_rate_window_available?(provider_key, now) ->
        Repo.rollback(:provider_rate_window_full)

      true ->
        insert_reserved_provider_run(
          %{
            asset_id: asset.id,
            provider_key: provider_key,
            request_kind: "valuation",
            requested_at: now,
            request_month: request_month
          },
          provider_key,
          now,
          monthly_limit
        )
    end
  end

  defp insert_reserved_provider_run(attrs, provider_key, now, monthly_limit) do
    usage = provider_usage(provider_key, now: now, monthly_limit: monthly_limit)

    case usage.remaining do
      0 ->
        Repo.rollback(:monthly_budget_exhausted)

      remaining ->
        attrs =
          Map.merge(attrs, %{
            status: "started",
            monthly_limit: monthly_limit,
            monthly_remaining: remaining - 1
          })

        %ValuationProviderRun{}
        |> ValuationProviderRun.changeset(attrs)
        |> Repo.insert!()
    end
  end

  defp finish_provider_run(run, status, now, started_at, reason, response_data \\ nil) do
    duration_ms = max(System.monotonic_time(:millisecond) - started_at, 0)

    run
    |> ValuationProviderRun.changeset(%{
      status: status,
      completed_at: now,
      duration_ms: duration_ms,
      error_message: provider_error_message(reason),
      response_data: response_data
    })
    |> Repo.update!()
  end

  defp provider_request_due?(asset_id, provider_key, now, interval_days) do
    cutoff = DateTime.add(now, -interval_days, :day)

    not Repo.exists?(
      from run in ValuationProviderRun,
        where:
          run.asset_id == ^asset_id and run.provider_key == ^provider_key and
            run.status in ^@outgoing_provider_run_statuses and run.requested_at > ^cutoff
    )
  end

  defp recent_manual_override?(asset_id, now, interval_days) do
    cutoff = Date.add(DateTime.to_date(now), -interval_days)

    Repo.exists?(
      from valuation in AssetValuation,
        where:
          valuation.asset_id == ^asset_id and valuation.source == "manual" and
            valuation.manually_overridden == true and valuation.valued_on > ^cutoff
    )
  end

  defp provider_rate_window_available?("marketcheck", now) do
    cutoff = DateTime.add(now, -1, :second)

    recent_count =
      ValuationProviderRun
      |> where(
        [run],
        run.provider_key == "marketcheck" and
          run.status in ^@outgoing_provider_run_statuses and run.requested_at > ^cutoff
      )
      |> Repo.aggregate(:count, :id)

    recent_count < @marketcheck_calls_per_second
  end

  defp provider_rate_window_available?(_provider_key, _now), do: true

  defp vehicle_provider_attrs(%Asset{vehicle_profile: %VehicleProfile{} = profile}) do
    if profile.encrypted_vin && profile.mileage && profile.market_region do
      {:ok,
       %{
         vin: profile.encrypted_vin,
         mileage: profile.mileage,
         market_region: profile.market_region
       }}
    else
      {:error, :invalid_vehicle}
    end
  end

  defp vehicle_provider_attrs(%Asset{}), do: {:error, :invalid_vehicle}

  defp month_start(%DateTime{} = now), do: %Date{year: now.year, month: now.month, day: 1}

  defp provider_error_message(nil), do: nil

  defp provider_error_message(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 500)
    |> String.slice(0, 1000)
  end

  defp provider_run_error_status(:rate_limited), do: "rate_limited"
  defp provider_run_error_status(_reason), do: "error"

  defp initial_valuation_changeset(%Asset{} = asset) do
    AssetValuation.changeset(%AssetValuation{}, %{
      asset_id: asset.id,
      amount: asset.valuation_amount,
      currency: asset.valuation_currency,
      source: "manual",
      valued_on: asset.last_valued_on || Date.utc_today()
    })
  end

  defp maybe_append_updated_valuation(multi, false), do: multi

  defp maybe_append_updated_valuation(multi, true) do
    multi
    |> Multi.insert(:valuation, fn %{asset: asset} ->
      initial_valuation_changeset(asset)
    end)
    |> Multi.run(:latest_valuation, fn repo, %{asset: asset} ->
      {:ok, latest_valuation(repo, asset.id)}
    end)
    |> Multi.update(:cached_asset, fn %{asset: asset, latest_valuation: latest} ->
      Ecto.Changeset.change(asset,
        valuation_amount: latest.amount,
        valuation_currency: latest.currency,
        last_valued_on: latest.valued_on
      )
    end)
  end

  defp maybe_preload(asset, preload) when is_list(preload) and preload != [] do
    Repo.preload(asset, preload)
  end

  defp maybe_preload(asset, _), do: asset

  defp build_asset_summary(%Asset{} = asset, opts) do
    gross_value = decimal_or_zero(asset.valuation_amount)
    linked_debt = linked_debt_balance(asset)
    net_equity = Decimal.sub(gross_value, linked_debt)
    freshness = valuation_freshness(asset.last_valued_on, opts)

    %{
      asset: asset,
      gross_value_amount: gross_value,
      linked_debt_amount: linked_debt,
      net_equity_amount: net_equity,
      gross_value: Accounts.format_money(gross_value, asset.valuation_currency, opts),
      gross_value_masked: Accounts.mask_money(gross_value, asset.valuation_currency, opts),
      linked_debt: Accounts.format_money(linked_debt, asset.valuation_currency, opts),
      linked_debt_masked: Accounts.mask_money(linked_debt, asset.valuation_currency, opts),
      net_equity: Accounts.format_money(net_equity, asset.valuation_currency, opts),
      net_equity_masked: Accounts.mask_money(net_equity, asset.valuation_currency, opts),
      valuation_freshness_status: freshness.status,
      valuation_freshness: freshness.label,
      valuation: Accounts.format_money(gross_value, asset.valuation_currency, opts),
      valuation_masked: Accounts.mask_money(gross_value, asset.valuation_currency, opts)
    }
  end

  defp valuation_freshness(nil, _opts),
    do: %{status: :missing, label: "Valuation date missing"}

  defp valuation_freshness(%Date{} = valued_on, opts) do
    today = Keyword.get(opts, :today, Date.utc_today())
    stale_after_days = Keyword.get(opts, :stale_after_days, @default_stale_after_days)
    age_days = Date.diff(today, valued_on)

    cond do
      age_days < 0 ->
        %{status: :future, label: "Valuation date is in the future"}

      age_days == 0 ->
        %{status: :current, label: "Current • valued today"}

      age_days > stale_after_days ->
        %{status: :stale, label: "Stale • valued #{age_days} days ago"}

      age_days == 1 ->
        %{status: :current, label: "Current • valued 1 day ago"}

      true ->
        %{status: :current, label: "Current • valued #{age_days} days ago"}
    end
  end

  defp linked_debt_balance(%Asset{} = asset) do
    loan_balance =
      case asset.linked_loan do
        %Loan{current_balance: balance} -> decimal_or_zero(balance)
        _ -> Decimal.new("0")
      end

    mortgage_balance =
      case asset.linked_mortgage do
        %Mortgage{current_balance: balance} -> decimal_or_zero(balance)
        _ -> Decimal.new("0")
      end

    Decimal.add(loan_balance, mortgage_balance)
  end

  defp sum_summary_decimals(items, field) do
    Enum.reduce(items, Decimal.new("0"), fn item, total ->
      Decimal.add(total, Map.fetch!(item, field))
    end)
  end

  defp decimal_or_zero(%Decimal{} = decimal), do: decimal

  defp decimal_or_zero(value) do
    case Decimal.cast(value) do
      {:ok, decimal} -> decimal
      :error -> Decimal.new("0")
    end
  end
end
