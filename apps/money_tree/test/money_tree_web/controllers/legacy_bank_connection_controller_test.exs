defmodule MoneyTreeWeb.LegacyBankConnectionControllerTest do
  use MoneyTreeWeb.ConnCase

  import MoneyTree.AccountsFixtures
  import MoneyTree.InstitutionsFixtures

  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Repo
  alias MoneyTreeWeb.Auth

  @session_cookie Auth.session_cookie_name()

  setup %{conn: conn} do
    user = user_fixture()
    %{token: token} = session_fixture(user)
    conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

    {:ok, conn: conn, user: user}
  end

  test "lists legacy Teller and Plaid connections with credential state", %{
    conn: conn,
    user: user
  } do
    teller = connection_fixture(user, %{provider: "teller"})

    plaid =
      connection_fixture(user, %{
        provider: "plaid",
        teller_enrollment_id: nil,
        teller_user_id: nil
      })

    _simplefin = connection_fixture(user, %{provider: "simplefin"})

    response =
      conn
      |> get(~p"/api/legacy-bank-connections")
      |> json_response(200)

    connection_ids =
      response["data"]["connections"]
      |> Enum.map(& &1["id"])
      |> MapSet.new()

    assert MapSet.member?(connection_ids, teller.id)
    assert MapSet.member?(connection_ids, plaid.id)
    assert MapSet.size(connection_ids) == 2
    assert Enum.all?(response["data"]["connections"], & &1["credentials_present?"])
  end

  test "purges legacy credentials without deleting the connection", %{conn: conn, user: user} do
    connection =
      connection_fixture(user, %{
        provider: "teller",
        encrypted_credentials: Jason.encode!(%{"access_token" => "secret"}),
        webhook_secret: "webhook-secret",
        teller_enrollment_id: "enroll-1",
        teller_user_id: "user-1",
        provider_metadata: %{"cursor" => "old"}
      })

    response =
      conn
      |> post(~p"/api/legacy-bank-connections/#{connection.id}/purge-credentials")
      |> json_response(200)

    assert response["data"]["connection"]["credentials_present?"] == false

    refreshed = Repo.get!(Connection, connection.id)
    assert refreshed.encrypted_credentials == nil
    assert refreshed.webhook_secret == nil
    assert refreshed.teller_enrollment_id == nil
    assert refreshed.teller_user_id == nil
    assert refreshed.provider_metadata == %{}
    assert refreshed.metadata["credentials_purged"] == true
    assert refreshed.metadata["credentials_purged_at"]
  end

  test "rejects purging SimpleFIN credentials through legacy endpoint", %{conn: conn, user: user} do
    connection = connection_fixture(user, %{provider: "simplefin"})

    response =
      conn
      |> post(~p"/api/legacy-bank-connections/#{connection.id}/purge-credentials")
      |> json_response(400)

    assert response["error"] == "credentials can only be purged for Teller or Plaid connections"
  end
end
