defmodule MoneyTreeWeb.LinkBankLive.SimpleFinClientStub do
  @moduledoc false

  def claim_setup_token("valid-token"), do: {:ok, "https://bridge.example/access"}
  def claim_setup_token(_token), do: {:error, :invalid_setup_token}

  def get_balances("https://bridge.example/access") do
    {:ok,
     %{
       "accounts" => [%{"id" => "acct-1", "name" => "Checking", "balance" => "100.00"}],
       "errors" => []
     }}
  end
end

defmodule MoneyTreeWeb.LinkBankLiveTest do
  use MoneyTreeWeb.ConnCase, async: false

  import MoneyTree.InstitutionsFixtures
  import Phoenix.LiveViewTest

  alias MoneyTree.BankSync.ProviderRegistry

  setup do
    original_client = Application.get_env(:money_tree, :simplefin_client)
    original_registry = Application.get_env(:money_tree, ProviderRegistry)

    Application.put_env(
      :money_tree,
      :simplefin_client,
      MoneyTreeWeb.LinkBankLive.SimpleFinClientStub
    )

    Application.put_env(:money_tree, ProviderRegistry,
      enabled_providers: ["simplefin", "manual"],
      primary_provider: "simplefin"
    )

    on_exit(fn ->
      if is_nil(original_client) do
        Application.delete_env(:money_tree, :simplefin_client)
      else
        Application.put_env(:money_tree, :simplefin_client, original_client)
      end

      if is_nil(original_registry) do
        Application.delete_env(:money_tree, ProviderRegistry)
      else
        Application.put_env(:money_tree, ProviderRegistry, original_registry)
      end
    end)

    :ok
  end

  test "claims a SimpleFIN setup token and lists the resulting connection", %{conn: conn} do
    {:ok, %{conn: conn}} = register_and_log_in_user(%{conn: conn})

    {:ok, view, html} = live(conn, ~p"/app/link-bank")
    assert html =~ "SimpleFIN Bridge"

    html =
      render_submit(view, "claim-setup-token", %{"simplefin" => %{"setup_token" => "valid-token"}})

    assert html =~ "Review accounts to import"
    assert html =~ "Checking"
  end

  test "shows an error for an invalid setup token", %{conn: conn} do
    {:ok, %{conn: conn}} = register_and_log_in_user(%{conn: conn})

    {:ok, view, _html} = live(conn, ~p"/app/link-bank")

    html =
      render_submit(view, "claim-setup-token", %{"simplefin" => %{"setup_token" => "bad-token"}})

    assert html =~ "does not look valid"
  end

  test "lists legacy connections with a purge-credentials action", %{conn: conn} do
    {:ok, %{conn: conn, user: user}} = register_and_log_in_user(%{conn: conn})
    connection_fixture(user, %{provider: "plaid"})

    {:ok, _view, html} = live(conn, ~p"/app/link-bank")

    assert html =~ "Legacy connections"
    assert html =~ "Purge credentials"
  end

  test "surfaces newly discovered accounts for approval and merges them on confirm", %{conn: conn} do
    {:ok, %{conn: conn, user: user}} = register_and_log_in_user(%{conn: conn})

    connection =
      connection_fixture(user, %{
        provider: "simplefin",
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

    {:ok, view, html} = live(conn, ~p"/app/link-bank")

    assert html =~ "New accounts found at SimpleFIN"
    assert html =~ "New Savings"

    render_submit(view, "confirm-import", %{
      "connection_id" => connection.id,
      "account_ids" => ["acct-2"]
    })

    refreshed = MoneyTree.Repo.get!(MoneyTree.Institutions.Connection, connection.id)
    review = MoneyTree.SimpleFin.import_review(refreshed)

    assert Enum.sort(review["account_ids"]) == ["acct-1", "acct-2"]
    assert review["pending_new_accounts"] == []

    refute render(view) =~ "New accounts found at SimpleFIN"
  end
end
