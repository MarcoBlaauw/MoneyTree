defmodule MoneyTree.Repo.Migrations.AddSuspendedAtToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :suspended_at, :utc_datetime_usec
    end

    create index(:users, [:suspended_at])
  end
end
