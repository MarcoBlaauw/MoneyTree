defmodule MoneyTreeWeb.TellerClientStub do
  @moduledoc false

  def create_connect_token(params), do: dispatch(:connect_token, params)

  def exchange_public_token(token), do: dispatch(:exchange_public_token, token)

  defp dispatch(key, arg) do
    case Process.get({__MODULE__, key}) do
      nil -> raise "stub not configured for #{inspect(key)}"
      fun when is_function(fun, 1) -> fun.(arg)
      value -> value
    end
  end
end

defmodule MoneyTreeWeb.SyncStub do
  @moduledoc false

  def schedule_initial_sync(connection) do
    send(self(), {:sync_scheduled, connection.id})
    :ok
  end
end

defmodule MoneyTreeWeb.RateLimiter.AlwaysDeny do
  @moduledoc false
  @behaviour MoneyTreeWeb.RateLimiter

  @impl true
  def check(_bucket, _limit, _period), do: {:error, :rate_limited}
end

defmodule MoneyTreeWeb.TellerControllerTest do
  use MoneyTreeWeb.ConnCase

  import MoneyTree.AccountsFixtures

  alias MoneyTree.Institutions
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Institutions.Institution
  alias MoneyTree.Repo
  alias MoneyTreeWeb.Auth

  @session_cookie Auth.session_cookie_name()

  setup %{conn: conn} do
    user = user_fixture()
    %{token: token} = session_fixture(user)

    conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

    original_client = Application.get_env(:money_tree, :teller_client)
    original_sync = Application.get_env(:money_tree, :synchronization)
    original_rate_limiter = Application.get_env(:money_tree, :rate_limiter)

    Application.put_env(:money_tree, :teller_client, MoneyTreeWeb.TellerClientStub)
    Application.put_env(:money_tree, :synchronization, MoneyTreeWeb.SyncStub)
    Application.put_env(:money_tree, :rate_limiter, MoneyTreeWeb.RateLimiter.Noop)

    on_exit(fn ->
      Process.delete({MoneyTreeWeb.TellerClientStub, :connect_token})
      Process.delete({MoneyTreeWeb.TellerClientStub, :exchange_public_token})

      restore_env(:teller_client, original_client)
      restore_env(:synchronization, original_sync)
      restore_env(:rate_limiter, original_rate_limiter)
    end)

    {:ok, conn: conn, user: user}
  end

  describe "POST /api/teller/connect_token" do
    test "returns connect token payload", %{conn: conn} do
      Process.put({MoneyTreeWeb.TellerClientStub, :connect_token}, fn params ->
        assert params == %{"institution" => "demo"}
        {:ok, %{"token" => "connect-token"}}
      end)

      response =
        conn
        |> post(~p"/api/teller/connect_token", %{"institution" => "demo"})
        |> json_response(200)

      assert response == %{"data" => %{"token" => "connect-token"}}
    end

    test "applies rate limiting hook", %{conn: conn} do
      Application.put_env(:money_tree, :rate_limiter, MoneyTreeWeb.RateLimiter.AlwaysDeny)

      Process.put({MoneyTreeWeb.TellerClientStub, :connect_token}, fn _ ->
        {:ok, %{"token" => "ignored"}}
      end)

      response =
        conn
        |> post(~p"/api/teller/connect_token", %{})
        |> json_response(429)

      assert response == %{"error" => "rate limit exceeded"}
    end

    test "normalizes teller errors", %{conn: conn} do
      Process.put({MoneyTreeWeb.TellerClientStub, :connect_token}, fn _ ->
        {:error, %{type: :http, status: 400, details: %{"message" => "invalid institution"}}}
      end)

      response =
        conn
        |> post(~p"/api/teller/connect_token", %{})
        |> json_response(400)

      assert response == %{"error" => "invalid institution"}
    end
  end

  describe "POST /api/teller/exchange" do
    setup _context do
      slug = "demo-bank-#{System.unique_integer([:positive])}"

      institution =
        %Institution{}
        |> Institution.changeset(%{
          name: "Demo Bank",
          slug: slug,
          external_id: slug,
          encrypted_credentials: "sandbox",
          metadata: %{}
        })
        |> Repo.insert!()

      {:ok, institution: institution}
    end

    test "creates connection and schedules sync", %{conn: conn, institution: institution} do
      Process.put({MoneyTreeWeb.TellerClientStub, :exchange_public_token}, fn token ->
        assert token == "public-token"

        {:ok,
         %{
           "access_token" => "access-123",
           "user_id" => "user-abc",
           "enrollment_id" => "enroll-xyz"
         }}
      end)

      response =
        conn
        |> post(~p"/api/teller/exchange", %{
          "public_token" => "public-token",
          "institution_id" => institution.id,
          "institution_name" => "Demo Bank Inc"
        })
        |> json_response(200)

      %{"data" => data} = response
      connection_id = data["connection_id"]
      assert data["institution_name"] == "Demo Bank Inc"
      assert data["institution_id"] == institution.id
      assert data["metadata"]["institution_name"] == "Demo Bank Inc"

      assert_receive {:sync_scheduled, ^connection_id}

      connection = Repo.get!(Connection, connection_id)
      assert connection.teller_user_id == "user-abc"
      assert connection.teller_enrollment_id == "enroll-xyz"
      assert connection.encrypted_credentials

      assert connection.metadata["status"] == "active"
      assert connection.metadata["provider"] == "teller"
      assert connection.metadata["institution_name"] == "Demo Bank Inc"
    end

    test "updates existing connection metadata", %{
      conn: conn,
      user: user,
      institution: institution
    } do
      {:ok, existing} =
        Institutions.create_connection(user, institution.id, %{
          metadata: %{"status" => "revoked", "revoked_at" => "yesterday", "provider" => "teller"},
          teller_user_id: "old-user"
        })

      Process.put({MoneyTreeWeb.TellerClientStub, :exchange_public_token}, fn _ ->
        {:ok, %{"user_id" => "new-user", "enrollment_id" => "new-enroll"}}
      end)

      response =
        conn
        |> post(~p"/api/teller/exchange", %{
          "public_token" => "fresh-token",
          "institution_id" => institution.id,
          "institution_name" => "Demo Bank"
        })
        |> json_response(200)

      %{"data" => %{"connection_id" => connection_id, "metadata" => metadata}} = response
      assert connection_id == existing.id

      connection = Repo.get!(Connection, connection_id)
      refute Map.has_key?(connection.metadata, "revoked_at")
      refute Map.has_key?(connection.metadata, "revocation_reason")
      assert connection.metadata["status"] == "active"
      assert connection.metadata["provider"] == "teller"
      assert metadata["institution_name"] == "Demo Bank"
      assert connection.teller_user_id == "new-user"
      assert connection.teller_enrollment_id == "new-enroll"
    end

    test "requires public token", %{conn: conn} do
      response =
        conn
        |> post(~p"/api/teller/exchange", %{"institution_id" => "inst"})
        |> json_response(400)

      assert response == %{"error" => "public_token is required"}
    end

    test "requires institution id", %{conn: conn} do
      Process.put({MoneyTreeWeb.TellerClientStub, :exchange_public_token}, fn _ ->
        {:ok, %{"user_id" => "user"}}
      end)

      response =
        conn
        |> post(~p"/api/teller/exchange", %{"public_token" => "token"})
        |> json_response(400)

      assert response == %{"error" => "institution_id is required"}
    end

    test "maps teller upstream errors", %{conn: conn, institution: institution} do
      Process.put({MoneyTreeWeb.TellerClientStub, :exchange_public_token}, fn _ ->
        {:error, %{type: :http, status: 503, details: %{"message" => "teller maintenance"}}}
      end)

      response =
        conn
        |> post(~p"/api/teller/exchange", %{
          "public_token" => "token",
          "institution_id" => institution.id
        })
        |> json_response(502)

      assert response == %{"error" => "teller maintenance"}
    end
  end

  describe "POST /api/teller/revoke" do
    setup %{user: user} do
      slug = "revoke-bank-#{System.unique_integer([:positive])}"

      institution =
        %Institution{}
        |> Institution.changeset(%{
          name: "Revoke Bank",
          slug: slug,
          external_id: slug,
          encrypted_credentials: "sandbox"
        })
        |> Repo.insert!()

      {:ok, connection} = Institutions.create_connection(user, institution.id, %{})

      {:ok, connection: connection}
    end

    test "marks connection as revoked", %{conn: conn, connection: connection} do
      response =
        conn
        |> post(~p"/api/teller/revoke", %{"connection_id" => connection.id})
        |> json_response(200)

      %{"data" => %{"metadata" => metadata, "connection_id" => returned_id}} = response
      assert returned_id == connection.id
      assert metadata["status"] == "revoked"
      assert metadata["revocation_reason"] == "user_initiated"
    end

    test "requires identifier", %{conn: conn} do
      response =
        conn
        |> post(~p"/api/teller/revoke", %{})
        |> json_response(400)

      assert response == %{"error" => "connection_id is required"}
    end

    test "returns not found for unknown connection", %{conn: conn} do
      response =
        conn
        |> post(~p"/api/teller/revoke", %{"connection_id" => Ecto.UUID.generate()})
        |> json_response(404)

      assert response == %{"error" => "connection not found"}
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:money_tree, key)
  defp restore_env(key, value), do: Application.put_env(:money_tree, key, value)
end
