defmodule MoneyTreeWeb.PlaidClientStub do
  @moduledoc false

  def exchange_public_token(token), do: dispatch(:exchange_public_token, token)

  defp dispatch(key, arg) do
    case Process.get({__MODULE__, key}) do
      nil -> raise "stub not configured for #{inspect(key)}"
      fun when is_function(fun, 1) -> fun.(arg)
      value -> value
    end
  end
end


defmodule MoneyTreeWeb.PlaidSyncStub do
  @moduledoc false

  def schedule_initial_sync(connection) do
    send(self(), {:sync_scheduled, connection.id})
    :ok
  end
end

defmodule MoneyTreeWeb.PlaidControllerTest do
  use MoneyTreeWeb.ConnCase

  import MoneyTree.AccountsFixtures

  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Institutions.Institution
  alias MoneyTree.Repo
  alias MoneyTreeWeb.Auth

  @session_cookie Auth.session_cookie_name()

  setup %{conn: conn} do
    user = user_fixture()
    %{token: token} = session_fixture(user)

    conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

    original_client = Application.get_env(:money_tree, :plaid_client)
    original_sync = Application.get_env(:money_tree, :synchronization)

    Application.put_env(:money_tree, :plaid_client, MoneyTreeWeb.PlaidClientStub)
    Application.put_env(:money_tree, :synchronization, MoneyTreeWeb.PlaidSyncStub)

    on_exit(fn ->
      Process.delete({MoneyTreeWeb.PlaidClientStub, :exchange_public_token})
      restore_env(:plaid_client, original_client)
      restore_env(:synchronization, original_sync)
    end)

    {:ok, conn: conn}
  end

  describe "authentication" do
    test "requires session", %{conn: conn} do
      conn = Plug.Conn.delete_req_header(conn, "cookie")

      response = post(conn, ~p"/api/plaid/link_token", %{})

      assert response.status == 401
    end
  end

  describe "POST /api/plaid/link_token" do
    test "returns a link token payload", %{conn: conn} do
      response = post(conn, ~p"/api/plaid/link_token", %{products: ["auth"]})

      assert %{"data" => data} = json_response(response, 200)
      assert is_binary(data["link_token"])
      assert is_binary(data["expiration"])
      assert data["metadata"] == %{"products" => ["auth"]}
    end
  end

  describe "POST /api/plaid/exchange" do
    setup do
      institution =
        %Institution{}
        |> Institution.changeset(%{
          name: "Plaid Bank",
          slug: "plaid-bank-#{System.unique_integer([:positive])}",
          external_id: "plaid-ext-#{System.unique_integer([:positive])}",
          encrypted_credentials: "sandbox",
          metadata: %{}
        })
        |> Repo.insert!()

      {:ok, institution: institution}
    end

    test "persists plaid provider connection", %{conn: conn, institution: institution} do
      Process.put({MoneyTreeWeb.PlaidClientStub, :exchange_public_token}, fn token ->
        assert token == "public-plaid"
        {:ok, %{"access_token" => "plaid-access", "item_id" => "item-1"}}
      end)

      response =
        conn
        |> post(~p"/api/plaid/exchange", %{
          "public_token" => "public-plaid",
          "institution_id" => institution.id,
          "institution_name" => "Plaid Bank"
        })
        |> json_response(200)

      %{"data" => %{"connection_id" => connection_id}} = response

      assert_receive {:sync_scheduled, ^connection_id}

      connection = Repo.get!(Connection, connection_id)
      assert connection.provider == "plaid"
      assert connection.provider_metadata["item_id"] == "item-1"
      assert connection.metadata["provider"] == "plaid"
    end
  end
end
