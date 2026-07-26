defmodule MoneyTreeWeb.Owner.SecretBackendControllerTest do
  use MoneyTreeWeb.ConnCase

  setup [:force_env_backend, :register_owner]

  describe "GET /api/owner/security/secret-backend" do
    test "returns secret backend status for owners", %{conn: conn} do
      conn = get(conn, ~p"/api/owner/security/secret-backend")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["backend"] in ["env", "openbao"]
      assert is_map(data["groups"])
      refute inspect(data) =~ "SECRET_KEY_BASE="
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "requires owner role" do
      {:ok, %{conn: conn}} =
        register_and_log_in_user(%{conn: build_conn()}, user_attrs: %{role: :member})

      response = get(conn, ~p"/api/owner/security/secret-backend")

      assert response.status == 403
      assert %{"error" => "forbidden"} = json_response(response, 403)
    end
  end

  describe "POST /api/owner/security/secret-backend/revalidate" do
    test "returns live revalidation summary for owners", %{conn: conn} do
      conn = post(conn, ~p"/api/owner/security/secret-backend/revalidate")

      assert %{"data" => %{"live" => true, "groups" => groups}} = json_response(conn, 200)
      assert is_map(groups)
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  defp force_env_backend(_context) do
    original_backend = System.get_env("MONEYTREE_SECRET_BACKEND")
    original_compat_backend = System.get_env("SECRET_BACKEND_MODE")

    System.put_env("MONEYTREE_SECRET_BACKEND", "env")
    System.delete_env("SECRET_BACKEND_MODE")

    on_exit(fn ->
      restore_env("MONEYTREE_SECRET_BACKEND", original_backend)
      restore_env("SECRET_BACKEND_MODE", original_compat_backend)
    end)

    :ok
  end

  defp register_owner(context) do
    register_and_log_in_user(context, user_attrs: %{role: :owner})
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
