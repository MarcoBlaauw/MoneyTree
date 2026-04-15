defmodule MoneyTree.Plaid.ClientTest do
  use ExUnit.Case

  alias MoneyTree.Plaid.Client

  setup do
    original = Application.get_env(:money_tree, MoneyTree.Plaid, [])

    on_exit(fn -> Application.put_env(:money_tree, MoneyTree.Plaid, original) end)
    :ok
  end

  test "returns validation error when client credentials are missing" do
    Application.put_env(:money_tree, MoneyTree.Plaid, api_host: "https://sandbox.plaid.com")

    assert {:error, %{type: :validation, details: %{message: "plaid is not configured"}}} =
             Client.create_link_token(%{"user" => %{"client_user_id" => "user-1"}})
  end

  test "builds client with configured credentials and default host from environment" do
    Application.put_env(:money_tree, MoneyTree.Plaid,
      environment: "development",
      client_id: "plaid-client-id",
      secret: "plaid-secret"
    )

    client = Client.new()

    assert client.client_id == "plaid-client-id"
    assert client.secret == "plaid-secret"
    assert client.request.options[:base_url] == "https://development.plaid.com"
  end

  test "requires access_token when syncing transactions" do
    Application.put_env(:money_tree, MoneyTree.Plaid,
      client_id: "plaid-client-id",
      secret: "plaid-secret"
    )

    client = Client.new()

    assert {:error, %{type: :validation, details: %{message: "access_token is required"}}} =
             Client.sync_transactions(client, nil, %{})
  end
end
