defmodule MoneyTree.Plaid.SynchronizerTest do
  use MoneyTree.DataCase, async: true

  alias Decimal
  alias MoneyTree.Accounts.Account
  alias MoneyTree.AccountsFixtures
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.InstitutionsFixtures
  alias MoneyTree.Plaid.Synchronizer
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction

  defmodule SuccessClient do
    def list_accounts(_params) do
      {:ok,
       %{
         "data" => [
           %{
             "account_id" => "plaid-acct-1",
             "name" => "Plaid Checking",
             "type" => "depository",
             "subtype" => "checking",
             "balances" => %{"current" => "150.00", "available" => "140.00"},
             "iso_currency_code" => "USD"
           }
         ],
         "next_cursor" => nil
       }}
    end

    def list_transactions(params) do
      case params["cursor"] do
        nil ->
          {:ok,
           %{
             "data" => [
               %{
                 "transaction_id" => "plaid-txn-1",
                 "account_id" => "plaid-acct-1",
                 "amount" => "-12.50",
                 "iso_currency_code" => "USD",
                 "datetime" => "2024-04-01T00:00:00Z",
                 "name" => "Coffee"
               }
             ],
             "next_cursor" => "cursor-1",
             "has_more" => false
           }}

        _ ->
          {:ok, %{"data" => [], "next_cursor" => "cursor-1", "has_more" => false}}
      end
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

  test "sync/2 persists accounts and transactions with cursor updates" do
    user = AccountsFixtures.user_fixture()

    connection =
      InstitutionsFixtures.connection_fixture(user, %{
        provider: "plaid",
        encrypted_credentials: Jason.encode!(%{"access_token" => "plaid-token-1"}),
        metadata: %{"status" => "active", "provider" => "plaid"}
      })

    assert {:ok, result} = Synchronizer.sync(connection, client: SuccessClient, mode: "initial")
    assert result.accounts_synced == 1
    assert result.transactions_synced == 1
    assert result.transactions_cursor == "cursor-1"

    refreshed = Repo.get!(Connection, connection.id)
    assert refreshed.transactions_cursor == "cursor-1"
    assert refreshed.last_synced_at
    assert refreshed.last_sync_error == nil

    account = Repo.get_by!(Account, external_id: "plaid-acct-1")
    assert Decimal.eq?(account.current_balance, Decimal.new("150.00"))
    assert Decimal.eq?(account.available_balance, Decimal.new("140.00"))

    transaction = Repo.get_by!(Transaction, external_id: "plaid-txn-1")
    assert Decimal.eq?(transaction.amount, Decimal.new("-12.50"))
    assert transaction.account_id == account.id
  end

  test "sync/2 reports missing credentials" do
    user = AccountsFixtures.user_fixture()

    connection =
      InstitutionsFixtures.connection_fixture(user, %{
        provider: "plaid",
        encrypted_credentials: Jason.encode!(%{})
      })

    assert {:error, {:missing_access_token, %{connection_id: connection_id}}} =
             Synchronizer.sync(connection, client: SuccessClient)

    assert connection_id == connection.id
  end

  test "sync/2 converts 429 into retryable rate limit errors" do
    user = AccountsFixtures.user_fixture()

    connection =
      InstitutionsFixtures.connection_fixture(user, %{
        provider: "plaid",
        encrypted_credentials: Jason.encode!(%{"access_token" => "plaid-token-1"})
      })

    assert {:error, {:rate_limited, info}} =
             Synchronizer.sync(connection, client: RateLimitClient)

    assert info[:retry_after] == 30
  end
end
