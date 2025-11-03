defmodule MoneyTree.Accounts do
  @moduledoc """
  Context responsible for user lifecycle operations, password management, and session tokens.
  """

  import Bitwise
  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ecto.Multi
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Accounts.AccountInvitation
  alias MoneyTree.Accounts.AccountMembership
  alias MoneyTree.Audit
  alias MoneyTree.Mailer
  alias MoneyTree.Repo
  alias MoneyTree.Sessions.Session
  alias MoneyTree.Transactions
  alias MoneyTree.Users.User
  alias Swoosh.Email
  alias Decimal

  @default_session_ttl 60 * 60 * 24 * 30
  @default_invitation_ttl 60 * 60 * 24 * 7

  @default_user_page 1
  @default_user_per_page 25
  @max_user_per_page 100

  @doc """
  Registers a new user, hashing the provided password with Argon2.
  """
  @spec register_user(map()) :: {:ok, User.t()} | {:error, Changeset.t()}
  def register_user(attrs) when is_map(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> put_password_hash()
    |> Repo.insert()
  end

  @doc """
  Updates the role for the user identified by email.
  """
  @spec set_user_role(String.t(), atom() | String.t()) ::
          {:ok, User.t()} | {:error, :invalid_email | :invalid_role | :not_found | Changeset.t()}
  def set_user_role(email, role) when is_binary(email) do
    case get_user_by_email(email) do
      nil -> {:error, :not_found}
      %User{} = user -> update_user_role(user, role)
    end
  end

  def set_user_role(_email, _role), do: {:error, :invalid_email}

  @doc """
  Returns an Ecto query for listing users with optional search filters.

  The query orders users by insertion date in descending order so that the newest
  accounts appear first.
  """
  @spec user_directory_query(map() | keyword()) :: Ecto.Query.t()
  def user_directory_query(opts \\ []) do
    opts = normalize_user_pagination_opts(opts)
    search = Keyword.get(opts, :search)

    from(user in User, order_by: [desc: user.inserted_at])
    |> maybe_search_users(search)
  end

  @doc """
  Returns paginated users matching the supplied filters.
  """
  @spec paginate_users(map() | keyword()) :: %{entries: [User.t()], metadata: map()}
  def paginate_users(opts \\ []) do
    opts = normalize_user_pagination_opts(opts)

    page = sanitize_page_param(Keyword.get(opts, :page, @default_user_page))
    per_page = sanitize_per_page_param(Keyword.get(opts, :per_page, @default_user_per_page))
    preload = Keyword.get(opts, :preload)

    query = user_directory_query(opts)

    total_entries = Repo.aggregate(query, :count, :id)

    entries =
      query
      |> offset(^((page - 1) * per_page))
      |> limit(^per_page)
      |> Repo.all()
      |> maybe_preload_users(preload)

    %{entries: entries, metadata: build_pagination_metadata(page, per_page, total_entries)}
  end

  @doc """
  Fetches a user by ID, returning an error tuple when the record is missing.
  """
  @spec fetch_user(binary(), keyword()) :: {:ok, User.t()} | {:error, :not_found}
  def fetch_user(user_id, opts \\ [])

  def fetch_user(user_id, opts) when is_binary(user_id) do
    opts = normalize_user_pagination_opts(opts)

    query =
      from(user in User, where: user.id == ^user_id)
      |> maybe_preload_user(Keyword.get(opts, :preload))

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %User{} = user -> {:ok, user}
    end
  end

  def fetch_user(_user_id, _opts), do: {:error, :not_found}

  @doc """
  Updates a user's role, validating allowed values and recording an audit event.
  """
  @spec update_user_role(User.t() | binary(), atom() | String.t(), keyword()) ::
          {:ok, User.t()} | {:error, :invalid_role | :not_found | Changeset.t()}
  def update_user_role(user_or_id, role, opts \\ [])

  def update_user_role(%User{} = user, role, opts) do
    with {:ok, role_atom} <- normalize_role(role),
         {:ok, %User{} = updated} <-
           user
           |> User.changeset(%{role: role_atom})
           |> Repo.update() do
      Audit.log(:user_role_updated, audit_metadata(opts, %{user_id: updated.id, role: role_atom}))
      {:ok, updated}
    end
  end

  def update_user_role(user_id, role, opts) when is_binary(user_id) do
    with {:ok, %User{} = user} <- fetch_user(user_id) do
      update_user_role(user, role, opts)
    end
  end

  def update_user_role(_user_id, _role, _opts), do: {:error, :not_found}

  @doc """
  Suspends a user account, setting the suspension timestamp and emitting an audit event.
  """
  @spec suspend_user(User.t() | binary(), keyword()) ::
          {:ok, User.t()} | {:error, :already_suspended | :not_found | Changeset.t()}
  def suspend_user(user_or_id, opts \\ [])

  def suspend_user(%User{} = user, opts) do
    if user.suspended_at do
      {:error, :already_suspended}
    else
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      case user |> Changeset.change(%{suspended_at: now}) |> Repo.update() do
        {:ok, %User{} = updated} ->
          Audit.log(:user_suspended, audit_metadata(opts, %{user_id: updated.id}))
          {:ok, updated}

        {:error, %Changeset{} = changeset} ->
          {:error, changeset}
      end
    end
  end

  def suspend_user(user_id, opts) when is_binary(user_id) do
    with {:ok, %User{} = user} <- fetch_user(user_id) do
      suspend_user(user, opts)
    end
  end

  def suspend_user(_user_id, _opts), do: {:error, :not_found}

  @doc """
  Reactivates a previously suspended user, clearing the suspension timestamp and logging the event.
  """
  @spec reactivate_user(User.t() | binary(), keyword()) ::
          {:ok, User.t()} | {:error, :not_suspended | :not_found | Changeset.t()}
  def reactivate_user(user_or_id, opts \\ [])

  def reactivate_user(%User{} = user, opts) do
    if is_nil(user.suspended_at) do
      {:error, :not_suspended}
    else
      case user |> Changeset.change(%{suspended_at: nil}) |> Repo.update() do
        {:ok, %User{} = updated} ->
          Audit.log(:user_reactivated, audit_metadata(opts, %{user_id: updated.id}))
          {:ok, updated}

        {:error, %Changeset{} = changeset} ->
          {:error, changeset}
      end
    end
  end

  def reactivate_user(user_id, opts) when is_binary(user_id) do
    with {:ok, %User{} = user} <- fetch_user(user_id) do
      reactivate_user(user, opts)
    end
  end

  def reactivate_user(_user_id, _opts), do: {:error, :not_found}

  @doc """
  Authenticates a user and transparently rehashes outdated Argon2 hashes.
  """
  @spec authenticate_user(String.t(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid_credentials}
  def authenticate_user(email, password) when is_binary(email) and is_binary(password) do
    normalized_email = normalize_email(email)

    user =
      from(u in User,
        where: fragment("LOWER(?)", u.email) == ^normalized_email
      )
      |> Repo.one()

    cond do
      is_nil(user) ->
        Argon2.no_user_verify()
        Audit.log(:login_failed, %{email: normalized_email})
        {:error, :invalid_credentials}

      Argon2.verify_pass(password, user.password_hash) ->
        Audit.log(:login_succeeded, %{user_id: user.id})
        {:ok, maybe_rehash_password(user, password)}

      true ->
        Audit.log(:login_failed, %{email: normalized_email, user_id: user.id})
        {:error, :invalid_credentials}
    end
  end

  @doc """
  Creates a persistent session for the given user, returning the database record and cookie token.
  """
  @spec create_session(User.t(), map()) ::
          {:ok, Session.t(), String.t()} | {:error, Changeset.t()}
  def create_session(%User{} = user, attrs \\ %{}) do
    token = generate_session_token()
    token_hash = hash_session_token(token)
    now = DateTime.utc_now()

    attrs = Map.new(attrs)

    context =
      Map.get(attrs, :context) ||
        Map.get(attrs, "context") ||
        "api"

    metadata =
      Map.get(attrs, :metadata) ||
        Map.get(attrs, "metadata") ||
        %{}

    encrypted_metadata =
      Map.get(attrs, :encrypted_metadata) ||
        Map.get(attrs, "encrypted_metadata") ||
        metadata

    params = %{
      context: context,
      token_hash: token_hash,
      expires_at:
        Map.get(attrs, :expires_at) ||
          Map.get(attrs, "expires_at") ||
          DateTime.add(now, session_ttl_seconds(), :second),
      last_used_at:
        Map.get(attrs, :last_used_at) ||
          Map.get(attrs, "last_used_at") ||
          now,
      ip_address: Map.get(attrs, :ip_address) || Map.get(attrs, "ip_address"),
      user_agent: Map.get(attrs, :user_agent) || Map.get(attrs, "user_agent"),
      encrypted_metadata: encrypted_metadata,
      user_id: user.id
    }

    %Session{}
    |> Session.changeset(params)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:user_id, :context],
      returning: true
    )
    |> case do
      {:ok, session} ->
        {:ok, session, token}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Removes a session identified by its cookie token.
  """
  @spec delete_session(String.t()) :: :ok
  def delete_session(token) when is_binary(token) do
    token_hash = hash_session_token(token)
    from(s in Session, where: s.token_hash == ^token_hash) |> Repo.delete_all()
    :ok
  end

  @doc """
  Fetches the user associated with the provided session token if it is still valid.
  """
  @spec get_user_by_session_token(String.t()) ::
          {:ok, User.t()} | {:error, :invalid_token | :expired}
  def get_user_by_session_token(token) when is_binary(token) do
    token_hash = hash_session_token(token)
    now = DateTime.utc_now()

    query =
      from s in Session,
        where: s.token_hash == ^token_hash,
        preload: [:user]

    case Repo.one(query) do
      nil ->
        {:error, :invalid_token}

      %Session{} = session ->
        if DateTime.compare(session.expires_at, now) == :lt do
          Repo.delete(session)
          {:error, :expired}
        else
          {:ok, _updated} =
            session
            |> Changeset.change(last_used_at: now)
            |> Repo.update()

          {:ok, session.user}
        end
    end
  end

  def get_user_by_session_token(_), do: {:error, :invalid_token}

  @doc """
  Returns the cookie name used for session tokens.
  """
  @spec session_cookie_name() :: String.t()
  def session_cookie_name, do: "_money_tree_session"

  @doc """
  Provides the configured session TTL (in seconds) for cookie and persistence alignment.
  """
  @spec session_ttl_seconds() :: pos_integer()
  def session_ttl_seconds do
    Application.get_env(:money_tree, __MODULE__, [])
    |> Keyword.get(:session_ttl, @default_session_ttl)
  end

  @doc """
  Returns an Ecto query that scopes accounts to those owned or shared with the user.

  The query excludes revoked memberships so downstream callers don't need to reapply
  access checks.
  """
  @spec accessible_accounts_query(User.t() | binary()) :: Ecto.Query.t()
  def accessible_accounts_query(user) do
    user_id = normalize_user_id(user)

    from account in Account,
      left_join: membership in AccountMembership,
      on:
        membership.account_id == account.id and
          membership.user_id == ^user_id and
          is_nil(membership.revoked_at),
      where: account.user_id == ^user_id or not is_nil(membership.id),
      distinct: true
  end

  @doc """
  Lists accounts the user can access, optionally preloading associations.
  """
  @spec list_accessible_accounts(User.t() | binary(), keyword()) :: [Account.t()]
  def list_accessible_accounts(user, opts \\ []) do
    accessible_accounts_query(user)
    |> maybe_order_accounts(opts)
    |> maybe_preload_accounts(opts)
    |> Repo.all()
  end

  @doc """
  Fetches an accessible account for the user.
  """
  @spec fetch_accessible_account(User.t() | binary(), binary(), keyword()) ::
          {:ok, Account.t()} | {:error, :not_found}
  def fetch_accessible_account(user, account_id, opts \\ []) do
    query =
      accessible_accounts_query(user)
      |> where([account], account.id == ^account_id)
      |> maybe_preload_accounts(opts)

    query =
      case Keyword.get(opts, :lock) do
        nil -> query
        :for_update -> lock(query, "FOR UPDATE")
        :for_no_key_update -> lock(query, "FOR NO KEY UPDATE")
        :for_share -> lock(query, "FOR SHARE")
        :for_key_share -> lock(query, "FOR KEY SHARE")
        "FOR UPDATE" -> lock(query, "FOR UPDATE")
        "FOR NO KEY UPDATE" -> lock(query, "FOR NO KEY UPDATE")
        "FOR SHARE" -> lock(query, "FOR SHARE")
        "FOR KEY SHARE" -> lock(query, "FOR KEY SHARE")
        other -> raise ArgumentError, "unsupported lock option: #{inspect(other)}"
      end

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %Account{} = account -> {:ok, account}
    end
  end

  @doc """
  Formats dashboard data for the provided user.

  The response includes masked balance strings that can be toggled in the LiveView
  without re-querying the database.
  """
  @spec dashboard_summary(User.t() | binary(), keyword()) :: %{accounts: list(), totals: list()}
  def dashboard_summary(user, opts \\ []) do
    accounts =
      list_accessible_accounts(user,
        preload: Keyword.get(opts, :preload, [:institution, :institution_connection]),
        order_by: {:desc, :updated_at}
      )

    summaries = Enum.map(accounts, &account_summary(&1, opts))

    totals =
      summaries
      |> Enum.group_by(& &1.account.currency)
      |> Enum.map(fn {currency, grouped} ->
        total_balance =
          grouped
          |> Enum.map(& &1.account.current_balance)
          |> sum_decimals()

        %{
          currency: currency,
          current_balance: format_money(total_balance, currency, opts),
          current_balance_masked: mask_money(total_balance, currency, opts),
          account_count: length(grouped)
        }
      end)

    %{accounts: summaries, totals: totals}
  end

  @doc """
  Returns running balance insights for active card accounts accessible to the user.
  """
  @spec running_card_balances(User.t() | binary(), keyword()) :: [map()]
  def running_card_balances(user, opts \\ []) do
    transactions_module = Keyword.get(opts, :transactions_module, Transactions)
    lookback_days = Keyword.get(opts, :lookback_days, 30)

    list_accessible_accounts(user,
      preload: Keyword.get(opts, :preload, []),
      order_by: Keyword.get(opts, :order_by, [{:asc, :name}])
    )
    |> Enum.filter(&card_account?/1)
    |> Enum.map(fn account ->
      current_balance = normalize_decimal(account.current_balance)
      available_balance = normalize_optional_decimal(account.available_balance)
      limit = normalize_optional_decimal(account.limit)

      available_credit =
        cond do
          not is_nil(limit) ->
            limit
            |> Decimal.sub(current_balance)
            |> clamp_decimal()

          not is_nil(available_balance) ->
            available_balance

          true ->
            nil
        end

      utilization =
        cond do
          is_nil(limit) ->
            nil

          Decimal.compare(limit, Decimal.new("0")) == :eq ->
            nil

          true ->
            Decimal.div(current_balance, limit)
            |> Decimal.max(Decimal.new("0"))
        end

      trend_amount = transactions_module.net_activity_for_account(account, days: lookback_days)

      %{
        account: %{
          id: account.id,
          name: account.name,
          currency: account.currency,
          type: account.type
        },
        current_balance: format_money(current_balance, account.currency, opts),
        current_balance_masked: mask_money(current_balance, account.currency, opts),
        available_credit: format_money(available_credit, account.currency, opts),
        available_credit_masked: mask_money(available_credit, account.currency, opts),
        utilization: utilization && Decimal.round(utilization, 4),
        utilization_percent:
          case utilization do
            nil -> nil
            %Decimal{} = value -> Decimal.mult(value, Decimal.new("100")) |> Decimal.round(2)
          end,
        trend_amount: format_money(trend_amount, account.currency, opts),
        trend_amount_masked: mask_money(trend_amount, account.currency, opts),
        trend_direction: trend_direction(trend_amount)
      }
    end)
  end

  @doc """
  Calculates the household net worth for accounts accessible to the user.
  """
  @spec net_worth_snapshot(User.t() | binary(), keyword()) :: map()
  def net_worth_snapshot(user, opts \\ []) do
    accounts = list_accessible_accounts(user, preload: Keyword.get(opts, :preload, []))

    {asset_total, liability_total, asset_groups, liability_groups} =
      Enum.reduce(accounts, {Decimal.new("0"), Decimal.new("0"), %{}, %{}}, fn account,
                                                                               {asset_acc,
                                                                                liability_acc,
                                                                                asset_map,
                                                                                liability_map} ->
        balance = normalize_decimal(account.current_balance)
        currency = account.currency || "USD"
        label = account_group_label(account)

        cond do
          asset_account?(account) ->
            updated_assets =
              Map.update(asset_map, {label, currency}, balance, &Decimal.add(&1, balance))

            {Decimal.add(asset_acc, balance), liability_acc, updated_assets, liability_map}

          liability_account?(account) ->
            updated_liabilities =
              Map.update(liability_map, {label, currency}, balance, &Decimal.add(&1, balance))

            {asset_acc, Decimal.add(liability_acc, balance), asset_map, updated_liabilities}

          true ->
            {asset_acc, liability_acc, asset_map, liability_map}
        end
      end)

    currency = primary_currency(accounts)
    net_worth = Decimal.sub(asset_total, liability_total)

    %{
      currency: currency,
      assets: format_money(asset_total, currency, opts),
      assets_masked: mask_money(asset_total, currency, opts),
      liabilities: format_money(liability_total, currency, opts),
      liabilities_masked: mask_money(liability_total, currency, opts),
      net_worth: format_money(net_worth, currency, opts),
      net_worth_masked: mask_money(net_worth, currency, opts),
      breakdown: %{
        assets: format_group_totals(asset_groups, opts),
        liabilities: format_group_totals(liability_groups, opts)
      }
    }
  end

  @doc """
  Summarises balances across savings and investment accounts for quick dashboard rendering.
  """
  @spec savings_and_investments_summary(User.t() | binary(), keyword()) :: map()
  def savings_and_investments_summary(user, opts \\ []) do
    accounts = list_accessible_accounts(user, preload: Keyword.get(opts, :preload, []))

    savings_accounts = Enum.filter(accounts, &savings_account?/1)
    investment_accounts = Enum.filter(accounts, &investment_account?/1)

    currency = primary_currency(savings_accounts ++ investment_accounts)

    savings_total = sum_balances(savings_accounts)
    investment_total = sum_balances(investment_accounts)
    combined_total = Decimal.add(savings_total, investment_total)

    %{
      currency: currency,
      savings_total: format_money(savings_total, currency, opts),
      savings_total_masked: mask_money(savings_total, currency, opts),
      investment_total: format_money(investment_total, currency, opts),
      investment_total_masked: mask_money(investment_total, currency, opts),
      combined_total: format_money(combined_total, currency, opts),
      combined_total_masked: mask_money(combined_total, currency, opts),
      savings_accounts: Enum.map(savings_accounts, &format_account_listing(&1, opts)),
      investment_accounts: Enum.map(investment_accounts, &format_account_listing(&1, opts))
    }
  end

  @doc """
  Formats user settings data for rendering.
  """
  @spec user_settings(User.t()) :: map()
  def user_settings(%User{} = user) do
    sessions = list_active_sessions(user)

    %{
      profile: %{
        email: user.email,
        full_name: user.encrypted_full_name,
        role: user.role
      },
      security: %{
        multi_factor_enabled: Map.get(user, :multi_factor_enabled, false),
        last_login_at: latest_session_timestamp(sessions)
      },
      notifications: %{
        transfer_alerts: true,
        security_alerts: true
      },
      sessions:
        Enum.map(sessions, fn session ->
          %{
            id: session.id,
            context: session.context,
            last_used_at: session.last_used_at,
            user_agent: session.user_agent,
            ip_address: session.ip_address
          }
        end)
    }
  end

  @doc """
  Lists active sessions for the user ordered by most recent activity.
  """
  @spec list_active_sessions(User.t() | binary()) :: [Session.t()]
  def list_active_sessions(user) do
    user_id = normalize_user_id(user)

    from(session in Session,
      where: session.user_id == ^user_id,
      order_by: [desc: session.last_used_at, desc: session.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Formats a decimal amount using the provided ISO currency code.
  """
  @spec format_money(Decimal.t() | nil, String.t() | nil, keyword()) :: String.t() | nil
  def format_money(nil, _currency, _opts), do: nil

  def format_money(%Decimal{} = amount, currency, _opts) when is_binary(currency) do
    amount
    |> Decimal.round(2)
    |> Decimal.to_string(:normal)
    |> ensure_precision(2)
    |> prepend_currency(currency)
  end

  def format_money(amount, currency, opts) when is_binary(currency) do
    case Decimal.cast(amount) do
      {:ok, decimal} -> format_money(decimal, currency, opts)
      :error -> nil
    end
  end

  @doc """
  Formats an APR value with a percent sign.
  """
  @spec format_apr(Decimal.t() | nil, keyword()) :: String.t() | nil
  def format_apr(nil, _opts), do: nil

  def format_apr(%Decimal{} = apr, opts) do
    precision = apr_precision(opts)

    apr
    |> Decimal.round(precision)
    |> Decimal.to_string(:normal)
    |> ensure_precision(precision)
    |> Kernel.<>("%")
  end

  def format_apr(apr, opts) do
    case Decimal.cast(apr) do
      {:ok, decimal} -> format_apr(decimal, opts)
      :error -> nil
    end
  end

  @doc """
  Returns a masked currency string using the configured mask character.
  """
  @spec mask_money(Decimal.t() | nil, String.t() | nil, keyword()) :: String.t() | nil
  def mask_money(amount, currency, opts \\ []) do
    mask_character = Keyword.get(opts, :mask_character, "•")

    amount
    |> format_money(currency, opts)
    |> maybe_mask(mask_character)
  end

  defp apr_precision(opts), do: Keyword.get(opts, :apr_precision, 2)

  defp account_summary(%Account{} = account, opts) do
    %{
      account: account,
      current_balance: format_money(account.current_balance, account.currency, opts),
      current_balance_masked: mask_money(account.current_balance, account.currency, opts),
      available_balance: format_money(account.available_balance, account.currency, opts),
      available_balance_masked: mask_money(account.available_balance, account.currency, opts),
      minimum_balance: format_money(account.minimum_balance, account.currency, opts),
      minimum_balance_masked: mask_money(account.minimum_balance, account.currency, opts),
      maximum_balance: format_money(account.maximum_balance, account.currency, opts),
      maximum_balance_masked: mask_money(account.maximum_balance, account.currency, opts),
      apr: format_apr(account.apr, opts),
      fee_schedule: account.fee_schedule
    }
  end

  defp maybe_order_accounts(query, opts) do
    case Keyword.get(opts, :order_by) do
      nil ->
        order_by(query, desc: :inserted_at)

      order ->
        apply_account_order(query, order)
    end
  end

  defp apply_account_order(query, order) when is_list(order) do
    Enum.reduce(order, query, fn
      {:asc, field}, acc ->
        order_by(acc, [account], asc: field(account, ^normalize_account_field(field)))

      {:desc, field}, acc ->
        order_by(acc, [account], desc: field(account, ^normalize_account_field(field)))

      field, acc ->
        order_by(acc, [account], asc: field(account, ^normalize_account_field(field)))
    end)
  end

  defp apply_account_order(query, {:asc, field}) do
    order_by(query, [account], asc: field(account, ^normalize_account_field(field)))
  end

  defp apply_account_order(query, {:desc, field}) do
    order_by(query, [account], desc: field(account, ^normalize_account_field(field)))
  end

  defp apply_account_order(query, field) do
    order_by(query, [account], asc: field(account, ^normalize_account_field(field)))
  end

  defp normalize_account_field(field) when is_atom(field), do: field

  defp normalize_account_field(field) when is_binary(field) do
    String.to_existing_atom(field)
  rescue
    ArgumentError ->
      raise ArgumentError, "unknown account order field: #{inspect(field)}"
  end

  defp maybe_preload_accounts(query, opts) do
    case Keyword.get(opts, :preload) do
      nil -> query
      preload -> preload(query, ^preload)
    end
  end

  defp latest_session_timestamp([]), do: nil

  defp latest_session_timestamp([session | _rest]),
    do: session.last_used_at || session.inserted_at

  defp sum_decimals(values) do
    Enum.reduce(values, Decimal.new("0"), fn value, acc ->
      case Decimal.cast(value) do
        {:ok, decimal} -> Decimal.add(acc, decimal)
        :error -> acc
      end
    end)
  end

  defp ensure_precision(string, precision) when precision <= 0, do: string

  defp ensure_precision(string, precision) do
    case String.split(string, ".") do
      [whole] ->
        whole <> "." <> String.duplicate("0", precision)

      [whole, fraction] ->
        trimmed = String.slice(fraction, 0, precision)
        whole <> "." <> String.pad_trailing(trimmed, precision, "0")

      _ ->
        string
    end
  end

  defp prepend_currency(value, currency) do
    [String.upcase(currency), value]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp maybe_mask(nil, _mask_character), do: nil

  defp maybe_mask(value, mask_character) do
    Regex.replace(~r/\d/, value, mask_character)
  end

  defp normalize_decimal(nil), do: Decimal.new("0")
  defp normalize_decimal(%Decimal{} = value), do: value

  defp normalize_decimal(value) do
    case Decimal.cast(value) do
      {:ok, decimal} -> decimal
      :error -> Decimal.new("0")
    end
  end

  defp normalize_optional_decimal(nil), do: nil
  defp normalize_optional_decimal(value), do: normalize_decimal(value)

  defp clamp_decimal(%Decimal{} = value) do
    if Decimal.compare(value, Decimal.new("0")) == :lt do
      Decimal.new("0")
    else
      value
    end
  end

  defp clamp_decimal(nil), do: nil

  defp trend_direction(amount) do
    case Decimal.compare(normalize_decimal(amount), Decimal.new("0")) do
      :gt -> :increasing
      :lt -> :decreasing
      :eq -> :flat
    end
  end

  defp format_group_totals(group_map, opts) do
    group_map
    |> Enum.map(fn {{label, currency}, total} ->
      currency = currency || "USD"

      %{
        label: label,
        total: format_money(total, currency, opts),
        total_masked: mask_money(total, currency, opts)
      }
    end)
    |> Enum.sort_by(& &1.label)
  end

  defp format_account_listing(account, opts) do
    balance = normalize_decimal(account.current_balance)
    currency = account.currency || "USD"

    %{
      id: account.id,
      name: account.name,
      balance: format_money(balance, currency, opts),
      balance_masked: mask_money(balance, currency, opts),
      apr: format_apr(account.apr, opts),
      minimum_balance: format_money(account.minimum_balance, currency, opts),
      minimum_balance_masked: mask_money(account.minimum_balance, currency, opts),
      maximum_balance: format_money(account.maximum_balance, currency, opts),
      maximum_balance_masked: mask_money(account.maximum_balance, currency, opts),
      fee_schedule: account.fee_schedule
    }
  end

  defp sum_balances(accounts) do
    Enum.reduce(accounts, Decimal.new("0"), fn account, acc ->
      Decimal.add(acc, normalize_decimal(account.current_balance))
    end)
  end

  defp primary_currency([]), do: "USD"

  defp primary_currency(accounts) do
    accounts
    |> Enum.map(& &1.currency)
    |> Enum.find("USD", fn currency -> is_binary(currency) and currency != "" end)
  end

  defp asset_account?(account) do
    type = downcase(account.type)
    subtype = downcase(account.subtype)

    cond do
      card_account?(account) -> false
      loan_account?(account) -> false
      type in ["depository", "investment", "brokerage", "retirement", "cash"] -> true
      subtype in ["savings", "checking", "money market", "ira", "401k"] -> true
      true -> false
    end
  end

  defp liability_account?(account) do
    card_account?(account) or loan_account?(account) or downcase(account.type) in ["liability"]
  end

  defp card_account?(account) do
    type = downcase(account.type)
    subtype = downcase(account.subtype)

    type in ["credit", "card", "credit card"] or
      subtype in ["credit", "credit card", "charge card"]
  end

  defp loan_account?(account) do
    type = downcase(account.type)
    subtype = downcase(account.subtype)

    String.contains?(type, "loan") or String.contains?(subtype, "loan") or
      subtype in ["mortgage", "student"]
  end

  defp savings_account?(account) do
    subtype = downcase(account.subtype)
    type = downcase(account.type)

    subtype in ["savings", "money market"] or type == "depository"
  end

  defp investment_account?(account) do
    type = downcase(account.type)
    subtype = downcase(account.subtype)

    type in ["investment", "brokerage", "retirement"] or
      subtype in ["ira", "401k", "brokerage", "roth"]
  end

  defp account_group_label(account) do
    cond do
      card_account?(account) -> "Credit Cards"
      loan_account?(account) -> "Loans"
      savings_account?(account) -> "Savings"
      investment_account?(account) -> "Investments"
      asset_account?(account) -> titleize(account.type || "Assets")
      true -> "Accounts"
    end
  end

  defp titleize(nil), do: "Accounts"

  defp titleize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.downcase()
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp downcase(nil), do: ""
  defp downcase(value) when is_binary(value), do: String.downcase(value)

  defp normalize_user_id(%User{id: id}) when is_binary(id), do: id
  defp normalize_user_id(id) when is_binary(id), do: id

  @doc """
  Creates a new invitation for the given account and sends a notification email.
  """
  @spec create_account_invitation(User.t(), Account.t()) ::
          {:ok, AccountInvitation.t(), String.t()} | {:error, term()}
  def create_account_invitation(%User{} = inviter, %Account{} = account) do
    create_account_invitation(inviter, account, %{})
  end

  @spec create_account_invitation(User.t(), Account.t(), map()) ::
          {:ok, AccountInvitation.t(), String.t()} | {:error, term()}
  def create_account_invitation(%User{} = inviter, %Account{} = account, attrs)
      when is_map(attrs) do
    with :ok <- ensure_account_access(inviter.id, account),
         {:ok, email} <- fetch_email(attrs),
         :ok <- ensure_not_already_member(account.id, email),
         :ok <- ensure_no_pending_invitation(account.id, email),
         {:ok, expires_at} <- invitation_expiration(attrs) do
      token = generate_invitation_token()

      params =
        attrs
        |> Map.drop([:token, "token"])
        |> Map.put(:email, email)
        |> Map.put(:expires_at, expires_at)
        |> Map.put(:token_hash, hash_invitation_token(token))
        |> Map.put(:account_id, account.id)
        |> Map.put(:user_id, inviter.id)
        |> Map.put_new(:status, :pending)

      %AccountInvitation{}
      |> AccountInvitation.changeset(params)
      |> Repo.insert()
      |> case do
        {:ok, invitation} ->
          deliver_invitation_email(invitation, token)
          {:ok, invitation, token}

        {:error, %Changeset{} = changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Revokes a pending invitation, preventing further use of its token.
  """
  @spec revoke_account_invitation(User.t(), AccountInvitation.t()) ::
          {:ok, AccountInvitation.t()} | {:error, term()}
  def revoke_account_invitation(%User{} = actor, %AccountInvitation{} = invitation) do
    with :ok <- ensure_account_access(actor.id, invitation.account_id),
         :ok <- ensure_pending(invitation) do
      invitation
      |> Changeset.change(status: :revoked)
      |> Repo.update()
    end
  end

  @doc """
  Accepts an invitation token, authenticating or creating the invitee and granting membership.
  """
  @spec accept_account_invitation(String.t(), map()) ::
          {:ok, AccountInvitation.t(), AccountMembership.t()} | {:error, term()}
  def accept_account_invitation(token, params) when is_binary(token) and is_map(params) do
    with {:ok, invitation} <- fetch_invitation(token),
         :ok <- ensure_pending(invitation),
         :ok <- ensure_not_expired(invitation),
         {:ok, user} <- resolve_invitee(invitation, params),
         :ok <- ensure_not_already_member(invitation.account_id, user.id) do
      multi =
        Multi.new()
        |> Multi.insert(:membership, invitation_membership_changeset(invitation, user))
        |> Multi.update(:invitation, invitation_accept_changeset(invitation, user))

      case Repo.transaction(multi) do
        {:ok, %{invitation: updated_invitation, membership: membership}} ->
          {:ok, updated_invitation, membership}

        {:error, :membership, %Changeset{} = changeset, _} ->
          {:error, changeset}

        {:error, :invitation, %Changeset{} = changeset, _} ->
          {:error, changeset}
      end
    end
  end

  defp normalize_email(email) do
    email
    |> String.trim()
    |> String.downcase()
  end

  defp fetch_email(attrs) do
    case Map.get(attrs, :email) || Map.get(attrs, "email") do
      nil -> {:error, :email_required}
      email -> {:ok, normalize_email(email)}
    end
  end

  defp ensure_account_access(user_id, %Account{} = account) do
    ensure_account_access(user_id, account.id, account.user_id)
  end

  defp ensure_account_access(user_id, account_id) do
    account_owner_id =
      from(a in Account, where: a.id == ^account_id, select: a.user_id)
      |> Repo.one()

    ensure_account_access(user_id, account_id, account_owner_id)
  end

  defp ensure_account_access(user_id, account_id, owner_id) do
    cond do
      owner_id == user_id ->
        :ok

      Repo.exists?(
        from m in AccountMembership,
          where: m.account_id == ^account_id and m.user_id == ^user_id and is_nil(m.revoked_at)
      ) ->
        :ok

      true ->
        {:error, :unauthorized}
    end
  end

  defp ensure_not_already_member(account_id, email) when is_binary(email) do
    case get_user_by_email(email) do
      nil -> :ok
      %User{id: user_id} -> ensure_not_already_member(account_id, user_id)
    end
  end

  defp ensure_not_already_member(account_id, user_id)
       when is_binary(account_id) and is_binary(user_id) do
    if Repo.exists?(
         from m in AccountMembership,
           where: m.account_id == ^account_id and m.user_id == ^user_id and is_nil(m.revoked_at)
       ) do
      {:error, :already_member}
    else
      :ok
    end
  end

  defp ensure_no_pending_invitation(account_id, email) do
    if Repo.exists?(
         from i in AccountInvitation,
           where: i.account_id == ^account_id and i.email == ^email and i.status == :pending
       ) do
      {:error, :already_invited}
    else
      :ok
    end
  end

  defp invitation_expiration(attrs) do
    case Map.get(attrs, :expires_at) || Map.get(attrs, "expires_at") do
      nil ->
        {:ok,
         DateTime.utc_now()
         |> DateTime.add(@default_invitation_ttl, :second)
         |> DateTime.truncate(:microsecond)}

      %DateTime{} = datetime ->
        {:ok, DateTime.truncate(datetime, :microsecond)}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} ->
            {:ok, DateTime.truncate(datetime, :microsecond)}

          {:error, _reason} ->
            {:error, :invalid_expiration}
        end

      _other ->
        {:error, :invalid_expiration}
    end
  end

  defp ensure_pending(%AccountInvitation{status: :pending}), do: :ok
  defp ensure_pending(%AccountInvitation{status: :accepted}), do: {:error, :already_accepted}
  defp ensure_pending(%AccountInvitation{status: :revoked}), do: {:error, :revoked}
  defp ensure_pending(%AccountInvitation{status: :expired}), do: {:error, :expired}

  defp ensure_not_expired(%AccountInvitation{} = invitation) do
    if DateTime.compare(invitation.expires_at, DateTime.utc_now()) == :lt do
      invitation
      |> Changeset.change(status: :expired)
      |> Repo.update()

      {:error, :expired}
    else
      :ok
    end
  end

  defp resolve_invitee(%AccountInvitation{} = invitation, params) do
    password = Map.get(params, :password) || Map.get(params, "password")

    with password when is_binary(password) <- password do
      case get_user_by_email(invitation.email) do
        nil ->
          encrypted_full_name =
            Map.get(params, :encrypted_full_name) || Map.get(params, "encrypted_full_name")

          if is_binary(encrypted_full_name) do
            register_user(%{
              email: invitation.email,
              password: password,
              encrypted_full_name: encrypted_full_name
            })
          else
            {:error, :full_name_required}
          end

        %User{} = _existing ->
          authenticate_user(invitation.email, password)
      end
    else
      _ -> {:error, :password_required}
    end
  end

  defp invitation_membership_changeset(%AccountInvitation{} = invitation, %User{} = user) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %AccountMembership{}
    |> AccountMembership.changeset(%{
      account_id: invitation.account_id,
      user_id: user.id,
      role: :member,
      invited_at: invitation.inserted_at,
      accepted_at: now
    })
  end

  defp invitation_accept_changeset(%AccountInvitation{} = invitation, %User{} = user) do
    invitation
    |> Changeset.change(%{status: :accepted, invitee_user_id: user.id})
  end

  defp fetch_invitation(token) do
    token_hash = hash_invitation_token(token)

    case Repo.one(from i in AccountInvitation, where: i.token_hash == ^token_hash) do
      nil -> {:error, :not_found}
      %AccountInvitation{} = invitation -> {:ok, invitation}
    end
  end

  defp deliver_invitation_email(%AccountInvitation{} = invitation, token) do
    sender =
      Application.get_env(
        :money_tree,
        :invitation_sender,
        {"MoneyTree", "no-reply@moneytree.app"}
      )

    invitation_link =
      Application.get_env(
        :money_tree,
        :invitation_base_url,
        "https://app.moneytree.test/invitations/#{token}"
      )

    body =
      "You have been invited to join account #{invitation.account_id}. " <>
        "Use the token #{token} to accept at #{invitation_link}."

    Email.new()
    |> Email.to(invitation.email)
    |> Email.from(sender)
    |> Email.subject("You're invited to MoneyTree")
    |> Email.text_body(body)
    |> Mailer.deliver()

    :ok
  end

  defp get_user_by_email(email) when is_binary(email) do
    normalized_email = normalize_email(email)

    from(u in User, where: fragment("LOWER(?)", u.email) == ^normalized_email)
    |> Repo.one()
  end

  defp normalize_user_pagination_opts(opts) when is_list(opts), do: opts

  defp normalize_user_pagination_opts(opts) when is_map(opts) do
    Enum.reduce(opts, [], fn {key, value}, acc ->
      case normalize_pagination_key(key) do
        nil -> acc
        normalized_key -> [{normalized_key, value} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp normalize_user_pagination_opts(_opts), do: []

  defp normalize_pagination_key(key) when key in [:page, :per_page, :preload, :search],
    do: key

  defp normalize_pagination_key("page"), do: :page
  defp normalize_pagination_key("per_page"), do: :per_page
  defp normalize_pagination_key("preload"), do: :preload
  defp normalize_pagination_key("search"), do: :search
  defp normalize_pagination_key("q"), do: :search
  defp normalize_pagination_key("query"), do: :search
  defp normalize_pagination_key(_key), do: nil

  defp sanitize_page_param(value) when is_integer(value) and value > 0, do: value

  defp sanitize_page_param(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} when parsed > 0 -> parsed
      _ -> @default_user_page
    end
  end

  defp sanitize_page_param(_value), do: @default_user_page

  defp sanitize_per_page_param(value) when is_integer(value) and value > 0 do
    min(value, @max_user_per_page)
  end

  defp sanitize_per_page_param(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} when parsed > 0 -> min(parsed, @max_user_per_page)
      _ -> @default_user_per_page
    end
  end

  defp sanitize_per_page_param(_value), do: @default_user_per_page

  defp build_pagination_metadata(page, per_page, total_entries) do
    total_pages =
      total_entries
      |> Kernel./(per_page)
      |> Float.ceil()
      |> trunc()

    %{
      page: page,
      per_page: per_page,
      total_entries: total_entries,
      total_pages: total_pages
    }
  end

  defp maybe_search_users(query, nil), do: query

  defp maybe_search_users(query, search) when is_binary(search) do
    search = String.trim(search)

    if search == "" do
      query
    else
      pattern = "%#{search}%"

      from(user in query, where: ilike(user.email, ^pattern))
    end
  end

  defp maybe_search_users(query, _search), do: query

  defp maybe_preload_users(users, preload) when preload in [nil, []], do: users

  defp maybe_preload_users(users, preload), do: Repo.preload(users, preload)

  defp maybe_preload_user(query, preload) when preload in [nil, []], do: query

  defp maybe_preload_user(query, preload), do: preload(query, ^preload)

  defp audit_metadata(opts, extra) when is_map(extra) do
    opts
    |> Keyword.get(:actor)
    |> case do
      %User{id: actor_id} -> Map.put(extra, :actor_id, actor_id)
      actor_id when is_binary(actor_id) -> Map.put(extra, :actor_id, actor_id)
      _ -> extra
    end
  end

  defp normalize_role(role) when is_atom(role) do
    if role in User.roles(), do: {:ok, role}, else: {:error, :invalid_role}
  end

  defp normalize_role(role) when is_binary(role) do
    role
    |> String.trim()
    |> String.downcase()
    |> case do
      "" ->
        {:error, :invalid_role}

      normalized ->
        case Enum.find(User.roles(), fn candidate ->
               Atom.to_string(candidate) == normalized
             end) do
          nil -> {:error, :invalid_role}
          role_atom -> {:ok, role_atom}
        end
    end
  end

  defp normalize_role(_), do: {:error, :invalid_role}

  defp put_password_hash(changeset) do
    case Changeset.fetch_change(changeset, :password) do
      {:ok, password} ->
        changeset
        |> Changeset.put_change(:password_hash, Argon2.hash_pwd_salt(password))
        |> Changeset.delete_change(:password)

      :error ->
        changeset
    end
  end

  defp maybe_rehash_password(%User{} = user, password) do
    if password_needs_rehash?(user.password_hash) do
      user
      |> Changeset.change(password_hash: Argon2.hash_pwd_salt(password))
      |> Repo.update!()
    else
      user
    end
  end

  defp password_needs_rehash?(hash) when is_binary(hash) do
    with {:ok, params} <- extract_argon2_params(hash) do
      current = expected_argon2_params()
      Enum.any?(current, fn {key, value} -> Map.get(params, key) != value end)
    else
      _ -> true
    end
  end

  defp password_needs_rehash?(_), do: true

  defp extract_argon2_params(hash) do
    params_segment =
      hash
      |> String.split("$")
      |> Enum.find(fn segment -> String.contains?(segment, "m=") end)

    with %{} = params <- parse_params(params_segment) do
      {:ok, params}
    else
      _ -> {:error, :unknown_hash_format}
    end
  end

  defp parse_params(nil), do: nil

  defp parse_params(segment) do
    segment
    |> String.split(",")
    |> Enum.reduce(%{}, fn part, acc ->
      case String.split(part, "=", parts: 2) do
        [key, value] ->
          Map.put(acc, key, parse_value(value))

        _ ->
          acc
      end
    end)
  end

  defp parse_value(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> value
    end
  end

  defp expected_argon2_params do
    m_cost = Application.get_env(:argon2_elixir, :m_cost, 16)

    %{
      "m" => 1 <<< m_cost,
      "t" => Application.get_env(:argon2_elixir, :t_cost, 3),
      "p" => Application.get_env(:argon2_elixir, :parallelism, 4)
    }
  end

  defp generate_session_token do
    generate_url_safe_token()
  end

  defp hash_session_token(token) when is_binary(token) do
    :crypto.hash(:sha256, token)
  end

  defp generate_invitation_token do
    generate_url_safe_token()
  end

  defp hash_invitation_token(token) when is_binary(token) do
    :crypto.hash(:sha256, token)
  end

  defp generate_url_safe_token(byte_length \\ 32)
       when is_integer(byte_length) and byte_length > 0 do
    byte_length
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
