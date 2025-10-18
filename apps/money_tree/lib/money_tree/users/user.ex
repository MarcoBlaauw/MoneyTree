defmodule MoneyTree.Users.User do
  @moduledoc """
  User record with authentication metadata and encrypted profile attributes.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias MoneyTree.Accounts.AccountMembership
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Encrypted.Binary
  alias MoneyTree.Sessions.Session

  @roles [:owner, :member, :advisor]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "users" do
    field(:email, :string)
    field(:password_hash, :string)
    field(:encrypted_full_name, Binary)
    field(:password, :string, virtual: true)
    field(:role, Ecto.Enum, values: @roles, default: :member)

    has_many(:accounts, Account)
    has_many(:memberships, AccountMembership)

    many_to_many(:shared_accounts, Account,
      join_through: AccountMembership,
      join_keys: [user_id: :id, account_id: :id],
      on_replace: :delete
    )

    has_many(:sessions, Session)

    timestamps()
  end

  @doc false
  def registration_changeset(user, attrs) do
    user
    |> changeset(attrs)
    |> validate_required([:password])
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password, :encrypted_full_name, :role])
    |> validate_required([:email, :role])
    |> update_change(:email, &normalize_email/1)
    |> validate_length(:email, max: 255)
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> validate_inclusion(:role, @roles)
    |> validate_password()
    |> unique_constraint(:email)
  end

  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_password()
  end

  def roles, do: @roles

  def with_memberships(query) do
    from(user in query,
      preload: [memberships: ^from(m in AccountMembership, preload: [:account])]
    )
  end

  def with_memberships, do: with_memberships(__MODULE__)

  def with_shared_accounts(query) do
    from(user in query,
      preload: [
        shared_accounts:
          ^from(a in Account,
            preload: [memberships: ^from(m in AccountMembership, preload: [:user])]
          )
      ]
    )
  end

  def with_shared_accounts, do: with_shared_accounts(__MODULE__)

  defp normalize_email(email) when is_binary(email) do
    email
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_email(other), do: other

  defp validate_password(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      password ->
        changeset
        |> validate_length(:password, min: 12, max: 72)
        |> maybe_disallow_whitespace(password)
    end
  end

  defp maybe_disallow_whitespace(changeset, password) do
    if maybe_has_whitespace?(password) do
      add_error(changeset, :password, "cannot contain whitespace")
    else
      changeset
    end
  end

  defp maybe_has_whitespace?(password) do
    String.match?(password, ~r/\s/)
  end
end
