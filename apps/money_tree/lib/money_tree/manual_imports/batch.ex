defmodule MoneyTree.ManualImports.Batch do
  @moduledoc """
  Metadata and lifecycle state for a single manual import upload batch.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Accounts.Account
  alias MoneyTree.ManualImports.Row
  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @valid_statuses ~w(
    uploaded
    mapped
    parsed
    reviewed
    committing
    committed
    rollback_pending
    rolled_back
    failed
  )

  schema "manual_import_batches" do
    field :source_institution, :string
    field :source_account_label, :string
    field :file_name, :string
    field :file_mime_type, :string
    field :file_size_bytes, :integer
    field :file_sha256, :string
    field :raw_file_storage_key, :string
    field :detected_preset_key, :string
    field :selected_preset_key, :string
    field :mapping_config, :map, default: %{}
    field :status, :string, default: "uploaded"
    field :row_count, :integer, default: 0
    field :accepted_count, :integer, default: 0
    field :excluded_count, :integer, default: 0
    field :duplicate_count, :integer, default: 0
    field :committed_count, :integer, default: 0
    field :error_count, :integer, default: 0
    field :started_at, :utc_datetime_usec
    field :committed_at, :utc_datetime_usec
    field :rolled_back_at, :utc_datetime_usec

    belongs_to :user, User
    belongs_to :account, Account
    has_many :rows, Row, foreign_key: :manual_import_batch_id

    timestamps()
  end

  @doc false
  def changeset(batch, attrs) do
    batch
    |> cast(attrs, [
      :user_id,
      :account_id,
      :source_institution,
      :source_account_label,
      :file_name,
      :file_mime_type,
      :file_size_bytes,
      :file_sha256,
      :raw_file_storage_key,
      :detected_preset_key,
      :selected_preset_key,
      :mapping_config,
      :status,
      :row_count,
      :accepted_count,
      :excluded_count,
      :duplicate_count,
      :committed_count,
      :error_count,
      :started_at,
      :committed_at,
      :rolled_back_at
    ])
    |> validate_required([:user_id, :status])
    |> validate_length(:source_institution, max: 120)
    |> validate_length(:source_account_label, max: 180)
    |> validate_length(:file_name, max: 255)
    |> validate_length(:file_mime_type, max: 120)
    |> validate_length(:file_sha256, max: 128)
    |> validate_length(:raw_file_storage_key, max: 400)
    |> validate_length(:detected_preset_key, max: 120)
    |> validate_length(:selected_preset_key, max: 120)
    |> validate_length(:status, max: 60)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:file_size_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:row_count, greater_than_or_equal_to: 0)
    |> validate_number(:accepted_count, greater_than_or_equal_to: 0)
    |> validate_number(:excluded_count, greater_than_or_equal_to: 0)
    |> validate_number(:duplicate_count, greater_than_or_equal_to: 0)
    |> validate_number(:committed_count, greater_than_or_equal_to: 0)
    |> validate_number(:error_count, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:account_id)
  end
end
