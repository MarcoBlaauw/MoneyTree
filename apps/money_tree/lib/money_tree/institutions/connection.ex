defmodule MoneyTree.Institutions.Connection do
  @moduledoc """
  Represents a user's authenticated connection to a financial institution via an aggregator.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ecto.Changeset

  alias MoneyTree.Accounts.Account
  alias MoneyTree.Encrypted.Binary
  alias MoneyTree.Encrypted.Map
  alias MoneyTree.Institutions.Institution
  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "institution_connections" do
    field :encrypted_credentials, Binary
    field :webhook_secret, Binary
    field :webhook_secret_hash, :binary
    field :metadata, Map, default: %{}

    field :teller_enrollment_id, :string
    field :teller_user_id, :string

    field :sync_cursor, :string
    field :sync_cursor_updated_at, :utc_datetime_usec

    belongs_to :user, User
    belongs_to :institution, Institution

    has_many :accounts, Account, foreign_key: :institution_connection_id

    timestamps()
  end

  @doc false
  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :user_id,
      :institution_id,
      :encrypted_credentials,
      :webhook_secret,
      :metadata,
      :teller_enrollment_id,
      :teller_user_id,
      :sync_cursor,
      :sync_cursor_updated_at
    ])
    |> validate_required([:user_id, :institution_id])
    |> normalize_cursor()
    |> validate_length(:teller_enrollment_id, max: 120)
    |> validate_length(:teller_user_id, max: 120)
    |> validate_length(:sync_cursor, max: 1024)
    |> validate_metadata_is_map()
    |> validate_webhook_secret()
    |> maybe_put_webhook_secret_hash()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:institution_id)
    |> unique_constraint([:user_id, :institution_id],
      name: :institution_connections_user_id_institution_id_index
    )
    |> unique_constraint(:teller_enrollment_id,
      name: :institution_connections_teller_enrollment_id_index
    )
  end

  defp normalize_cursor(changeset) do
    update_change(changeset, :sync_cursor, fn
      cursor when is_binary(cursor) -> cursor |> String.trim() |> blank_to_nil()
      other -> other
    end)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp validate_metadata_is_map(changeset) do
    validate_change(changeset, :metadata, fn :metadata, value ->
      cond do
        is_nil(value) -> []
        is_map(value) -> []
        true -> [{:metadata, "must be a map"}]
      end
    end)
  end

  defp validate_webhook_secret(changeset) do
    validate_change(changeset, :webhook_secret, fn :webhook_secret, value ->
      cond do
        is_nil(value) -> []
        is_binary(value) and byte_size(value) > 0 -> []
        true -> [{:webhook_secret, "must be a non-empty binary"}]
      end
    end)
  end

  defp maybe_put_webhook_secret_hash(%Changeset{changes: %{webhook_secret: secret}} = changeset)
       when is_binary(secret) do
    put_change(changeset, :webhook_secret_hash, hash_webhook_secret(secret))
  end

  defp maybe_put_webhook_secret_hash(changeset), do: changeset

  defp hash_webhook_secret(secret) when is_binary(secret) do
    :crypto.hash(:sha256, secret)
  end
end
