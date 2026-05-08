defmodule MoneyTree.Loans.LoanDocument do
  @moduledoc """
  Metadata for a loan document uploaded for review.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Loans.LoanDocumentExtraction
  alias MoneyTree.Mortgages.Mortgage
  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @document_types ~w(
    mortgage_statement
    closing_disclosure
    loan_estimate
    escrow_statement
    payoff_quote
    lender_quote
    property_tax_bill
    homeowners_insurance
    auto_loan_statement
    student_loan_statement
    personal_loan_statement
    credit_card_statement
    other
  )

  @statuses ~w(uploaded queued extracting pending_review confirmed rejected failed archived)

  schema "loan_documents" do
    field :document_type, :string
    field :original_filename, :string
    field :content_type, :string
    field :byte_size, :integer
    field :storage_key, :string
    field :checksum_sha256, :string
    field :status, :string, default: "uploaded"
    field :uploaded_at, :utc_datetime_usec

    belongs_to :user, User
    belongs_to :mortgage, Mortgage
    has_many :extractions, LoanDocumentExtraction

    timestamps()
  end

  @doc false
  def changeset(document, attrs) do
    document
    |> cast(attrs, [
      :user_id,
      :mortgage_id,
      :document_type,
      :original_filename,
      :content_type,
      :byte_size,
      :storage_key,
      :checksum_sha256,
      :status,
      :uploaded_at
    ])
    |> validate_required([
      :user_id,
      :mortgage_id,
      :document_type,
      :original_filename,
      :content_type,
      :byte_size,
      :storage_key,
      :status,
      :uploaded_at
    ])
    |> update_change(:document_type, &normalize_downcase/1)
    |> update_change(:status, &normalize_downcase/1)
    |> validate_inclusion(:document_type, @document_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:byte_size, greater_than: 0)
    |> validate_length(:original_filename, min: 1, max: 255)
    |> validate_length(:content_type, min: 1, max: 160)
    |> validate_length(:storage_key, min: 1, max: 400)
    |> validate_length(:checksum_sha256, is: 64)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:mortgage_id)
    |> unique_constraint(:storage_key, name: :loan_documents_user_id_storage_key_index)
  end

  def document_types, do: @document_types
  def statuses, do: @statuses

  defp normalize_downcase(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_downcase(value), do: value
end
