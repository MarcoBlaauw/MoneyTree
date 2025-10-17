defmodule MoneyTree.Repo.Migrations.AddTellerSyncMetadataToConnections do
  use Ecto.Migration

  def change do
    alter table(:institution_connections) do
      add :accounts_cursor, :string
      add :transactions_cursor, :string
      add :last_synced_at, :utc_datetime_usec
      add :last_sync_error, :map
      add :last_sync_error_at, :utc_datetime_usec
    end
  end
end
