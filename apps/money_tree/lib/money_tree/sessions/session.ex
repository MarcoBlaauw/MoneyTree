defmodule MoneyTree.Sessions.Session do
  @moduledoc """
  Authentication session linked to a user with optional encrypted metadata.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Encrypted.Map, as: EncryptedMap
  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "sessions" do
    field :token_hash, :binary
    field :context, :string
    field :expires_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :ip_address, :string
    field :user_agent, :string
    field :encrypted_metadata, EncryptedMap

    belongs_to :user, User

    timestamps()
  end

  @doc false
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :token_hash,
      :context,
      :expires_at,
      :last_used_at,
      :ip_address,
      :user_agent,
      :encrypted_metadata,
      :user_id
    ])
    |> validate_required([:token_hash, :context, :expires_at, :user_id])
    |> validate_length(:context, min: 1, max: 64)
    |> validate_user_agent()
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:token_hash)
    |> unique_constraint(:context, name: :sessions_user_id_context_index)
  end

  defp validate_user_agent(changeset) do
    validate_length(changeset, :user_agent, max: 512)
  end
end
