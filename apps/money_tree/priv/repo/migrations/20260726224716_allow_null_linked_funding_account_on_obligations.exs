defmodule MoneyTree.Repo.Migrations.AllowNullLinkedFundingAccountOnObligations do
  use Ecto.Migration

  def change do
    alter table(:obligations) do
      modify :linked_funding_account_id, :binary_id, null: true
    end
  end
end
