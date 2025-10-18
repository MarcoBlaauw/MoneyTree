defmodule MoneyTree.Accounts.AccountMembership do
  @moduledoc """
  Join table linking users to shared accounts with role-based permissions.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Accounts.Account
  alias MoneyTree.Users.User

  @roles [:primary, :member, :viewer]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "account_memberships" do
    field(:role, Ecto.Enum, values: @roles, default: :member)
    field(:invited_at, :utc_datetime_usec)
    field(:accepted_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    belongs_to(:account, Account)
    belongs_to(:user, User)

    timestamps()
  end

  @doc false
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:account_id, :user_id, :role, :invited_at, :accepted_at, :revoked_at])
    |> validate_required([:account_id, :user_id, :role])
    |> validate_change(:invited_at, &validate_timestamp/2)
    |> validate_change(:accepted_at, &validate_timestamp/2)
    |> validate_change(:revoked_at, &validate_timestamp/2)
    |> unique_constraint([:account_id, :user_id],
      name: :account_memberships_account_id_user_id_index
    )
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:user_id)
  end

  def roles, do: @roles

  defp validate_timestamp(field, value) do
    cond do
      is_nil(value) -> []
      match?(%DateTime{}, value) -> []
      true -> [{field, "must be a DateTime"}]
    end
  end
end
