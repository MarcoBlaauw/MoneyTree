defmodule MoneyTreeWeb.Owner.UserControllerTest do
  use MoneyTreeWeb.ConnCase

  import MoneyTree.AccountsFixtures

  alias MoneyTree.Accounts

  setup [:register_owner]

  describe "GET /api/owner/users" do
    test "returns paginated users with metadata", %{conn: conn} do
      other = user_fixture(%{email: "other@example.com"})
      latest = user_fixture(%{email: "latest@example.com"})

      conn = get(conn, ~p"/api/owner/users", %{"page" => "1", "per_page" => "2"})

      assert %{"data" => data, "meta" => meta} = json_response(conn, 200)
      assert meta["page"] == 1
      assert meta["per_page"] == 2
      assert meta["total_entries"] == 3
      assert Enum.map(data, & &1["id"]) == [latest.id, other.id]
    end

    test "filters by email search term", %{conn: conn} do
      target = user_fixture(%{email: "target@example.com"})
      _ignored = user_fixture(%{email: "ignored@example.com"})

      conn = get(conn, ~p"/api/owner/users", %{"q" => "target"})

      assert %{"data" => [%{"id" => ^target.id}], "meta" => %{"total_entries" => 1}} =
               json_response(conn, 200)
    end

    test "requires owner role" do
      {:ok, %{conn: conn}} =
        register_and_log_in_user(%{conn: build_conn()}, user_attrs: %{role: :member})

      response = get(conn, ~p"/api/owner/users")

      assert response.status == 403
      assert %{"error" => "forbidden"} = json_response(response, 403)
    end

    test "requires authentication" do
      conn = build_conn()

      response = get(conn, ~p"/api/owner/users")

      assert response.status == 401
      assert %{"error" => "unauthorized"} = json_response(response, 401)
    end
  end

  describe "GET /api/owner/users/:id" do
    test "shows the requested user", %{conn: conn} do
      target = user_fixture(%{email: "detail@example.com"})

      conn = get(conn, ~p"/api/owner/users/#{target.id}")

      assert %{"data" => %{"id" => ^target.id, "email" => "detail@example.com", "suspended" => false}} =
               json_response(conn, 200)
    end

    test "returns 404 for unknown users", %{conn: conn} do
      conn = get(conn, ~p"/api/owner/users/#{Ecto.UUID.generate()}")
      assert conn.status == 404
      assert %{"error" => "not found"} = json_response(conn, 404)
    end
  end

  describe "PATCH /api/owner/users/:id" do
    test "updates the role", %{conn: conn} do
      target = user_fixture(%{role: :member})

      conn = patch(conn, ~p"/api/owner/users/#{target.id}", %{"role" => "advisor"})

      assert %{"data" => %{"id" => ^target.id, "role" => "advisor"}} = json_response(conn, 200)

      assert {:ok, reloaded} = Accounts.fetch_user(target.id)
      assert reloaded.role == :advisor
    end

    test "suspends and reactivates the user", %{conn: conn} do
      target = user_fixture()

      conn = patch(conn, ~p"/api/owner/users/#{target.id}", %{"suspended" => true})

      assert %{"data" => %{"suspended" => true, "suspended_at" => suspended_at}} =
               json_response(conn, 200)

      assert is_binary(suspended_at)
      assert {:ok, suspended} = Accounts.fetch_user(target.id)
      refute is_nil(suspended.suspended_at)

      conn = patch(conn, ~p"/api/owner/users/#{target.id}", %{"suspended" => false})

      assert %{"data" => %{"suspended" => false, "suspended_at" => nil}} =
               json_response(conn, 200)

      assert {:ok, reactivated} = Accounts.fetch_user(target.id)
      assert is_nil(reactivated.suspended_at)
    end

    test "validates suspended flag", %{conn: conn} do
      target = user_fixture()

      conn = patch(conn, ~p"/api/owner/users/#{target.id}", %{"suspended" => "maybe"})

      assert %{"error" => "suspended must be a boolean"} = json_response(conn, 422)
    end

    test "requires supported attributes", %{conn: conn} do
      target = user_fixture()

      conn = patch(conn, ~p"/api/owner/users/#{target.id}", %{})

      assert %{"error" => "no supported attributes provided"} = json_response(conn, 422)
    end

    test "reports conflicts for repeated suspension", %{conn: conn} do
      target = user_fixture()
      {:ok, _} = Accounts.suspend_user(target)

      conn = patch(conn, ~p"/api/owner/users/#{target.id}", %{"suspended" => true})

      assert %{"error" => "user is already suspended"} = json_response(conn, 409)
    end

    test "reports conflicts when reactivating active users", %{conn: conn} do
      target = user_fixture()

      conn = patch(conn, ~p"/api/owner/users/#{target.id}", %{"suspended" => false})

      assert %{"error" => "user is not suspended"} = json_response(conn, 409)
    end
  end

  describe "DELETE /api/owner/users/:id" do
    test "suspends the user and returns no content", %{conn: conn} do
      target = user_fixture()

      conn = delete(conn, ~p"/api/owner/users/#{target.id}")

      assert response(conn, 204)
      assert {:ok, reloaded} = Accounts.fetch_user(target.id)
      refute is_nil(reloaded.suspended_at)
    end

    test "returns conflict when already suspended", %{conn: conn} do
      target = user_fixture()
      {:ok, _} = Accounts.suspend_user(target)

      conn = delete(conn, ~p"/api/owner/users/#{target.id}")

      assert %{"error" => "user is already suspended"} = json_response(conn, 409)
    end
  end

  defp register_owner(context) do
    register_and_log_in_user(context, user_attrs: %{role: :owner})
  end
end
