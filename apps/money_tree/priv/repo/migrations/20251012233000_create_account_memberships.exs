defmodule MoneyTree.Repo.Migrations.CreateAccountMemberships do
  use Ecto.Migration

  def up do
    create table(:account_memberships, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:role, :string, null: false)
      add(:invited_at, :utc_datetime_usec)
      add(:accepted_at, :utc_datetime_usec)
      add(:revoked_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:account_memberships, [:account_id, :user_id]))

    execute(&backfill_primary_memberships/0, fn -> :ok end)
  end

  def down do
    drop(table(:account_memberships))
  end

  defp backfill_primary_memberships do
    repo().transaction(fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      %{rows: rows} =
        repo().query!("SELECT id, user_id FROM accounts WHERE user_id IS NOT NULL")

      entries =
        Enum.map(rows, fn [account_id, user_id] ->
          %{
            id: Ecto.UUID.generate(),
            account_id: account_id,
            user_id: user_id,
            role: "primary",
            invited_at: now,
            accepted_at: now,
            inserted_at: now,
            updated_at: now
          }
        end)

      case entries do
        [] -> :ok
        _ -> repo().insert_all(:account_memberships, entries)
      end
    end)
  end
end
