defmodule MoneyTree.Accounts.UserAdminTest do
  use MoneyTree.DataCase

  import MoneyTree.AccountsFixtures

  alias MoneyTree.Accounts

  describe "paginate_users/1" do
    test "returns paginated users with metadata" do
      _user_one = user_fixture(%{email: "one@example.com"})
      user_two = user_fixture(%{email: "two@example.com"})
      user_three = user_fixture(%{email: "three@example.com"})

      %{entries: entries, metadata: metadata} = Accounts.paginate_users(%{"page" => "1", "per_page" => "2"})

      assert length(entries) == 2
      assert metadata.page == 1
      assert metadata.per_page == 2
      assert metadata.total_entries == 3
      assert Enum.map(entries, & &1.id) == [user_three.id, user_two.id]
    end

    test "applies case-insensitive email search" do
      matching = user_fixture(%{email: "needle@example.com"})
      _other = user_fixture(%{email: "other@example.com"})

      %{entries: entries, metadata: metadata} = Accounts.paginate_users(%{"q" => "NEED"})

      assert Enum.map(entries, & &1.id) == [matching.id]
      assert metadata.total_entries == 1
    end
  end

  describe "fetch_user/2" do
    test "returns the user when present" do
      user = user_fixture()

      assert {:ok, fetched} = Accounts.fetch_user(user.id)
      assert fetched.id == user.id
    end

    test "returns error for missing user" do
      assert {:error, :not_found} = Accounts.fetch_user(Ecto.UUID.generate())
    end
  end

  describe "update_user_role/3" do
    test "updates the role and emits an audit event" do
      actor = user_fixture(%{role: :owner})
      user = user_fixture(%{role: :member})

      attach_audit_listener([:user_role_updated])

      assert {:ok, updated} = Accounts.update_user_role(user, :advisor, actor: actor)
      assert updated.role == :advisor

      assert_receive {:audit_event, [:money_tree, :audit, :user_role_updated], metadata}
      assert metadata[:user_id] == updated.id
      assert metadata[:actor_id] == actor.id
      assert metadata[:role] == :advisor
    end

    test "validates the supplied role" do
      user = user_fixture()

      assert {:error, :invalid_role} = Accounts.update_user_role(user, "invalid")
    end
  end

  describe "suspend_user/2 and reactivate_user/2" do
    test "toggle suspension state and emit audit events" do
      actor = user_fixture(%{role: :owner})
      user = user_fixture()

      attach_audit_listener([:user_suspended, :user_reactivated])

      assert {:ok, suspended} = Accounts.suspend_user(user, actor: actor)
      refute is_nil(suspended.suspended_at)

      assert_receive {:audit_event, [:money_tree, :audit, :user_suspended], suspended_meta}
      assert suspended_meta[:user_id] == user.id
      assert suspended_meta[:actor_id] == actor.id

      assert {:error, :already_suspended} = Accounts.suspend_user(suspended, actor: actor)

      assert {:ok, reactivated} = Accounts.reactivate_user(suspended, actor: actor)
      assert is_nil(reactivated.suspended_at)

      assert_receive {:audit_event, [:money_tree, :audit, :user_reactivated], reactivated_meta}
      assert reactivated_meta[:user_id] == user.id
      assert reactivated_meta[:actor_id] == actor.id

      assert {:error, :not_suspended} = Accounts.reactivate_user(reactivated, actor: actor)
    end
  end

  defp attach_audit_listener(events) do
    handler_id = "accounts-user-admin-#{System.unique_integer([:positive])}"
    parent = self()

    telemetry_events = Enum.map(events, &[:money_tree, :audit, &1])

    :telemetry.attach_many(
      handler_id,
      telemetry_events,
      fn event, _measurements, metadata, _config ->
        send(parent, {:audit_event, event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    handler_id
  end
end
