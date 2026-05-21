defmodule MoneyTreeWeb.SimpleFinClientStub do
  @moduledoc false

  def claim_setup_token(token), do: dispatch(:claim_setup_token, token)
  def get_balances(access_url), do: dispatch(:get_balances, access_url)

  defp dispatch(key, arg) do
    case Process.get({__MODULE__, key}) do
      nil -> raise "stub not configured for #{inspect(key)}"
      fun when is_function(fun, 1) -> fun.(arg)
      value -> value
    end
  end
end

defmodule MoneyTreeWeb.SimpleFinSyncStub do
  @moduledoc false

  def schedule_initial_sync(connection) do
    send(self(), {:simplefin_sync_scheduled, connection.id})
    :ok
  end

  def schedule_incremental_sync(connection) do
    send(self(), {:simplefin_incremental_sync_scheduled, connection.id})
    :ok
  end
end

defmodule MoneyTreeWeb.SimpleFinControllerTest do
  use MoneyTreeWeb.ConnCase

  import MoneyTree.AccountsFixtures
  import MoneyTree.InstitutionsFixtures

  alias MoneyTree.BankSync.ProviderRegistry
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Repo
  alias MoneyTreeWeb.Auth

  @session_cookie Auth.session_cookie_name()

  setup %{conn: conn} do
    user = user_fixture()
    %{token: token} = session_fixture(user)
    conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

    original_client = Application.get_env(:money_tree, :simplefin_client)
    original_sync = Application.get_env(:money_tree, :synchronization)
    original_registry = Application.get_env(:money_tree, ProviderRegistry)

    Application.put_env(:money_tree, :simplefin_client, MoneyTreeWeb.SimpleFinClientStub)
    Application.put_env(:money_tree, :synchronization, MoneyTreeWeb.SimpleFinSyncStub)

    Application.put_env(:money_tree, ProviderRegistry,
      enabled_providers: ["simplefin", "manual"],
      primary_provider: "simplefin"
    )

    on_exit(fn ->
      Process.delete({MoneyTreeWeb.SimpleFinClientStub, :claim_setup_token})
      Process.delete({MoneyTreeWeb.SimpleFinClientStub, :get_balances})
      restore_env(:simplefin_client, original_client)
      restore_env(:synchronization, original_sync)
      restore_registry(original_registry)
    end)

    {:ok, conn: conn, user: user}
  end

  test "config returns enabled SimpleFIN metadata", %{conn: conn} do
    response =
      conn
      |> get(~p"/api/simplefin/config")
      |> json_response(200)

    assert response["data"]["enabled"] == true
    assert response["data"]["primary_provider"] == "simplefin"
  end

  test "claim stores access URL in encrypted credentials and returns safe account metadata", %{
    conn: conn
  } do
    Process.put({MoneyTreeWeb.SimpleFinClientStub, :claim_setup_token}, fn token ->
      assert token == "setup-token"
      {:ok, "https://user:pass@bridge.simplefin.org/simplefin"}
    end)

    Process.put({MoneyTreeWeb.SimpleFinClientStub, :get_balances}, fn access_url ->
      assert access_url == "https://user:pass@bridge.simplefin.org/simplefin"

      {:ok,
       %{
         "accounts" => [
           %{
             "id" => "acct-1",
             "name" => "Checking",
             "currency" => "USD",
             "balance" => "42.00"
           }
         ],
         "connections" => [
           %{"conn_id" => "conn-1", "org_name" => "Demo Bank", "sfin_url" => access_url}
         ],
         "errors" => [
           %{"code" => "con.auth", "conn_id" => "conn-1", "msg" => "Auth required"}
         ]
       }}
    end)

    response =
      conn
      |> post(~p"/api/simplefin/claim", %{"setup_token" => "setup-token"})
      |> json_response(200)

    refute inspect(response) =~ "user:pass"
    assert response["data"]["status"] == "connected_with_provider_errors"
    assert response["data"]["institution_name"] == "SimpleFIN Bridge"
    assert [%{"code" => "con.auth", "msg" => "Auth required"}] = response["data"]["errors"]
    assert [%{"name" => "Checking"}] = response["data"]["accounts"]

    connection = Repo.get!(Connection, response["data"]["connection_id"])
    assert Repo.preload(connection, :institution).institution.name == "SimpleFIN Bridge"
    assert connection.provider == "simplefin"

    assert Jason.decode!(connection.encrypted_credentials)["access_url"] ==
             "https://user:pass@bridge.simplefin.org/simplefin"

    assert get_in(connection.provider_metadata, ["simplefin", "errors"]) == [
             %{"code" => "con.auth", "conn_id" => "conn-1", "msg" => "Auth required"}
           ]

    assert_receive {:simplefin_sync_scheduled, _connection_id}
  end

  test "connections lists active SimpleFIN connections", %{conn: conn, user: user} do
    institution = institution_fixture(%{name: "SimpleFIN Bridge"})

    connection =
      connection_fixture(user, %{
        institution: institution,
        provider: "simplefin",
        last_synced_at: ~U[2026-05-20 14:12:00Z]
      })

    account_fixture(user, %{
      name: "Checking",
      institution_id: institution.id,
      institution_connection_id: connection.id
    })

    response =
      conn
      |> get(~p"/api/simplefin/connections")
      |> json_response(200)

    assert [
             %{
               "id" => id,
               "institution_name" => "SimpleFIN Bridge",
               "provider" => "simplefin",
               "account_count" => 1,
               "status" => "connected",
               "last_synced_at" => "2026-05-20T14:12:00.000000Z"
             }
           ] = response["data"]["connections"]

    assert id == connection.id
  end

  test "revoke marks an active SimpleFIN connection revoked", %{conn: conn, user: user} do
    institution = institution_fixture(%{name: "SimpleFIN Bridge"})

    connection =
      connection_fixture(user, %{
        institution: institution,
        provider: "simplefin"
      })

    response =
      conn
      |> delete(~p"/api/simplefin/connections/#{connection.id}")
      |> json_response(200)

    assert response["data"]["status"] == "revoked"
    assert Repo.get!(Connection, connection.id).metadata["status"] == "revoked"
    assert Repo.get!(Connection, connection.id).metadata["revoked_at"]
  end

  test "returns stable disabled response", %{conn: conn} do
    Application.put_env(:money_tree, ProviderRegistry,
      enabled_providers: ["manual"],
      primary_provider: "manual"
    )

    response =
      conn
      |> post(~p"/api/simplefin/claim", %{"setup_token" => "setup-token"})
      |> json_response(503)

    assert response["error"] == "SimpleFIN is disabled for new connections"
  end

  defp restore_env(key, nil), do: Application.delete_env(:money_tree, key)
  defp restore_env(key, value), do: Application.put_env(:money_tree, key, value)

  defp restore_registry(nil), do: Application.delete_env(:money_tree, ProviderRegistry)
  defp restore_registry(value), do: Application.put_env(:money_tree, ProviderRegistry, value)
end
