defmodule MoneyTree.SynchronizationTest do
  use MoneyTree.DataCase, async: false

  alias MoneyTree.AccountsFixtures
  alias MoneyTree.BankSync.ProviderRegistry
  alias MoneyTree.InstitutionsFixtures
  alias MoneyTree.Synchronization
  alias MoneyTree.Teller.SyncWorker
  alias Oban.Job

  setup do
    original_registry = Application.get_env(:money_tree, ProviderRegistry)

    on_exit(fn ->
      if original_registry do
        Application.put_env(:money_tree, ProviderRegistry, original_registry)
      else
        Application.delete_env(:money_tree, ProviderRegistry)
      end
    end)

    :ok
  end

  test "does not schedule direct syncs for disabled legacy providers" do
    Application.put_env(:money_tree, ProviderRegistry,
      enabled_providers: ["simplefin", "manual"],
      primary_provider: "simplefin"
    )

    user = AccountsFixtures.user_fixture()
    connection = InstitutionsFixtures.connection_fixture(user)

    assert {:error, :provider_disabled} = Synchronization.schedule_initial_sync(connection)
    assert {:error, :provider_disabled} = Synchronization.schedule_incremental_sync(connection)
  end

  test "dispatch ignores disabled provider connections" do
    Application.put_env(:money_tree, ProviderRegistry,
      enabled_providers: ["simplefin", "manual"],
      primary_provider: "simplefin"
    )

    user = AccountsFixtures.user_fixture()
    _connection = InstitutionsFixtures.connection_fixture(user)

    assert :ok = Synchronization.dispatch_incremental_syncs()
    assert :ok = Synchronization.dispatch_incremental_syncs(provider: "teller")
  end

  test "stale worker jobs discard disabled provider connections" do
    Application.put_env(:money_tree, ProviderRegistry,
      enabled_providers: ["simplefin", "manual"],
      primary_provider: "simplefin"
    )

    user = AccountsFixtures.user_fixture()
    connection = InstitutionsFixtures.connection_fixture(user)

    assert :discard =
             SyncWorker.perform(%Job{
               args: %{"connection_id" => connection.id, "mode" => "incremental"},
               attempt: 1
             })
  end
end
