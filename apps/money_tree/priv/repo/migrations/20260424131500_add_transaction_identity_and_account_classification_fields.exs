defmodule MoneyTree.Repo.Migrations.AddTransactionIdentityAndAccountClassificationFields do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :internal_account_kind, :string
      add :liability_type, :string
      add :is_internal, :boolean, null: false, default: true
      add :include_in_cash_flow, :boolean, null: false, default: true
      add :include_in_net_worth, :boolean, null: false, default: true
      add :manual_account, :boolean, null: false, default: false
    end

    create index(:accounts, [:internal_account_kind])
    create index(:accounts, [:liability_type])

    alter table(:transactions) do
      add :source, :string, null: false, default: "unknown"
      add :source_transaction_id, :string
      add :source_reference, :string
      add :source_fingerprint, :string
      add :normalized_fingerprint, :string
      add :authorized_at, :utc_datetime_usec
      add :original_description, :string
      add :transaction_kind, :string, null: false, default: "unknown"
      add :excluded_from_spending, :boolean, null: false, default: false
      add :needs_review, :boolean, null: false, default: false
      add :review_reason, :string
    end

    create index(:transactions, [:account_id, :posted_at, :amount])
    create index(:transactions, [:source, :source_transaction_id])
    create index(:transactions, [:source_fingerprint])
    create index(:transactions, [:normalized_fingerprint])
  end
end
