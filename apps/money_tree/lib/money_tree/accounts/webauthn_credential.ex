defmodule MoneyTree.Accounts.WebAuthnCredential do
  @moduledoc """
  Registered WebAuthn credential for passkey and hardware security-key sign-in.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Users.User

  @kinds ~w(passkey security_key)
  @attachments ~w(platform cross-platform)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "webauthn_credentials" do
    field :credential_id, :binary
    field :public_key, :binary
    field :label, :string
    field :kind, :string, default: "passkey"
    field :aaguid, :binary
    field :sign_count, :integer, default: 0
    field :transports, {:array, :string}, default: []
    field :attachment, :string
    field :backup_eligible, :boolean, default: false
    field :backed_up, :boolean, default: false
    field :user_handle, :binary
    field :last_used_at, :utc_datetime_usec
    field :last_verified_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps()
  end

  @doc false
  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [
      :credential_id,
      :public_key,
      :label,
      :kind,
      :aaguid,
      :sign_count,
      :transports,
      :attachment,
      :backup_eligible,
      :backed_up,
      :user_handle,
      :last_used_at,
      :last_verified_at,
      :revoked_at,
      :user_id
    ])
    |> validate_required([:credential_id, :public_key, :kind, :user_id])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:attachment, @attachments)
    |> validate_length(:label, max: 160)
    |> validate_number(:sign_count, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:credential_id)
  end
end
