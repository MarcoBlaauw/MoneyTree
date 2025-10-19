defmodule MoneyTreeWeb.AppRoutesTest do
  use MoneyTreeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "browser authentication" do
    test "redirects unauthenticated users", %{conn: conn} do
      paths = [~p"/app/dashboard", ~p"/app/transfers", ~p"/app/settings"]

      Enum.each(paths, fn path ->
        response_conn = conn |> recycle() |> get(path)
        assert redirected_to(response_conn) == ~p"/login"
      end)
    end

    test "allows authenticated users to mount LiveViews", %{conn: conn} do
      {:ok, %{conn: authed_conn}} = register_and_log_in_user(%{conn: conn})

      {:ok, dashboard, _html} = live(authed_conn, ~p"/app/dashboard")

      assert render(dashboard) =~ "Dashboard"

      {:ok, transfers, _html} = live(authed_conn, ~p"/app/transfers")

      assert render(transfers) =~ "Transfers"

      {:ok, settings, _html} = live(authed_conn, ~p"/app/settings")
      assert render(settings) =~ "Settings"
    end
  end
end
