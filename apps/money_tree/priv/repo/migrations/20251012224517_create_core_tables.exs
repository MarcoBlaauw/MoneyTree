defmodule MoneyTree.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration

  def change do
    execute("CREATE EXTENSION IF NOT EXISTS \"citext\"", "DROP EXTENSION IF EXISTS \"citext\"")

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext, null: false
      add :password_hash, :string, null: false
      add :encrypted_full_name, :binary

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])

    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :context, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :last_used_at, :utc_datetime_usec
      add :ip_address, :string
      add :user_agent, :string
      add :encrypted_metadata, :binary

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sessions, [:token_hash])
    create unique_index(:sessions, [:user_id, :context])

    create table(:institutions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :external_id, :string, null: false
      add :website_url, :string
      add :encrypted_credentials, :binary
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:institutions, [:slug])
    create unique_index(:institutions, [:external_id])

    create table(:accounts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :institution_id, references(:institutions, type: :binary_id, on_delete: :nilify_all)
      add :name, :string, null: false
      add :currency, :string, size: 3, null: false
      add :type, :string, null: false
      add :subtype, :string
      add :external_id, :string, null: false
      add :current_balance, :decimal, precision: 18, scale: 2, null: false, default: 0
      add :available_balance, :decimal, precision: 18, scale: 2
      add :limit, :decimal, precision: 18, scale: 2
      add :last_synced_at, :utc_datetime_usec
      add :encrypted_account_number, :binary
      add :encrypted_routing_number, :binary

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:accounts, [:user_id, :external_id])
    create index(:accounts, [:institution_id])
    create index(:accounts, [:currency])

    create table(:transactions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :external_id, :string, null: false
      add :amount, :decimal, precision: 18, scale: 2, null: false
      add :currency, :string, size: 3, null: false
      add :type, :string
      add :posted_at, :utc_datetime_usec, null: false
      add :settled_at, :utc_datetime_usec
      add :description, :string, null: false
      add :category, :string
      add :merchant_name, :string
      add :status, :string, null: false, default: "posted"
      add :encrypted_metadata, :binary

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:transactions, [:account_id, :external_id])
    create index(:transactions, [:posted_at])
    create index(:transactions, [:currency])
    create index(:transactions, [:status])
  end
end
