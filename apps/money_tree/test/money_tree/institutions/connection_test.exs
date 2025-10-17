defmodule MoneyTree.Institutions.ConnectionTest do
  use MoneyTree.DataCase, async: true

  import Ecto.Query

  alias MoneyTree.AccountsFixtures
  alias MoneyTree.Institutions
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.InstitutionsFixtures
  alias MoneyTree.Repo

  describe "changeset validations" do
    test "requires user and institution identifiers" do
      changeset = Connection.changeset(%Connection{}, %{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).user_id
      assert "can't be blank" in errors_on(changeset).institution_id
    end

    test "validates metadata, webhook secret, and cursor normalization" do
      attrs = %{
        user_id: Ecto.UUID.generate(),
        institution_id: Ecto.UUID.generate(),
        metadata: "not-a-map",
        webhook_secret: "",
        sync_cursor: "  next-cursor  "
      }

      changeset = Connection.changeset(%Connection{}, attrs)

      assert "must be a map" in errors_on(changeset).metadata
      assert "must be a non-empty binary" in errors_on(changeset).webhook_secret
      assert changeset.changes.sync_cursor == "next-cursor"
    end
  end

  describe "encrypted credentials" do
    test "credentials are stored encrypted at rest" do
      user = AccountsFixtures.user_fixture()
      institution = InstitutionsFixtures.institution_fixture()

      {:ok, connection} =
        Institutions.create_connection(user, institution.id, %{
          encrypted_credentials: "super-secret"
        })

      raw_value =
        Repo.one!(
          from c in "institution_connections",
            select: c.encrypted_credentials,
            where: c.id == ^connection.id
        )

      assert connection.encrypted_credentials == "super-secret"
      refute raw_value == "super-secret"
      refute raw_value == nil
    end
  end

  describe "rotate_webhook_secret/2" do
    test "rotates and persists a new secret" do
      user = AccountsFixtures.user_fixture()
      connection = InstitutionsFixtures.connection_fixture(user)
      original_secret = connection.webhook_secret

      assert {:ok, updated, new_secret} =
               Institutions.rotate_webhook_secret(user, connection.id)

      assert byte_size(new_secret) >= 32
      assert updated.webhook_secret == new_secret
      refute new_secret == original_secret
    end
  end

  describe "update_sync_state/2" do
    test "trims cursors and updates timestamps" do
      user = AccountsFixtures.user_fixture()
      connection = InstitutionsFixtures.connection_fixture(user)
      synced_at = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, updated} =
        Institutions.update_sync_state(connection, %{
          sync_cursor: "  cursor-value  ",
          last_synced_at: synced_at,
          last_sync_error: %{"type" => "test"}
        })

      assert updated.sync_cursor == "cursor-value"
      assert DateTime.diff(updated.sync_cursor_updated_at, synced_at, :second) == 0
      assert DateTime.diff(updated.last_synced_at, synced_at, :second) == 0
      refute updated.last_sync_error == nil
      assert updated.last_sync_error_at
    end
  end
end
