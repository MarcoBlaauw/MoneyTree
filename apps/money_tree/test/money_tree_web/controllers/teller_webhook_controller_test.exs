defmodule MoneyTreeWeb.TellerWebhookControllerTest do
  use MoneyTreeWeb.ConnCase, async: true

  alias MoneyTree.AccountsFixtures
  alias MoneyTree.Institutions
  alias MoneyTree.InstitutionsFixtures
  alias MoneyTree.Repo

  defmodule DenyAll do
    @behaviour MoneyTreeWeb.RateLimiter

    @impl true
    def check(_bucket, _limit, _period), do: {:error, :rate_limited}
  end

  defmodule TellerWebhookClientStub do
    def list_accounts(_params) do
      {:ok,
       %{
         "data" => [
           %{
             "id" => "stub-acct-1",
             "name" => "Webhook Checking",
             "type" => "depository",
             "subtype" => "checking",
             "currency" => "USD",
             "balances" => %{"current" => "100.00", "available" => "75.00"}
           }
         ],
         "next_cursor" => nil
       }}
    end

    def list_transactions("stub-acct-1", _params) do
      {:ok, %{"data" => [], "next_cursor" => nil}}
    end
  end

  setup do
    original_config = Application.get_env(:money_tree, MoneyTree.Teller)
    original_client = Application.get_env(:money_tree, :teller_client)
    base_config = original_config || []
    secret = "test-webhook-secret"

    new_config =
      base_config
      |> Keyword.put(:webhook_secret, secret)

    Application.put_env(:money_tree, MoneyTree.Teller, new_config)
    Application.put_env(:money_tree, :teller_client, TellerWebhookClientStub)

    on_exit(fn ->
      case original_config do
        nil -> Application.delete_env(:money_tree, MoneyTree.Teller)
        config -> Application.put_env(:money_tree, MoneyTree.Teller, config)
      end

      case original_client do
        nil -> Application.delete_env(:money_tree, :teller_client)
        client -> Application.put_env(:money_tree, :teller_client, client)
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

      refreshed = Repo.get!(MoneyTree.Institutions.Connection, connection.id)
      webhook_meta = refreshed.metadata["teller_webhook"]

      assert webhook_meta["last_event"] == "accounts.updated"
      assert webhook_meta["nonces"][payload["nonce"]]
    end

    test "logs audit events when webhook processed", %{conn: conn, secret: secret} do
      attach_audit_listener([:teller_webhook_received, :teller_webhook_processed])

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

      _response = post(conn, ~p"/api/teller/webhook", body)

      assert_receive {:audit_event, [:money_tree, :audit, :teller_webhook_received],
                      received_meta}

      assert received_meta[:connection_id] == connection.id
      assert received_meta[:event] == "accounts.updated"

      assert_receive {:audit_event, [:money_tree, :audit, :teller_webhook_processed],
                      processed_meta}

      assert processed_meta[:connection_id] == connection.id
      assert processed_meta[:event] == "accounts.updated"
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
    end

    test "emits audit event for invalid signatures", %{conn: conn} do
      attach_audit_listener([:teller_webhook_signature_invalid])

      payload = %{"connection_id" => "conn", "event" => "foo", "nonce" => "abc"}
      body = Jason.encode!(payload)
      timestamp = System.system_time(:second)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("teller-signature", "t=#{timestamp},v1=invalid")

      _response = post(conn, ~p"/api/teller/webhook", body)

      assert_receive {:audit_event, [:money_tree, :audit, :teller_webhook_signature_invalid],
                      metadata}

      assert metadata[:remote_ip]
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
    end

    test "applies rate limiting", %{conn: conn, secret: secret} do
      original = Application.get_env(:money_tree, :rate_limiter)
      Application.put_env(:money_tree, :rate_limiter, DenyAll)

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

  defp attach_audit_listener(events) do
    handler_id = "audit-test-#{System.unique_integer([:positive])}"
    parent = self()

    telemetry_events = Enum.map(events, &[:money_tree, :audit, &1])

    :telemetry.attach_many(
      handler_id,
      telemetry_events,
      fn event, _meas, metadata, _config ->
        send(parent, {:audit_event, event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    handler_id
  end
end
