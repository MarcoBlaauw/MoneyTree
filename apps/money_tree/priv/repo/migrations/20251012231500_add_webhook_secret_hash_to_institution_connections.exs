defmodule MoneyTree.Repo.Migrations.AddWebhookSecretHashToInstitutionConnections do
  use Ecto.Migration

  alias Ecto.Changeset
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Repo
  alias MoneyTree.Vault

  import Ecto.Query

  def up do
    alter table(:institution_connections) do
      add :webhook_secret_hash, :binary
    end

    create index(:institution_connections, [:webhook_secret_hash])

    flush()

    ensure_vault_started()

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

  defp ensure_vault_started do
    case Process.whereis(Vault) do
      nil ->
        config = Application.fetch_env!(:money_tree, Vault)
        {:ok, _pid} = Vault.start_link(config)
        :ok

      _pid ->
        :ok
    end
  end
end
