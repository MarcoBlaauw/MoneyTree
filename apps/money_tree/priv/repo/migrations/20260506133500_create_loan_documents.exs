defmodule MoneyTree.Repo.Migrations.CreateLoanDocuments do
  use Ecto.Migration

  def change do
    create table(:loan_documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :mortgage_id, references(:mortgages, type: :binary_id, on_delete: :delete_all),
        null: false

      add :document_type, :string, null: false
      add :original_filename, :string, null: false
      add :content_type, :string, null: false
      add :byte_size, :bigint, null: false
      add :storage_key, :string, null: false
      add :checksum_sha256, :string
      add :status, :string, null: false, default: "uploaded"
      add :uploaded_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:loan_documents, [:user_id])
    create index(:loan_documents, [:mortgage_id])
    create index(:loan_documents, [:document_type])
    create index(:loan_documents, [:status])
    create unique_index(:loan_documents, [:user_id, :storage_key])

    create table(:loan_document_extractions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :mortgage_id, references(:mortgages, type: :binary_id, on_delete: :delete_all),
        null: false

      add :loan_document_id,
          references(:loan_documents, type: :binary_id, on_delete: :delete_all),
          null: false

      add :extraction_method, :string, null: false
      add :model_name, :string
      add :status, :string, null: false, default: "pending_review"
      add :ocr_text_storage_key, :string
      add :raw_text_excerpt, :text
      add :extracted_payload, :map, null: false, default: %{}
      add :field_confidence, :map, null: false, default: %{}
      add :source_citations, :map, null: false, default: %{}
      add :reviewed_at, :utc_datetime_usec
      add :confirmed_at, :utc_datetime_usec
      add :rejected_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:loan_document_extractions, [:user_id])
    create index(:loan_document_extractions, [:mortgage_id])
    create index(:loan_document_extractions, [:loan_document_id])
    create index(:loan_document_extractions, [:status])
  end
end
