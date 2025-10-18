defmodule MoneyTree.Teller.SynchronizerTest do
  use MoneyTree.DataCase, async: true

  alias Decimal
  alias MoneyTree.Accounts.Account
  alias MoneyTree.AccountsFixtures
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.InstitutionsFixtures
  alias MoneyTree.Repo
  alias MoneyTree.Teller.Synchronizer
  alias MoneyTree.Transactions.Transaction

  defmodule SuccessClient do
    def list_accounts(params) do
      case Map.get(params, :cursor) do
        nil ->
          {:ok,
           %{
             "data" => [
               %{
                 "id" => "acct-1",
                 "name" => "Checking",
                 "type" => "depository",
                 "subtype" => "checking",
                 "currency" => "usd",
                 "balances" => %{"current" => "100.00", "available" => "80.00"}
               }
             ],
             "next_cursor" => "acct-cursor"
           }}

        "acct-cursor" ->
          {:ok, %{"data" => [], "next_cursor" => nil}}
      end
    end

    def list_transactions("acct-1", params) do
      case Map.get(params, :cursor) do
        nil ->
          {:ok,
           %{
             "data" => [
               %{
                 "id" => "txn-1",
                 "amount" => "-25.50",
                 "currency" => "USD",
                 "posted_at" => "2024-01-01T10:00:00Z",
                 "description" => "Coffee Shop",
                 "status" => "posted",
                 "type" => "card"
               }
             ],
             "next_cursor" => nil
           }}

        _ ->
          {:ok, %{"data" => [], "next_cursor" => nil}}
      end
    end
  end

  defmodule RateLimitClient do
    def list_accounts(_params) do
      {:error,
       %{
         type: :http,
         status: 429,
         headers: [{"Retry-After", "45"}],
         details: %{message: "too many requests"}
       }}
    end
  end

  defmodule PagedClient do
    def list_accounts(params) do
      case Map.get(params, :cursor) do
        nil ->
          {:ok,
           %{
             "data" => [
               %{
                 "id" => "acct-1",
                 "name" => "Primary",
                 "type" => "depository",
                 "currency" => "USD",
                 "balances" => %{"current" => "100.00"}
               }
             ],
             "next_cursor" => "acct-cursor"
           }}

        "acct-cursor" ->
          {:ok,
           %{
             "data" => [
               %{
                 "id" => "acct-2",
                 "name" => "Savings",
                 "type" => "depository",
                 "currency" => "USD",
                 "balances" => %{"current" => "200.00"}
               }
             ],
             "next_cursor" => nil
           }}
      end
    end

    def list_transactions("acct-1", params) do
      case Map.get(params, :cursor) do
        nil ->
          {:ok,
           %{
             "data" => [
               %{
                 "id" => "txn-1",
                 "amount" => "-5.00",
                 "currency" => "USD",
                 "posted_at" => "2024-03-01T00:00:00Z",
                 "description" => "Coffee"
               }
             ],
             "next_cursor" => "txn-cursor"
           }}

        "txn-cursor" ->
          {:ok, %{"data" => [], "next_cursor" => nil}}
      end
    end

    def list_transactions("acct-2", _params) do
      {:ok, %{"data" => [], "next_cursor" => nil}}
    end
  end

  defmodule InvalidTransactionClient do
    def list_accounts(_params) do
      {:ok,
       %{
         "data" => [
           %{
             "id" => "acct-invalid",
             "name" => "Broken",
             "type" => "credit",
             "currency" => "USD"
           }
         ],
         "next_cursor" => nil
       }}
    end

    def list_transactions("acct-invalid", _params) do
      {:ok,
       %{
         "data" => [
           %{
             "id" => "txn-invalid",
             "amount" => nil,
             "currency" => "USD",
             "posted_at" => "2024-03-01T00:00:00Z"
           }
         ],
         "next_cursor" => nil
       }}
    end
  end

  describe "sync/2" do
    test "persists accounts, transactions, and updates connection state" do
      user = AccountsFixtures.user_fixture()

      connection = InstitutionsFixtures.connection_fixture(user)

      assert {:ok, result} = Synchronizer.sync(connection, client: SuccessClient, mode: "initial")
      assert result.accounts_synced == 1
      assert result.transactions_synced == 1
      assert result.accounts_cursor == "acct-cursor"
      assert result.transactions_cursor == nil

      refreshed = Repo.get!(Connection, connection.id)
      assert refreshed.accounts_cursor == "acct-cursor"
      assert refreshed.last_synced_at
      assert refreshed.last_sync_error == nil

      account = Repo.get_by!(Account, external_id: "acct-1")
      assert account.name == "Checking"
      assert account.currency == "USD"
      assert Decimal.eq?(account.current_balance, Decimal.new("100.00"))
      assert Decimal.eq?(account.available_balance, Decimal.new("80.00"))

      transaction = Repo.get_by!(Transaction, external_id: "txn-1")
      assert transaction.account_id == account.id
      assert Decimal.eq?(transaction.amount, Decimal.new("-25.50"))
      assert transaction.status == "posted"
      assert transaction.description == "Coffee Shop"
    end

    test "records rate limit errors and returns retry information" do
      user = AccountsFixtures.user_fixture()

      connection = InstitutionsFixtures.connection_fixture(user)

      assert {:error, {:rate_limited, info}} =
               Synchronizer.sync(connection, client: RateLimitClient)

      assert info[:retry_after] == 45

      refreshed = Repo.get!(Connection, connection.id)
      assert Map.get(refreshed.last_sync_error, "type") == "rate_limited"
      assert refreshed.last_sync_error_at
    end

    test "advances cursors for paginated responses" do
      user = AccountsFixtures.user_fixture()
      connection = InstitutionsFixtures.connection_fixture(user)

      assert {:ok, result} = Synchronizer.sync(connection, client: PagedClient)
      assert result.accounts_synced == 2
      assert result.transactions_synced == 1
      assert result.accounts_cursor == "acct-cursor"
      assert result.transactions_cursor == "txn-cursor"

      refreshed = Repo.get!(Connection, connection.id)
      assert refreshed.accounts_cursor == "acct-cursor"
      assert refreshed.transactions_cursor == "txn-cursor"
    end

    test "records invalid transaction errors" do
      user = AccountsFixtures.user_fixture()
      connection = InstitutionsFixtures.connection_fixture(user)

      assert {:error, {:invalid_transaction_amount, info}} =
               Synchronizer.sync(connection, client: InvalidTransactionClient)

      assert info[:account_id]

      refreshed = Repo.get!(Connection, connection.id)

      error_type =
        Map.get(refreshed.last_sync_error, :type) || Map.get(refreshed.last_sync_error, "type")

      assert error_type == :invalid_transaction_amount or
               error_type == "invalid_transaction_amount"

      assert refreshed.last_sync_error_at
    end
  end
end
