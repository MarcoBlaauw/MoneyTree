defmodule MoneyTree.AccountsFixtures do
  @moduledoc """
  Test helpers for creating users and sessions.
  """

  alias MoneyTree.Accounts

  def unique_user_email do
    "user-#{System.unique_integer([:positive])}@example.com"
  end

  def valid_password do
    "SupersafePass123!"
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

  def session_fixture(user, attrs \\ %{}) do
    {:ok, session, token} = Accounts.create_session(user, attrs)
    %{session: session, token: token}
  end
end
