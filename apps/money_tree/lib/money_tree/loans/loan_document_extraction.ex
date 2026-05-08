defmodule MoneyTree.Loans.LoanDocumentExtraction do
  @moduledoc """
  Reviewable extracted candidate data from a loan document.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Loans.LoanDocument
  alias MoneyTree.Mortgages.Mortgage
  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @methods ~w(manual ocr ollama imported)
  @statuses ~w(pending_review confirmed rejected failed archived)

  schema "loan_document_extractions" do
    field :extraction_method, :string
    field :model_name, :string
    field :status, :string, default: "pending_review"
    field :ocr_text_storage_key, :string
    field :raw_text_excerpt, :string
    field :extracted_payload, :map, default: %{}
    field :field_confidence, :map, default: %{}
    field :source_citations, :map, default: %{}
    field :reviewed_at, :utc_datetime_usec
    field :confirmed_at, :utc_datetime_usec
    field :rejected_at, :utc_datetime_usec

    belongs_to :user, User
    belongs_to :mortgage, Mortgage
    belongs_to :loan_document, LoanDocument

    timestamps()
  end

  @doc false
  def changeset(extraction, attrs) do
    extraction
    |> cast(attrs, [
      :user_id,
      :mortgage_id,
      :loan_document_id,
      :extraction_method,
      :model_name,
      :status,
      :ocr_text_storage_key,
      :raw_text_excerpt,
      :extracted_payload,
      :field_confidence,
      :source_citations,
      :reviewed_at,
      :confirmed_at,
      :rejected_at
    ])
    |> validate_required([
      :user_id,
      :mortgage_id,
      :loan_document_id,
      :extraction_method,
      :status
    ])
    |> update_change(:extraction_method, &normalize_downcase/1)
    |> update_change(:status, &normalize_downcase/1)
    |> validate_inclusion(:extraction_method, @methods)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:model_name, max: 160)
    |> validate_length(:ocr_text_storage_key, max: 400)
    |> validate_length(:raw_text_excerpt, max: 10_000)
    |> validate_map(:extracted_payload)
    |> validate_map(:field_confidence)
    |> validate_map(:source_citations)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:mortgage_id)
    |> foreign_key_constraint(:loan_document_id)
  end

  def methods, do: @methods
  def statuses, do: @statuses

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end

  defp normalize_downcase(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_downcase(value), do: value
end
