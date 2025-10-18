defmodule MoneyTree.Accounts.AccountInvitation do
  @moduledoc """
  Represents an invitation for a user to join a shared account.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Accounts.Account
  alias MoneyTree.Users.User

  @statuses [:pending, :accepted, :revoked, :expired]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "account_invitations" do
    field :email, :string
    field :token_hash, :binary
    field :expires_at, :utc_datetime_usec
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :token, :string, virtual: true

    belongs_to :account, Account
    belongs_to :inviter, User, foreign_key: :user_id
    belongs_to :invitee, User, foreign_key: :invitee_user_id

    timestamps()
  end

  @doc false
  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [
      :email,
      :token_hash,
      :expires_at,
      :status,
      :account_id,
      :user_id,
      :invitee_user_id
    ])
    |> normalize_email()
    |> validate_required([:email, :token_hash, :expires_at, :status, :account_id, :user_id])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> validate_future_datetime(:expires_at)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:invitee_user_id)
    |> unique_constraint(:token_hash)
    |> unique_constraint(:email, name: :account_invitations_account_email_pending_index)
  end

  @doc """
  Returns the list of valid invitation statuses.
  """
  def statuses, do: @statuses

  defp normalize_email(changeset) do
    update_change(changeset, :email, fn
      nil -> nil
      email -> email |> String.trim() |> String.downcase()
    end)
  end

  defp validate_future_datetime(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        is_nil(value) ->
          []

        match?(%DateTime{}, value) ->
          if DateTime.compare(value, DateTime.utc_now()) in [:gt, :eq] do
            []
          else
            [{field, "must be in the future"}]
          end

        true ->
          [{field, "is invalid"}]
      end
    end)
  end
end
