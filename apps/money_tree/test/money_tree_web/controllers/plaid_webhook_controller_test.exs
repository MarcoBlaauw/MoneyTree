defmodule MoneyTreeWeb.PlaidWebhookControllerTest do
  use MoneyTreeWeb.ConnCase

  alias MoneyTree.AccountsFixtures
  alias MoneyTree.BankSync.ProviderRegistry
  alias MoneyTree.InstitutionsFixtures
  alias MoneyTree.Repo

  defmodule PlaidWebhookClientStub do
    def list_accounts(_params) do
      {:ok,
       %{
         "data" => [
           %{
             "id" => "plaid-acct-1",
             "name" => "Plaid Checking",
             "type" => "depository",
             "subtype" => "checking",
             "currency" => "USD",
             "balances" => %{"current" => "125.00", "available" => "100.00"}
           }
         ],
         "next_cursor" => nil
       }}
    end

    def list_transactions(params) do
      assert params["access_token"] == "plaid-token-1"
      {:ok, %{"data" => [], "next_cursor" => nil, "has_more" => false}}
    end
  end

  setup do
    original_config = Application.get_env(:money_tree, MoneyTree.Plaid)
    original_client = Application.get_env(:money_tree, :plaid_client)
    original_registry = Application.get_env(:money_tree, ProviderRegistry)
    Application.put_env(:money_tree, MoneyTree.Plaid, webhook_secret: "plaid-secret")
    Application.put_env(:money_tree, :plaid_client, PlaidWebhookClientStub)

    Application.put_env(:money_tree, ProviderRegistry,
      enabled_providers: ["simplefin", "manual", "plaid"],
      primary_provider: "simplefin"
    )

    on_exit(fn ->
      case original_config do
        nil -> Application.delete_env(:money_tree, MoneyTree.Plaid)
        config -> Application.put_env(:money_tree, MoneyTree.Plaid, config)
      end

      case original_client do
        nil -> Application.delete_env(:money_tree, :plaid_client)
        client -> Application.put_env(:money_tree, :plaid_client, client)
      end

      case original_registry do
        nil -> Application.delete_env(:money_tree, ProviderRegistry)
        config -> Application.put_env(:money_tree, ProviderRegistry, config)
      end
    end)

    :ok
  end

  test "verifies signature and enqueues plaid sync", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    connection =
      InstitutionsFixtures.connection_fixture(user, %{
        provider: "plaid",
        metadata: %{"status" => "active", "provider" => "plaid"},
        encrypted_credentials: Jason.encode!(%{"access_token" => "plaid-token-1"})
      })

    payload = %{
      "connection_id" => connection.id,
      "event" => "SYNC_UPDATES_AVAILABLE",
      "nonce" => "nonce-1"
    }

    body = Jason.encode!(payload)
    timestamp = System.system_time(:second)
    sig = sign(timestamp, body)

    response =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("plaid-timestamp", Integer.to_string(timestamp))
      |> put_req_header("plaid-signature", sig)
      |> post(~p"/api/plaid/webhook", body)

    assert json_response(response, 200) == %{"status" => "ok"}
    refreshed = Repo.get!(MoneyTree.Institutions.Connection, connection.id)
    assert get_in(refreshed.metadata, ["plaid_webhook", "last_event"]) == "SYNC_UPDATES_AVAILABLE"
  end

  test "rejects a validly signed but stale (replayed) webhook", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    connection =
      InstitutionsFixtures.connection_fixture(user, %{
        provider: "plaid",
        metadata: %{"status" => "active", "provider" => "plaid"},
        encrypted_credentials: Jason.encode!(%{"access_token" => "plaid-token-1"})
      })

    payload = %{
      "connection_id" => connection.id,
      "event" => "SYNC_UPDATES_AVAILABLE",
      "nonce" => "nonce-stale"
    }

    body = Jason.encode!(payload)
    # Well outside the freshness window, but otherwise a perfectly valid
    # signature over the (stale) timestamp and body -- simulating a captured
    # webhook being replayed after its nonce would have been pruned.
    timestamp = System.system_time(:second) - 3600
    sig = sign(timestamp, body)

    response =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("plaid-timestamp", Integer.to_string(timestamp))
      |> put_req_header("plaid-signature", sig)
      |> post(~p"/api/plaid/webhook", body)

    assert json_response(response, 400) == %{"error" => "invalid webhook"}

    refreshed = Repo.get!(MoneyTree.Institutions.Connection, connection.id)
    refute get_in(refreshed.metadata, ["plaid_webhook", "last_event"])
  end

  test "acknowledges disabled Plaid webhooks without requiring signature", %{conn: conn} do
    Application.put_env(:money_tree, ProviderRegistry,
      enabled_providers: ["simplefin", "manual"],
      primary_provider: "simplefin"
    )

    response =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/plaid/webhook", Jason.encode!(%{}))

    assert json_response(response, 200) == %{
             "status" => "ignored",
             "reason" => "provider_disabled"
           }
  end

  defp sign(timestamp, body) do
    :crypto.mac(:hmac, :sha256, "plaid-secret", "#{timestamp}.#{body}")
    |> Base.encode16(case: :lower)
  end
end
