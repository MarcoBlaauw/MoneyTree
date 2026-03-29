defmodule MoneyTreeWeb.PlaidWebhookControllerTest do
  use MoneyTreeWeb.ConnCase, async: true

  import Ecto.Query

  alias MoneyTree.AccountsFixtures
  alias MoneyTree.InstitutionsFixtures
  alias MoneyTree.Repo
  alias Oban.Job

  setup do
    original_config = Application.get_env(:money_tree, MoneyTree.Plaid)
    Application.put_env(:money_tree, MoneyTree.Plaid, webhook_secret: "plaid-secret")

    on_exit(fn ->
      case original_config do
        nil -> Application.delete_env(:money_tree, MoneyTree.Plaid)
        config -> Application.put_env(:money_tree, MoneyTree.Plaid, config)
      end
    end)

    :ok
  end

  test "verifies signature and enqueues plaid sync", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    connection =
      InstitutionsFixtures.connection_fixture(user, %{provider: "plaid", metadata: %{"status" => "active", "provider" => "plaid"}})

    payload = %{"connection_id" => connection.id, "event" => "SYNC_UPDATES_AVAILABLE", "nonce" => "nonce-1"}
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

    job = Repo.one!(from j in Job, order_by: [desc: j.inserted_at], limit: 1)
    assert job.worker == "Elixir.MoneyTree.Plaid.SyncWorker"
    assert job.args["provider"] == "plaid"
  end

  defp sign(timestamp, body) do
    :crypto.mac(:hmac, :sha256, "plaid-secret", "#{timestamp}.#{body}")
    |> Base.encode16(case: :lower)
  end
end
