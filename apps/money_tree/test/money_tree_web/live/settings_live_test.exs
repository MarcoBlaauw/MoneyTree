defmodule MoneyTreeWeb.SettingsLiveTest do
  use MoneyTreeWeb.ConnCase, async: true

  import MoneyTree.AccountsFixtures
  import Phoenix.LiveViewTest

  alias MoneyTreeWeb.Auth

  setup %{conn: conn} do
    user = user_fixture(%{full_name: "Example User"})
    %{token: token} = session_fixture(user, %{context: "browser", user_agent: "Mozilla", ip_address: "127.0.0.1"})
    session_fixture(user, %{context: "mobile", user_agent: "iOS App"})

    {:ok,
     conn: authed_conn(conn, token),
     user: user}
  end

  test "renders profile and security information", %{conn: conn, user: user} do
    {:ok, view, html} = live(conn, ~p"/app/settings")

    assert html =~ "Settings"
    assert html =~ user.email
    assert html =~ "Example User"
    assert html =~ "Active sessions"

    assert render(view) =~ "browser"
    assert render(view) =~ "mobile"
  end

  test "locking hides data and requires unlock", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/app/settings")

    view |> element("button", "Lock") |> render_click()
    assert render(view) =~ "Settings are locked"

    assert view |> element("button", "Refresh") |> render_click() =~ "Unlock settings"

    view |> element("button", "Unlock") |> render_click()
    refute render(view) =~ "Settings are locked"
  end

  defp authed_conn(conn, token) do
    cookie_name = Auth.session_cookie_name()

    conn
    |> recycle()
    |> init_test_session(%{user_token: token})
    |> put_req_cookie(cookie_name, token)
  end
end
