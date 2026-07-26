defmodule MoneyTree.Institutions.ConnectionTest do
  use MoneyTree.DataCase, async: true

  alias Ecto.Adapters.SQL
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

      assert "is invalid" in errors_on(changeset).metadata
      refute Map.has_key?(errors_on(changeset), :webhook_secret)
      assert changeset.changes.sync_cursor == "next-cursor"
    end

    test "accepts simplefin provider while rejecting unknown providers" do
      attrs = %{
        user_id: Ecto.UUID.generate(),
        institution_id: Ecto.UUID.generate(),
        provider: "simplefin"
      }

      assert Connection.changeset(%Connection{}, attrs).valid?

      refute Connection.changeset(%Connection{}, Map.put(attrs, :provider, "unknown")).valid?
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
        SQL.query!(
          Repo,
          "select encrypted_credentials from institution_connections where id = $1::uuid",
          [Ecto.UUID.dump!(connection.id)]
        ).rows
        |> List.first()
        |> List.first()

      assert connection.encrypted_credentials == "super-secret"
      refute raw_value == "super-secret"
      refute raw_value == nil
    end
  end

  describe "shared access" do
    setup do
      owner = AccountsFixtures.user_fixture()
      member = AccountsFixtures.user_fixture()
      connection = InstitutionsFixtures.connection_fixture(owner)

      account =
        AccountsFixtures.account_fixture(owner, %{
          institution_id: connection.institution_id,
          institution_connection_id: connection.id
        })

      AccountsFixtures.primary_membership_fixture(account)
      AccountsFixtures.membership_fixture(account, member, %{role: :member})

      {:ok, owner: owner, member: member, connection: connection}
    end

    test "members can retrieve active connections", %{member: member, connection: connection} do
      assert {:ok, fetched} =
               Institutions.get_active_connection_for_user(member, connection.id,
                 preload: [:accounts]
               )

      assert fetched.id == connection.id

      connections = Institutions.list_active_connections(member)
      assert Enum.map(connections, & &1.id) == [connection.id]
    end

    test "membership does not grant mutation privileges", %{
      member: member,
      connection: connection
    } do
      assert {:error, :not_found} =
               Institutions.update_connection(member, connection.id, %{
                 metadata: %{"status" => "active", "note" => "shared-user"}
               })
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
