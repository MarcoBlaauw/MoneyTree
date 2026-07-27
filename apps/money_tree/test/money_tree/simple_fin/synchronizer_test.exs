defmodule MoneyTree.SimpleFin.SynchronizerTest do
  use MoneyTree.DataCase, async: true

  alias Decimal
  alias MoneyTree.Accounts.Account
  alias MoneyTree.AccountsFixtures
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Institutions.Institution
  alias MoneyTree.InstitutionsFixtures
  alias MoneyTree.Repo
  alias MoneyTree.SimpleFin
  alias MoneyTree.SimpleFin.Synchronizer
  alias MoneyTree.Transactions.Transaction

  defmodule SuccessClient do
    def get_accounts(_access_url, opts) do
      send(self(), {:simplefin_opts, opts})

      {:ok,
       %{
         "accounts" => [
           %{
             "id" => "account-" <> String.duplicate("x", 150),
             "conn_id" => "conn-1",
             "name" => "SimpleFIN Checking",
             "currency" => "usd",
             "balance" => "125.50",
             "available-balance" => "120.00",
             "transactions" => [
               %{
                 "id" => "transaction-" <> String.duplicate("y", 120),
                 "posted" => 1_777_593_600,
                 "amount" => "-12.34",
                 "description" => "Coffee",
                 "extra" => %{"category" => "Food"}
               }
             ]
           }
         ],
         "connections" => [
           %{
             "conn_id" => "conn-1",
             "org_id" => "demo-bank",
             "org_name" => "Demo Bank",
             "org_url" => "https://demo.example"
           }
         ],
         "errors" => []
       }}
    end
  end

  defmodule MovedAccountClient do
    def get_accounts(_access_url, _opts) do
      {:ok,
       %{
         "accounts" => [
           %{
             "id" => "account-moved",
             "conn_id" => "conn-1",
             "name" => "SimpleFIN Checking",
             "currency" => "usd",
             "balance" => "200.00",
             "available-balance" => "200.00",
             "transactions" => []
           }
         ],
         "connections" => [
           %{"conn_id" => "conn-1", "org_id" => "demo-bank", "org_name" => "Demo Bank"}
         ],
         "errors" => []
       }}
    end
  end

  defmodule ProviderErrorClient do
    def get_accounts(_access_url, _opts) do
      {:ok,
       %{
         "accounts" => [],
         "connections" => [%{"conn_id" => "conn-1"}],
         "errors" => [%{"code" => "con.auth", "msg" => "Auth required"}]
       }}
    end
  end

  describe "sync/2" do
    test "imports SimpleFIN accounts and transactions idempotently with long provider ids" do
      user = AccountsFixtures.user_fixture()
      connection = simplefin_connection(user)

      assert {:ok, result} = Synchronizer.sync(connection, client: SuccessClient, mode: "initial")
      assert result.accounts_synced == 1
      assert result.transactions_synced == 1

      assert_receive {:simplefin_opts, opts}
      assert opts[:version] == "2"
      assert Date.diff(Date.utc_today(), opts[:start_date]) <= 90

      account = Repo.one!(Account)
      account = Repo.preload(account, :institution)
      assert account.name == "SimpleFIN Checking"
      assert account.institution.name == "Demo Bank"
      assert account.internal_account_kind == "checking"
      assert account.liability_type == nil
      assert Decimal.equal?(account.current_balance, Decimal.new("125.50"))
      assert String.starts_with?(account.external_id, "simplefin:#{connection.id}:account-")
      assert Repo.get_by!(Institution, external_id: "simplefin:demo-bank").name == "Demo Bank"

      transaction = Repo.one!(Transaction)
      assert transaction.source == "simplefin"
      assert transaction.description == "Coffee"
      assert Decimal.equal?(transaction.amount, Decimal.new("-12.34"))
      assert String.starts_with?(transaction.external_id, "simplefin:#{connection.id}:account-")

      assert {:ok, rerun} =
               Synchronizer.sync(Repo.get!(Connection, connection.id), client: SuccessClient)

      assert rerun.accounts_synced == 1
      assert rerun.transactions_synced == 1
      assert Repo.aggregate(Account, :count) == 1
      assert Repo.aggregate(Transaction, :count) == 1
    end

    test "relinks a changed SimpleFIN account id when the institution and account name are stable" do
      user = AccountsFixtures.user_fixture()
      connection = simplefin_connection(user)

      assert {:ok, _result} =
               Synchronizer.sync(connection, client: SuccessClient, mode: "initial")

      [account] = Repo.all(Account)
      original_account_id = account.id

      assert {:ok, _result} =
               Synchronizer.sync(Repo.get!(Connection, connection.id), client: MovedAccountClient)

      assert Repo.aggregate(Account, :count) == 1

      updated = Repo.one!(Account)
      assert updated.id == original_account_id
      assert updated.external_id == "simplefin:#{connection.id}:account-moved"
      assert Decimal.equal?(updated.current_balance, Decimal.new("200.00"))
    end

    test "preserves user-renamed accounts during later syncs" do
      user = AccountsFixtures.user_fixture()
      connection = simplefin_connection(user)

      assert {:ok, _result} =
               Synchronizer.sync(connection, client: SuccessClient, mode: "initial")

      account = Repo.one!(Account)

      account
      |> Account.changeset(%{name: "Household Checking"})
      |> Repo.update!()

      assert {:ok, _result} =
               Synchronizer.sync(Repo.get!(Connection, connection.id), client: SuccessClient)

      updated = Repo.one!(Account)
      assert updated.name == "Household Checking"
      assert Decimal.equal?(updated.current_balance, Decimal.new("125.50"))
    end

    test "imports only SimpleFIN accounts selected during review" do
      user = AccountsFixtures.user_fixture()

      connection =
        simplefin_connection(user, %{
          provider_metadata: %{
            "simplefin" => %{
              "import_review" => %{
                "status" => "confirmed",
                "account_ids" => ["account-" <> String.duplicate("x", 150)]
              }
            }
          }
        })

      assert {:ok, result} = Synchronizer.sync(connection, client: MovedAccountClient)

      assert result.accounts_synced == 0
      assert Repo.aggregate(Account, :count) == 0

      refreshed = Repo.get!(Connection, connection.id)

      assert [%{"id" => "account-moved"}] =
               SimpleFin.import_review(refreshed)["pending_new_accounts"]
    end

    test "imports a newly discovered account once confirmed, without dropping the original selection" do
      user = AccountsFixtures.user_fixture()
      original_account_id = "account-" <> String.duplicate("x", 150)

      connection =
        simplefin_connection(user, %{
          provider_metadata: %{
            "simplefin" => %{
              "import_review" => %{
                "status" => "confirmed",
                "account_ids" => [original_account_id]
              }
            }
          }
        })

      assert {:ok, %{accounts_synced: 0}} =
               Synchronizer.sync(connection, client: MovedAccountClient)

      connection = Repo.get!(Connection, connection.id)
      assert {:ok, connection} = SimpleFin.confirm_import(connection, ["account-moved"])

      review = SimpleFin.import_review(connection)
      assert Enum.sort(review["account_ids"]) == Enum.sort([original_account_id, "account-moved"])
      assert review["pending_new_accounts"] == []

      assert {:ok, %{accounts_synced: 1}} =
               Synchronizer.sync(connection, client: MovedAccountClient)

      account = Repo.one!(Account)
      assert account.external_id == "simplefin:#{connection.id}:account-moved"

      final_review = SimpleFin.import_review(Repo.get!(Connection, connection.id))
      assert original_account_id in final_review["account_ids"]
    end

    test "persists provider errors without treating them as fatal" do
      user = AccountsFixtures.user_fixture()
      connection = simplefin_connection(user)

      assert {:ok, result} = Synchronizer.sync(connection, client: ProviderErrorClient)
      assert result.accounts_synced == 0
      assert result.transactions_synced == 0

      refreshed = Repo.get!(Connection, connection.id)

      assert get_in(refreshed.provider_metadata, ["simplefin", "errors"]) == [
               %{"code" => "con.auth", "msg" => "Auth required"}
             ]
    end

    test "enforces local daily request quota" do
      user = AccountsFixtures.user_fixture()

      connection =
        simplefin_connection(user, %{
          provider_metadata: %{
            "simplefin" => %{
              "request_usage" => %{
                "utc_date" => Date.utc_today() |> Date.to_iso8601(),
                "accounts_requests" => 24
              }
            }
          }
        })

      assert {:error, :quota_exceeded} = Synchronizer.sync(connection, client: SuccessClient)
    end
  end

  defp simplefin_connection(user, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          provider: "simplefin",
          encrypted_credentials:
            Jason.encode!(%{"access_url" => "https://user:pass@bridge.simplefin.org/simplefin"}),
          metadata: %{"status" => "active", "provider" => "simplefin"},
          provider_metadata: %{}
        },
        attrs
      )

    InstitutionsFixtures.connection_fixture(user, attrs)
  end
end
