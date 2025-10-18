defmodule MoneyTree.AccountsFixtures do
  @moduledoc """
  Test helpers for creating users and sessions.
  """

  alias MoneyTree.Accounts
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Accounts.AccountMembership
  alias MoneyTree.Repo
  alias Decimal

  def unique_user_email do
    "user-#{System.unique_integer([:positive])}@example.com"
  end

  def valid_password do
    "SupersafePass123!"
  end

  def unique_account_external_id do
    "acct-#{System.unique_integer([:positive])}"
  end

  def user_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    email = Map.get(attrs, :email, unique_user_email())
    password = Map.get(attrs, :password, valid_password())

    params =
      attrs
      |> Map.put_new(:email, email)
      |> Map.put(:password, password)
      |> Map.put_new(:encrypted_full_name, Map.get(attrs, :full_name, "Fixture User"))
      |> Map.put_new(:role, :member)
      |> Map.delete(:full_name)

    {:ok, user} = Accounts.register_user(params)

    %{user | password: nil}
  end

  def account_fixture(user, attrs \\ %{}) do
    attrs = Map.new(attrs)

    defaults = %{
      name: Map.get(attrs, :name, "Fixture Account"),
      currency: Map.get(attrs, :currency, "USD"),
      type: Map.get(attrs, :type, "depository"),
      subtype: Map.get(attrs, :subtype, "checking"),
      external_id: Map.get(attrs, :external_id, unique_account_external_id()),
      current_balance: Map.get(attrs, :current_balance, Decimal.new("0")),
      available_balance: Map.get(attrs, :available_balance, Decimal.new("0")),
      limit: Map.get(attrs, :limit),
      institution_id: Map.get(attrs, :institution_id),
      institution_connection_id: Map.get(attrs, :institution_connection_id),
      user_id: user.id
    }

    %Account{}
    |> Account.changeset(defaults)
    |> Repo.insert!()
  end

  def membership_fixture(account, user, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    attrs = Map.new(attrs)

    params =
      attrs
      |> Map.put_new(:role, :member)
      |> Map.put_new(:invited_at, now)
      |> Map.put_new(:accepted_at, now)
      |> Map.put(:account_id, account.id)
      |> Map.put(:user_id, user.id)

    %AccountMembership{}
    |> AccountMembership.changeset(params)
    |> Repo.insert!()
  end

  def primary_membership_fixture(account) do
    account = Repo.preload(account, :user)
    membership_fixture(account, account.user, %{role: :primary})
  end

  def session_fixture(user, attrs \\ %{}) do
    {:ok, session, token} = Accounts.create_session(user, attrs)
    %{session: session, token: token}
  end

  def invitation_fixture(account, inviter, attrs \\ %{}) do
    attrs = Map.new(attrs)
    email = Map.get(attrs, :email) || Map.get(attrs, "email") || unique_user_email()

    params =
      attrs
      |> Map.put(:email, email)

    {:ok, invitation, token} = Accounts.create_account_invitation(inviter, account, params)

    %{invitation: Repo.preload(invitation, [:invitee, :inviter]), token: token}
  end
end
