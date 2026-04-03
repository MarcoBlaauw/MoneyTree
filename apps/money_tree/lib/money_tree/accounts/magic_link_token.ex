defmodule MoneyTree.Accounts.MagicLinkToken do
  @moduledoc """
  One-time browser login token delivered by email.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "magic_link_tokens" do
    field :token_hash, :binary
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    field :requested_ip, :string
    field :requested_user_agent, :string
    field :context, :string, default: "web_magic_link"

    belongs_to :user, User

    timestamps()
  end

  @doc false
  def changeset(token, attrs) do
    token
    |> cast(attrs, [
      :token_hash,
      :expires_at,
      :consumed_at,
      :requested_ip,
      :requested_user_agent,
      :context,
      :user_id
    ])
    |> validate_required([:token_hash, :expires_at, :context, :user_id])
    |> validate_length(:context, min: 1, max: 64)
    |> validate_length(:requested_user_agent, max: 512)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:token_hash)
  end
end
