defmodule MoneyTree.Teller.SyncWorkerTest do
  use MoneyTree.DataCase, async: true

  alias Decimal
  alias MoneyTree.Accounts.Account
  alias MoneyTree.AccountsFixtures
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.InstitutionsFixtures
  alias MoneyTree.Repo
  alias MoneyTree.Teller.SyncWorker
  alias MoneyTree.Transactions.Transaction
  alias Oban.Job

  defmodule SuccessClient do
    def list_accounts(_params) do
      {:ok,
       %{
         "data" => [
           %{
             "id" => "acct-worker",
             "name" => "Worker Account",
             "type" => "depository",
             "currency" => "USD",
             "balances" => %{"current" => "42.00", "available" => "21.00"}
           }
         ],
         "next_cursor" => nil
       }}
    end

    def list_transactions("acct-worker", _params) do
      {:ok,
       %{
         "data" => [
           %{
             "id" => "txn-worker",
             "amount" => "-1.00",
             "currency" => "USD",
             "posted_at" => "2024-02-01T00:00:00Z",
             "description" => "Worker txn"
           }
         ],
         "next_cursor" => nil
       }}
    end
  end

  defmodule RateLimitClient do
    def list_accounts(_params) do
      {:error,
       %{
         type: :http,
         status: 429,
         headers: [{"Retry-After", "30"}],
         details: %{message: "slow down"}
       }}
    end
  end

  defmodule MissingAccountClient do
    def list_accounts(_params) do
      {:ok,
       %{
         "data" => [
           %{
             "name" => "Incomplete",
             "currency" => "USD"
           }
         ],
         "next_cursor" => nil
       }}
    end

    def list_transactions(_account_id, _params) do
      {:ok, %{"data" => [], "next_cursor" => nil}}
    end
  end

  test "perform/1 runs synchronizer and updates connection" do
    user = AccountsFixtures.user_fixture()

    connection = InstitutionsFixtures.connection_fixture(user)

    args = %{
      "connection_id" => connection.id,
      "mode" => "initial",
      "client" => Atom.to_string(__MODULE__.SuccessClient)
    }

    assert :ok = SyncWorker.perform(%Job{args: args, attempt: 1})

    refreshed = Repo.get!(Connection, connection.id)
    assert refreshed.last_synced_at
    assert refreshed.last_sync_error == nil

    account = Repo.get_by!(Account, external_id: "acct-worker")
    assert Decimal.eq?(account.current_balance, Decimal.new("42.00"))

    transaction = Repo.get_by!(Transaction, external_id: "txn-worker")
    assert transaction.account_id == account.id
  end

  test "perform/1 snoozes when rate limited" do
    user = AccountsFixtures.user_fixture()

    connection = InstitutionsFixtures.connection_fixture(user)

    args = %{
      "connection_id" => connection.id,
      "client" => Atom.to_string(__MODULE__.RateLimitClient)
    }

    assert {:snooze, seconds} = SyncWorker.perform(%Job{args: args, attempt: 1})
    assert seconds == 30

    refreshed = Repo.get!(Connection, connection.id)
    assert Map.get(refreshed.last_sync_error, "type") == "rate_limited"
    assert refreshed.last_sync_error_at
  end

  test "dispatch mode completes when no connections exist" do
    assert :ok = SyncWorker.perform(%Job{args: %{"mode" => "dispatch"}, attempt: 1})
  end

  test "returns error when synchronizer fails" do
    user = AccountsFixtures.user_fixture()
    connection = InstitutionsFixtures.connection_fixture(user)

    args = %{
      "connection_id" => connection.id,
      "client" => Atom.to_string(__MODULE__.MissingAccountClient)
    }

    assert {:error, {:missing_account_identifier, _info}} =
             SyncWorker.perform(%Job{args: args, attempt: 2})

    refreshed = Repo.get!(Connection, connection.id)

    error_type =
      Map.get(refreshed.last_sync_error, :type) || Map.get(refreshed.last_sync_error, "type")

    assert error_type == :missing_account_identifier or error_type == "missing_account_identifier"
    assert refreshed.last_sync_error_at
  end
end
