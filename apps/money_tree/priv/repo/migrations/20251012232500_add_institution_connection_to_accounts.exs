defmodule MoneyTree.Repo.Migrations.AddInstitutionConnectionToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :institution_connection_id,
          references(:institution_connections, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:accounts, [:institution_connection_id])
  end
end
