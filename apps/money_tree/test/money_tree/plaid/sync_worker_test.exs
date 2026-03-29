defmodule MoneyTree.Plaid.SyncWorkerTest do
  use MoneyTree.DataCase, async: true

  alias Decimal
  alias MoneyTree.Accounts.Account
  alias MoneyTree.AccountsFixtures
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.InstitutionsFixtures
  alias MoneyTree.Plaid.SyncWorker
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction
  alias Oban.Job

  defmodule SuccessClient do
    def list_accounts(_params) do
      {:ok,
       %{
         "data" => [
           %{
             "id" => "plaid-acct",
             "name" => "Plaid Account",
             "type" => "depository",
             "currency" => "USD",
             "balances" => %{"current" => "52.00"}
           }
         ],
         "next_cursor" => nil
       }}
    end

    def list_transactions("plaid-acct", _params) do
      {:ok,
       %{
         "data" => [
           %{
             "id" => "plaid-txn",
             "amount" => "-3.50",
             "currency" => "USD",
             "posted_at" => "2024-02-01T00:00:00Z",
             "description" => "Plaid txn"
           }
         ],
         "next_cursor" => nil
       }}
    end
  end

  test "perform/1 syncs plaid connections" do
    user = AccountsFixtures.user_fixture()

    connection =
      InstitutionsFixtures.connection_fixture(user, %{provider: "plaid", metadata: %{"status" => "active", "provider" => "plaid"}})

    args = %{"connection_id" => connection.id, "client" => Atom.to_string(__MODULE__.SuccessClient)}

    assert :ok = SyncWorker.perform(%Job{args: args, attempt: 1})

    refreshed = Repo.get!(Connection, connection.id)
    assert refreshed.last_synced_at

    account = Repo.get_by!(Account, external_id: "plaid-acct")
    assert Decimal.eq?(account.current_balance, Decimal.new("52.00"))

    transaction = Repo.get_by!(Transaction, external_id: "plaid-txn")
    assert transaction.account_id == account.id
  end
end
