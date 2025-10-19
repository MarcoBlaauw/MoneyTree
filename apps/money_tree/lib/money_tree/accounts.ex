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
  alias MoneyTree.Users.User
  alias Swoosh.Email
  alias Decimal

  @default_session_ttl 60 * 60 * 24 * 30
  @default_invitation_ttl 60 * 60 * 24 * 7

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

    params =
      attrs
      |> Map.new()
      |> Map.take([
        :context,
        :expires_at,
        :last_used_at,
        :ip_address,
        :user_agent,
        :encrypted_metadata
      ])
      |> Map.put_new(:context, Map.get(attrs, :context, "api"))
      |> Map.put(:token_hash, token_hash)
      |> Map.put_new(:expires_at, DateTime.add(now, session_ttl_seconds(), :second))
      |> Map.put_new(:last_used_at, now)
      |> Map.put(:user_id, user.id)
      |> Map.put_new(:encrypted_metadata, Map.get(attrs, :metadata, %{}))

    %Session{}
    |> Session.changeset(params)
    |> Repo.insert()
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
        lock_clause -> lock(query, ^lock_clause)
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
    |> ensure_two_decimals()
    |> prepend_currency(currency)
  end

  def format_money(amount, currency, opts) when is_binary(currency) do
    case Decimal.cast(amount) do
      {:ok, decimal} -> format_money(decimal, currency, opts)
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

  defp account_summary(%Account{} = account, opts) do
    %{
      account: account,
      current_balance: format_money(account.current_balance, account.currency, opts),
      current_balance_masked: mask_money(account.current_balance, account.currency, opts),
      available_balance: format_money(account.available_balance, account.currency, opts),
      available_balance_masked: mask_money(account.available_balance, account.currency, opts)
    }
  end

  defp maybe_order_accounts(query, opts) do
    case Keyword.get(opts, :order_by) do
      nil -> order_by(query, desc: :inserted_at)
      {:desc, field_name} -> order_by(query, [account], desc: field(account, ^field_name))
      {:asc, field_name} -> order_by(query, [account], asc: field(account, ^field_name))
      other when is_list(other) -> order_by(query, ^other)
      _ -> query
    end
  end

  defp maybe_preload_accounts(query, opts) do
    case Keyword.get(opts, :preload) do
      nil -> query
      preload -> preload(query, ^preload)
    end
  end

  defp latest_session_timestamp([]), do: nil
  defp latest_session_timestamp([session | _rest]), do: session.last_used_at || session.inserted_at

  defp sum_decimals(values) do
    Enum.reduce(values, Decimal.new("0"), fn value, acc ->
      case Decimal.cast(value) do
        {:ok, decimal} -> Decimal.add(acc, decimal)
        :error -> acc
      end
    end)
  end

  defp ensure_two_decimals(string) do
    case String.split(string, ".") do
      [whole] -> whole <> ".00"
      [whole, fraction] -> whole <> "." <> String.pad_trailing(fraction, 2, "0")
      _ -> string
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
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  defp hash_session_token(token) when is_binary(token) do
    :crypto.hash(:sha256, token)
  end

  defp generate_invitation_token do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  defp hash_invitation_token(token) when is_binary(token) do
    :crypto.hash(:sha256, token)
  end
end
