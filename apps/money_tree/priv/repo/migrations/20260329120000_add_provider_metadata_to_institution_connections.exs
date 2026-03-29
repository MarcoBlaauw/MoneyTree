defmodule MoneyTree.Repo.Migrations.AddProviderMetadataToInstitutionConnections do
  use Ecto.Migration

  def change do
    alter table(:institution_connections) do
      add :provider, :string, null: false, default: "teller"
      add :provider_metadata, :map
    end

    drop_if_exists index(:institution_connections, [:user_id, :institution_id],
                     name: :institution_connections_user_id_institution_id_index
                   )

    create unique_index(:institution_connections, [:user_id, :institution_id, :provider],
             name: :institution_connections_user_id_institution_id_provider_index
           )

    create index(:institution_connections, [:provider])
  end
end
