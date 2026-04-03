defmodule MoneyTree.Repo.Migrations.CreateMagicLinkTokens do
  use Ecto.Migration

  def change do
    create table(:magic_link_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
      add :requested_ip, :string
      add :requested_user_agent, :string
      add :context, :string, null: false, default: "web_magic_link"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:magic_link_tokens, [:token_hash])
    create index(:magic_link_tokens, [:user_id])
    create index(:magic_link_tokens, [:expires_at])
  end
end
