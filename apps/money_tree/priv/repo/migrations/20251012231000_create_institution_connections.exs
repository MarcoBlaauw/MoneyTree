defmodule MoneyTree.Repo.Migrations.CreateInstitutionConnections do
  use Ecto.Migration

  def change do
    create table(:institution_connections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :institution_id, references(:institutions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :teller_enrollment_id, :string
      add :teller_user_id, :string

      add :encrypted_credentials, :binary
      add :webhook_secret, :binary
      add :metadata, :binary

      add :sync_cursor, :string
      add :sync_cursor_updated_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:institution_connections, [:user_id, :institution_id],
             name: :institution_connections_user_id_institution_id_index
           )

    create unique_index(:institution_connections, [:teller_enrollment_id],
             where: "teller_enrollment_id IS NOT NULL",
             name: :institution_connections_teller_enrollment_id_index
           )

    create index(:institution_connections, [:teller_user_id])
  end
end
