defmodule MoneyTree.Repo.Migrations.CreateTransactionTransferMatches do
  use Ecto.Migration

  def change do
    create table(:transaction_transfer_matches, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :outflow_transaction_id,
          references(:transactions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :inflow_transaction_id,
          references(:transactions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :match_type, :string, null: false, default: "unknown"
      add :status, :string, null: false, default: "suggested"
      add :confidence_score, :decimal, precision: 5, scale: 4
      add :matched_by, :string, null: false, default: "system"
      add :match_reason, :string
      add :amount_difference, :decimal, precision: 18, scale: 2
      add :date_difference_days, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create index(:transaction_transfer_matches, [:outflow_transaction_id])
    create index(:transaction_transfer_matches, [:inflow_transaction_id])
    create index(:transaction_transfer_matches, [:status])

    create unique_index(
             :transaction_transfer_matches,
             [:outflow_transaction_id, :inflow_transaction_id],
             name: :transaction_transfer_matches_outflow_inflow_index
           )
  end
end
