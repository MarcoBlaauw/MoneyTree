defmodule MoneyTree.Repo.Migrations.CreateWebauthnSecurityTables do
  use Ecto.Migration

  def change do
    create table(:webauthn_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :credential_id, :binary, null: false
      add :public_key, :binary, null: false
      add :label, :string
      add :kind, :string, null: false, default: "passkey"
      add :aaguid, :binary
      add :sign_count, :integer, null: false, default: 0
      add :transports, {:array, :string}, null: false, default: []
      add :attachment, :string
      add :backup_eligible, :boolean, null: false, default: false
      add :backed_up, :boolean, null: false, default: false
      add :user_handle, :binary
      add :last_used_at, :utc_datetime_usec
      add :last_verified_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:webauthn_credentials, [:credential_id])
    create index(:webauthn_credentials, [:user_id])
    create index(:webauthn_credentials, [:user_id, :kind])
    create index(:webauthn_credentials, [:revoked_at])

    create table(:webauthn_challenges, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :challenge, :string, null: false
      add :purpose, :string, null: false
      add :context, :string, null: false, default: "security_settings"
      add :rp_id, :string, null: false
      add :origin, :string, null: false
      add :user_verification, :string, null: false, default: "preferred"
      add :authenticator_attachment, :string
      add :expires_at, :utc_datetime_usec, null: false
      add :used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:webauthn_challenges, [:challenge])
    create index(:webauthn_challenges, [:user_id])
    create index(:webauthn_challenges, [:purpose])
    create index(:webauthn_challenges, [:expires_at])
  end
end
