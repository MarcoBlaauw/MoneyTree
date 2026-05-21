defmodule MoneyTree.Repo.Migrations.WidenProviderExternalIds do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      modify :external_id, :string, size: 512, null: false
    end

    alter table(:transactions) do
      modify :external_id, :string, size: 512, null: false
      modify :source_transaction_id, :string, size: 512
    end
  end
end
