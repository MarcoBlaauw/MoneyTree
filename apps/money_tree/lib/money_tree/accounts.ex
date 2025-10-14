defmodule MoneyTree.Accounts do
  @moduledoc """
  Context responsible for user lifecycle operations, password management, and session tokens.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias MoneyTree.Audit
  alias MoneyTree.Repo
  alias MoneyTree.Sessions.Session
  alias MoneyTree.Users.User

  @default_session_ttl 60 * 60 * 24 * 30

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

  defp normalize_email(email) do
    email
    |> String.trim()
    |> String.downcase()
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
end
