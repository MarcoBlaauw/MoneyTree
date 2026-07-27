defmodule MoneyTree.SynchronizationTest do
  use MoneyTree.DataCase, async: false

  alias MoneyTree.AccountsFixtures
  alias MoneyTree.BankSync.ProviderRegistry
  alias MoneyTree.InstitutionsFixtures
  alias MoneyTree.Plaid.SyncWorker
  alias MoneyTree.Repo
  alias MoneyTree.Synchronization
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
    connection = InstitutionsFixtures.connection_fixture(user, %{provider: "plaid"})

    assert {:error, :provider_disabled} = Synchronization.schedule_initial_sync(connection)
    assert {:error, :provider_disabled} = Synchronization.schedule_incremental_sync(connection)
  end

  test "dispatch ignores disabled provider connections" do
    Application.put_env(:money_tree, ProviderRegistry,
      enabled_providers: ["simplefin", "manual"],
      primary_provider: "simplefin"
    )

    user = AccountsFixtures.user_fixture()
    _connection = InstitutionsFixtures.connection_fixture(user, %{provider: "plaid"})

    assert :ok = Synchronization.dispatch_incremental_syncs()
    assert :ok = Synchronization.dispatch_incremental_syncs(provider: "plaid")
  end

  test "schedule_initial_sync still schedules a sync minutes after an earlier initial sync" do
    Application.put_env(:money_tree, ProviderRegistry,
      enabled_providers: ["simplefin", "manual"],
      primary_provider: "simplefin"
    )

    user = AccountsFixtures.user_fixture()
    connection = InstitutionsFixtures.connection_fixture(user, %{provider: "simplefin"})

    # Oban's default test engine (:inline) executes jobs without ever persisting them,
    # which would make the uniqueness window this test exercises unobservable. :manual
    # persists the job row (without auto-executing it) like the real queue engine does.
    Oban.Testing.with_testing_mode(:manual, fn ->
      assert :ok = Synchronization.schedule_initial_sync(connection)

      # Simulate the first confirmation's sync having happened a minute ago, e.g.
      # approving newly discovered accounts well after the original claim.
      Repo.update_all(
        where(Job, worker: "MoneyTree.SimpleFin.SyncWorker"),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      assert :ok = Synchronization.schedule_initial_sync(connection)
    end)

    count =
      Job
      |> where(worker: "MoneyTree.SimpleFin.SyncWorker")
      |> Repo.all()
      |> Enum.count(&(&1.args["mode"] == "initial"))

    assert count == 2
  end

  test "schedule_initial_sync still dedupes an accidental immediate double submission" do
    Application.put_env(:money_tree, ProviderRegistry,
      enabled_providers: ["simplefin", "manual"],
      primary_provider: "simplefin"
    )

    user = AccountsFixtures.user_fixture()
    connection = InstitutionsFixtures.connection_fixture(user, %{provider: "simplefin"})

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert :ok = Synchronization.schedule_initial_sync(connection)
      assert :ok = Synchronization.schedule_initial_sync(connection)
    end)

    count =
      Job
      |> where(worker: "MoneyTree.SimpleFin.SyncWorker")
      |> Repo.all()
      |> Enum.count(&(&1.args["mode"] == "initial"))

    assert count == 1
  end

  test "stale worker jobs discard disabled provider connections" do
    Application.put_env(:money_tree, ProviderRegistry,
      enabled_providers: ["simplefin", "manual"],
      primary_provider: "simplefin"
    )

    user = AccountsFixtures.user_fixture()
    connection = InstitutionsFixtures.connection_fixture(user, %{provider: "plaid"})

    assert :discard =
             SyncWorker.perform(%Job{
               args: %{"connection_id" => connection.id, "mode" => "incremental"},
               attempt: 1
             })
  end
end
