defmodule MoneyTree.Repo.Migrations.ChangeTransactionsCursorToText do
  use Ecto.Migration

  def up do
    alter table(:institution_connections) do
      modify :transactions_cursor, :text, from: :string
    end
  end

  def down do
    execute("
    UPDATE institution_connections
    SET transactions_cursor = LEFT(transactions_cursor, 1024)
    WHERE transactions_cursor IS NOT NULL AND octet_length(transactions_cursor) > 1024
    ")

    alter table(:institution_connections) do
      modify :transactions_cursor, :string, size: 1024, from: :text
    end
  end
end
