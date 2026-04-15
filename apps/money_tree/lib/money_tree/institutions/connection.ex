defmodule MoneyTree.Institutions.Connection do
  @moduledoc """
  Represents a user's authenticated connection to a financial institution via an aggregator.
  """

  use Ecto.Schema

  import Ecto.Changeset

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
    field :metadata, Map
    field :provider, :string, default: "teller"
    field :provider_metadata, :map

    field :teller_enrollment_id, :string
    field :teller_user_id, :string

    field :sync_cursor, :string
    field :sync_cursor_updated_at, :utc_datetime_usec
    field :accounts_cursor, :string
    field :transactions_cursor, :string
    field :last_synced_at, :utc_datetime_usec
    field :last_sync_error, :map
    field :last_sync_error_at, :utc_datetime_usec

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
      :provider,
      :provider_metadata,
      :teller_enrollment_id,
      :teller_user_id,
      :sync_cursor,
      :sync_cursor_updated_at,
      :accounts_cursor,
      :transactions_cursor,
      :last_synced_at,
      :last_sync_error,
      :last_sync_error_at
    ])
    |> validate_required([:user_id, :institution_id, :provider])
    |> normalize_cursor()
    |> update_change(:provider, &normalize_provider/1)
    |> validate_inclusion(:provider, ["teller", "plaid"])
    |> validate_length(:teller_enrollment_id, max: 120)
    |> validate_length(:teller_user_id, max: 120)
    |> validate_length(:sync_cursor, max: 1024)
    |> validate_length(:accounts_cursor, max: 1024)
    |> validate_length(:transactions_cursor, max: 1024)
    |> validate_metadata_is_map()
    |> validate_provider_metadata_is_map()
    |> validate_sync_error_is_map()
    |> validate_webhook_secret()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:institution_id)
    |> unique_constraint([:user_id, :institution_id, :provider],
      name: :institution_connections_user_id_institution_id_provider_index
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

  defp validate_sync_error_is_map(changeset) do
    validate_change(changeset, :last_sync_error, fn :last_sync_error, value ->
      cond do
        is_nil(value) -> []
        is_map(value) -> []
        true -> [{:last_sync_error, "must be a map"}]
      end
    end)
  end

  defp validate_metadata_is_map(changeset) do
    validate_change(changeset, :metadata, fn :metadata, value ->
      cond do
        is_nil(value) -> []
        is_map(value) -> []
        true -> [{:metadata, "must be a map"}]
      end
    end)
  end

  defp validate_provider_metadata_is_map(changeset) do
    validate_change(changeset, :provider_metadata, fn :provider_metadata, value ->
      cond do
        is_nil(value) -> []
        is_map(value) -> []
        true -> [{:provider_metadata, "must be a map"}]
      end
    end)
  end

  defp normalize_provider(provider) when is_binary(provider),
    do: provider |> String.trim() |> String.downcase()

  defp normalize_provider(provider) when is_atom(provider),
    do: provider |> Atom.to_string() |> normalize_provider()

  defp normalize_provider(provider), do: provider

  defp validate_webhook_secret(changeset) do
    validate_change(changeset, :webhook_secret, fn :webhook_secret, value ->
      cond do
        is_nil(value) -> []
        is_binary(value) and byte_size(value) > 0 -> []
        true -> [{:webhook_secret, "must be a non-empty binary"}]
      end
    end)
  end
end
