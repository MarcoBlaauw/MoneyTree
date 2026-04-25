defmodule MoneyTree.Repo.Migrations.CreateManualImportTables do
  use Ecto.Migration

  def change do
    create table(:manual_import_batches, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :account_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)

      add :source_institution, :string
      add :source_account_label, :string
      add :file_name, :string
      add :file_mime_type, :string
      add :file_size_bytes, :bigint
      add :file_sha256, :string
      add :raw_file_storage_key, :string
      add :detected_preset_key, :string
      add :selected_preset_key, :string
      add :mapping_config, :map, null: false, default: %{}
      add :status, :string, null: false, default: "uploaded"
      add :row_count, :integer, null: false, default: 0
      add :accepted_count, :integer, null: false, default: 0
      add :excluded_count, :integer, null: false, default: 0
      add :duplicate_count, :integer, null: false, default: 0
      add :committed_count, :integer, null: false, default: 0
      add :error_count, :integer, null: false, default: 0
      add :started_at, :utc_datetime_usec
      add :committed_at, :utc_datetime_usec
      add :rolled_back_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:manual_import_batches, [:user_id, :inserted_at])
    create index(:manual_import_batches, [:status])
    create index(:manual_import_batches, [:file_sha256])

    create table(:manual_import_rows, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :manual_import_batch_id,
          references(:manual_import_batches, type: :binary_id, on_delete: :delete_all),
          null: false

      add :row_index, :integer, null: false
      add :raw_row, :map, null: false, default: %{}
      add :parse_status, :string, null: false, default: "parsed"
      add :parse_errors, :map, null: false, default: %{}
      add :posted_at, :utc_datetime_usec
      add :authorized_at, :utc_datetime_usec
      add :description, :string
      add :original_description, :string
      add :merchant_name, :string
      add :amount, :decimal, precision: 18, scale: 2
      add :currency, :string, size: 3, null: false, default: "USD"
      add :direction, :string
      add :external_transaction_id, :string
      add :source_reference, :string
      add :check_number, :string
      add :category_name_snapshot, :string
      add :category_rule_id, references(:category_rules, type: :binary_id, on_delete: :nilify_all)

      add :duplicate_candidate_transaction_id,
          references(:transactions, type: :binary_id, on_delete: :nilify_all)

      add :duplicate_confidence, :decimal, precision: 5, scale: 4

      add :transfer_match_candidate_transaction_id,
          references(:transactions, type: :binary_id, on_delete: :nilify_all)

      add :transfer_match_confidence, :decimal, precision: 5, scale: 4
      add :transfer_match_status, :string
      add :review_decision, :string, null: false, default: "accept"

      add :committed_transaction_id,
          references(:transactions, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:manual_import_rows, [:manual_import_batch_id, :row_index],
             name: :manual_import_rows_batch_row_index_index
           )

    create index(:manual_import_rows, [:parse_status])
    create index(:manual_import_rows, [:review_decision])
    create index(:manual_import_rows, [:committed_transaction_id])

    alter table(:transactions) do
      add :manual_import_batch_id,
          references(:manual_import_batches, type: :binary_id, on_delete: :nilify_all)

      add :manual_import_row_id,
          references(:manual_import_rows, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:transactions, [:manual_import_batch_id])
    create index(:transactions, [:manual_import_row_id])
  end
end
