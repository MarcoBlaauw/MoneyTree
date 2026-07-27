defmodule MoneyTree.SimpleFinTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures
  import MoneyTree.InstitutionsFixtures

  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Repo
  alias MoneyTree.SimpleFin

  describe "selected_account_ids/1" do
    test "returns nil when no import review has ever been confirmed" do
      user = user_fixture()
      connection = connection_fixture(user)

      assert SimpleFin.selected_account_ids(connection) == nil
    end

    test "returns the confirmed account ids as a MapSet" do
      user = user_fixture()

      connection =
        connection_fixture(user, %{
          provider_metadata: %{
            "simplefin" => %{"import_review" => %{"account_ids" => ["acct-1", "acct-2"]}}
          }
        })

      assert SimpleFin.selected_account_ids(connection) == MapSet.new(["acct-1", "acct-2"])
    end
  end

  describe "note_new_accounts/2" do
    test "records newly discovered accounts without touching the confirmed selection" do
      user = user_fixture()

      connection =
        connection_fixture(user, %{
          provider_metadata: %{
            "simplefin" => %{
              "import_review" => %{"status" => "confirmed", "account_ids" => ["acct-1"]}
            }
          }
        })

      assert {:ok, updated} =
               SimpleFin.note_new_accounts(connection, [
                 %{"id" => "acct-2", "name" => "New Savings", "balance" => "50.00"}
               ])

      review = SimpleFin.import_review(updated)
      assert review["account_ids"] == ["acct-1"]

      assert review["pending_new_accounts"] == [
               %{"id" => "acct-2", "name" => "New Savings", "balance" => "50.00"}
             ]
    end

    test "accumulates and refreshes pending accounts across repeated syncs" do
      user = user_fixture()
      connection = connection_fixture(user)

      assert {:ok, connection} =
               SimpleFin.note_new_accounts(connection, [
                 %{"id" => "acct-1", "name" => "New Checking", "balance" => "10.00"}
               ])

      assert {:ok, connection} =
               SimpleFin.note_new_accounts(connection, [
                 %{"id" => "acct-1", "name" => "New Checking", "balance" => "20.00"},
                 %{"id" => "acct-2", "name" => "New Savings", "balance" => "5.00"}
               ])

      pending = SimpleFin.import_review(connection)["pending_new_accounts"]
      assert length(pending) == 2
      assert Enum.find(pending, &(&1["id"] == "acct-1"))["balance"] == "20.00"
      assert Enum.find(pending, &(&1["id"] == "acct-2"))
    end

    test "is a no-op when there are no new accounts to note" do
      user = user_fixture()
      connection = connection_fixture(user)

      assert {:ok, ^connection} = SimpleFin.note_new_accounts(connection, [])
    end
  end

  describe "confirm_import/2" do
    test "merges newly confirmed ids with the previously confirmed selection" do
      user = user_fixture()

      connection =
        connection_fixture(user, %{
          provider_metadata: %{
            "simplefin" => %{
              "import_review" => %{
                "status" => "confirmed",
                "account_ids" => ["acct-1"],
                "pending_new_accounts" => [%{"id" => "acct-2", "name" => "New Savings"}]
              }
            }
          }
        })

      assert {:ok, updated} = SimpleFin.confirm_import(connection, ["acct-2"])

      review = SimpleFin.import_review(updated)
      assert Enum.sort(review["account_ids"]) == ["acct-1", "acct-2"]
      assert review["pending_new_accounts"] == []
      assert review["status"] == "confirmed"

      persisted = Repo.get!(Connection, connection.id)
      assert Enum.sort(SimpleFin.import_review(persisted)["account_ids"]) == ["acct-1", "acct-2"]
    end

    test "confirming the initial account list works with no prior review" do
      user = user_fixture()
      connection = connection_fixture(user)

      assert {:ok, updated} = SimpleFin.confirm_import(connection, ["acct-1", "acct-2"])

      review = SimpleFin.import_review(updated)
      assert Enum.sort(review["account_ids"]) == ["acct-1", "acct-2"]
      assert review["status"] == "confirmed"
    end
  end
end
