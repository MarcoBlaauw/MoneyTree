defmodule MoneyTreeWeb.AppRoutesTest do
  use MoneyTreeWeb.ConnCase, async: true

  import MoneyTree.AccountsFixtures
  import Phoenix.LiveViewTest

  alias MoneyTreeWeb.Auth

  describe "browser authentication" do
    test "redirects unauthenticated users", %{conn: conn} do
      paths = [~p"/app/dashboard", ~p"/app/transfers", ~p"/app/settings"]

      Enum.each(paths, fn path ->
        response_conn = conn |> recycle() |> get(path)
        assert redirected_to(response_conn) == ~p"/login"
      end)
    end

    test "allows authenticated users to mount LiveViews", %{conn: conn} do
      user = user_fixture()
      %{token: token} = session_fixture(user, %{context: "test"})
      cookie_name = Auth.session_cookie_name()

      {:ok, dashboard, _html} =
        conn |> authed_conn(cookie_name, token) |> live(~p"/app/dashboard")

      assert render(dashboard) =~ "Dashboard"

      {:ok, transfers, _html} =
        conn |> authed_conn(cookie_name, token) |> live(~p"/app/transfers")

      assert render(transfers) =~ "Transfers"

      {:ok, settings, _html} = conn |> authed_conn(cookie_name, token) |> live(~p"/app/settings")
      assert render(settings) =~ "Settings"
    end
  end

  defp authed_conn(conn, cookie_name, token) do
    conn
    |> recycle()
    |> init_test_session(%{user_token: token})
    |> put_req_cookie(cookie_name, token)
  end
end
