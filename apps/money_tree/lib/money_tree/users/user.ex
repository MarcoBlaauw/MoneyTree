defmodule MoneyTree.Users.User do
  @moduledoc """
  User record with authentication metadata and encrypted profile attributes.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Accounts.Account
  alias MoneyTree.Encrypted.Binary
  alias MoneyTree.Sessions.Session

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "users" do
    field :email, :string
    field :password_hash, :string
    field :encrypted_full_name, Binary

    has_many :accounts, Account
    has_many :sessions, Session

    timestamps()
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password_hash, :encrypted_full_name])
    |> validate_required([:email, :password_hash])
    |> update_change(:email, &normalize_email/1)
    |> validate_length(:email, max: 255)
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> unique_constraint(:email)
  end

  defp normalize_email(email) when is_binary(email) do
    email
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_email(other), do: other
end
