defmodule MoneyTreeWeb.TellerWebhookControllerTest do
  use MoneyTreeWeb.ConnCase, async: true

  import Ecto.Query

  alias MoneyTree.AccountsFixtures
  alias MoneyTree.Institutions
  alias MoneyTree.InstitutionsFixtures
  alias MoneyTree.Repo
  alias Oban.Job

  setup do
    original_config = Application.get_env(:money_tree, MoneyTree.Teller)
    base_config = original_config || []
    secret = "test-webhook-secret"
    new_config = Keyword.put(base_config, :webhook_secret, secret)
    Application.put_env(:money_tree, MoneyTree.Teller, new_config)

    on_exit(fn ->
      case original_config do
        nil -> Application.delete_env(:money_tree, MoneyTree.Teller)
        config -> Application.put_env(:money_tree, MoneyTree.Teller, config)
      end
    end)

    {:ok, secret: secret}
  end

  describe "POST /api/teller/webhook" do
    test "verifies signature, records metadata, and enqueues sync", %{conn: conn, secret: secret} do
      user = AccountsFixtures.user_fixture()
      connection = InstitutionsFixtures.connection_fixture(user)

      payload = %{
        "connection_id" => connection.id,
        "event" => "accounts.updated",
        "nonce" => "nonce-#{System.unique_integer([:positive])}"
      }

      {body, header} = signed_payload(payload, secret)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("teller-signature", header)

      response = post(conn, ~p"/api/teller/webhook", body)

      assert json_response(response, 200) == %{"status" => "ok"}

      job = Repo.one!(from j in Job, order_by: [desc: j.inserted_at], limit: 1)

      assert job.worker == "MoneyTree.Teller.SyncWorker"
      assert job.args["connection_id"] == connection.id
      assert job.args["telemetry_metadata"]["event"] == "accounts.updated"
      assert job.args["telemetry_metadata"]["source"] == "teller_webhook"

      refreshed = Repo.get!(MoneyTree.Institutions.Connection, connection.id)
      webhook_meta = refreshed.metadata["teller_webhook"]

      assert webhook_meta["last_event"] == "accounts.updated"
      assert webhook_meta["nonces"][payload["nonce"]]
    end

    test "returns 400 when signature is invalid", %{conn: conn} do
      payload = %{"connection_id" => "conn", "event" => "foo", "nonce" => "abc"}
      body = Jason.encode!(payload)
      timestamp = System.system_time(:second)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("teller-signature", "t=#{timestamp},v1=invalid")

      response = post(conn, ~p"/api/teller/webhook", body)

      assert response.status == 400
      assert %{"error" => "invalid signature"} = json_response(response, 400)

      assert Repo.all(Job) == []
    end

    test "acknowledges unknown connections without enqueuing", %{conn: conn, secret: secret} do
      payload = %{
        "connection_id" => Ecto.UUID.generate(),
        "event" => "accounts.updated",
        "nonce" => "nonce-#{System.unique_integer([:positive])}"
      }

      {body, header} = signed_payload(payload, secret)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("teller-signature", header)

      response = post(conn, ~p"/api/teller/webhook", body)

      assert json_response(response, 200) == %{
               "status" => "ignored",
               "reason" => "unknown_connection"
             }

      assert Repo.all(Job) == []
    end

    test "ignores duplicate deliveries", %{conn: conn, secret: secret} do
      user = AccountsFixtures.user_fixture()
      connection = InstitutionsFixtures.connection_fixture(user)

      payload = %{
        "connection_id" => connection.id,
        "event" => "transactions.updated",
        "nonce" => "fixed-nonce"
      }

      {body, header} = signed_payload(payload, secret)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("teller-signature", header)

      assert %{"status" => "ok"} =
               conn |> post(~p"/api/teller/webhook", body) |> json_response(200)

      assert %{"status" => "ignored", "reason" => "duplicate"} =
               conn
               |> recycle()
               |> put_req_header("content-type", "application/json")
               |> put_req_header("teller-signature", header)
               |> post(~p"/api/teller/webhook", body)
               |> json_response(200)

      assert Repo.aggregate(Job, :count, :id) == 1
    end

    test "returns ignored when connection revoked", %{conn: conn, secret: secret} do
      user = AccountsFixtures.user_fixture()
      connection = InstitutionsFixtures.connection_fixture(user)

      {:ok, _} = Institutions.mark_connection_revoked(user, connection.id)

      payload = %{
        "connection_id" => connection.id,
        "event" => "accounts.updated",
        "nonce" => "nonce-#{System.unique_integer([:positive])}"
      }

      {body, header} = signed_payload(payload, secret)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("teller-signature", header)

      response = post(conn, ~p"/api/teller/webhook", body)

      assert json_response(response, 200) == %{"status" => "ignored", "reason" => "revoked"}
      assert Repo.all(Job) == []
    end

    test "applies rate limiting", %{conn: conn, secret: secret} do
      original = Application.get_env(:money_tree, :rate_limiter)
      Application.put_env(:money_tree, :rate_limiter, MoneyTreeWeb.RateLimiter.DenyAll)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:money_tree, :rate_limiter)
          value -> Application.put_env(:money_tree, :rate_limiter, value)
        end
      end)

      payload = %{
        "connection_id" => Ecto.UUID.generate(),
        "event" => "accounts.updated",
        "nonce" => "nonce-#{System.unique_integer([:positive])}"
      }

      {body, header} = signed_payload(payload, secret)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("teller-signature", header)

      response = post(conn, ~p"/api/teller/webhook", body)

      assert response.status == 429
      assert %{"error" => "rate limit exceeded"} = json_response(response, 429)
    end
  end

  defp signed_payload(payload, secret) do
    body = Jason.encode!(payload)
    timestamp = System.system_time(:second)

    signature =
      :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}")
      |> Base.encode16(case: :lower)

    header = "t=#{timestamp},v1=#{signature}"

    {body, header}
  end
end
