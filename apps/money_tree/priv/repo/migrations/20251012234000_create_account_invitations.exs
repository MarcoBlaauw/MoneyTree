defmodule MoneyTree.Repo.Migrations.CreateAccountInvitations do
  use Ecto.Migration

  def change do
    create table(:account_invitations) do
      add :email, :string, null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :status, :string, null: false, default: "pending"
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :invitee_user_id, references(:users, on_delete: :nilify_all)
      add :account_id, references(:accounts, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:account_invitations, [:user_id])
    create index(:account_invitations, [:invitee_user_id])
    create index(:account_invitations, [:account_id])
    create unique_index(:account_invitations, [:token_hash])

    create unique_index(
             :account_invitations,
             [:account_id, :email],
             where: "status = 'pending'",
             name: :account_invitations_account_email_pending_index
           )
  end
end
