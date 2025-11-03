defmodule MoneyTree.Repo.Migrations.AddWebhookSecretHashToInstitutionConnections do
  use Ecto.Migration

  alias Ecto.Changeset
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Repo

  import Ecto.Query

  def up do
    alter table(:institution_connections) do
      add :webhook_secret_hash, :binary
    end

    create index(:institution_connections, [:webhook_secret_hash])

    flush()

    Repo.all(from c in Connection, where: not is_nil(c.webhook_secret))
    |> Enum.each(&backfill_webhook_secret_hash/1)
  end

  def down do
    drop index(:institution_connections, [:webhook_secret_hash])

    alter table(:institution_connections) do
      remove :webhook_secret_hash
    end
  end

  defp backfill_webhook_secret_hash(%Connection{webhook_secret: secret} = connection)
       when is_binary(secret) do
    hash = :crypto.hash(:sha256, secret)

    connection
    |> Changeset.change(webhook_secret_hash: hash)
    |> Repo.update!()
  end

  defp backfill_webhook_secret_hash(_connection), do: :ok
end
