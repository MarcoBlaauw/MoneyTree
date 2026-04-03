defmodule MoneyTree.Accounts.WebAuthnChallenge do
  @moduledoc """
  One-time WebAuthn challenge state for registration and authentication ceremonies.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Users.User

  @purposes ~w(registration authentication)
  @attachments ~w(platform cross-platform)
  @verifications ~w(required preferred discouraged)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "webauthn_challenges" do
    field :challenge, :string
    field :purpose, :string
    field :context, :string, default: "security_settings"
    field :rp_id, :string
    field :origin, :string
    field :user_verification, :string, default: "preferred"
    field :authenticator_attachment, :string
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps()
  end

  @doc false
  def changeset(challenge, attrs) do
    challenge
    |> cast(attrs, [
      :challenge,
      :purpose,
      :context,
      :rp_id,
      :origin,
      :user_verification,
      :authenticator_attachment,
      :expires_at,
      :used_at,
      :user_id
    ])
    |> validate_required([
      :challenge,
      :purpose,
      :context,
      :rp_id,
      :origin,
      :user_verification,
      :expires_at,
      :user_id
    ])
    |> validate_inclusion(:purpose, @purposes)
    |> validate_inclusion(:user_verification, @verifications)
    |> validate_inclusion(:authenticator_attachment, @attachments)
    |> validate_length(:challenge, min: 16, max: 255)
    |> validate_length(:context, min: 1, max: 64)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:challenge)
  end
end
