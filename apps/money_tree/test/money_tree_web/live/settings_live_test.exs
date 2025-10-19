defmodule MoneyTreeWeb.SettingsLiveTest do
  use MoneyTreeWeb.ConnCase, async: true

  import MoneyTree.AccountsFixtures
  import Phoenix.LiveViewTest

  setup context do
    {:ok, context} =
      register_and_log_in_user(context,
        user_attrs: %{full_name: "Example User"},
        session_attrs: %{context: "browser", user_agent: "Mozilla", ip_address: "127.0.0.1"}
      )

    session_fixture(context.user, %{context: "mobile", user_agent: "iOS App"})

    {:ok, context}
  end

  test "renders profile, security information, and CSP meta tags", %{conn: conn, user: user} do
    {:ok, view, html} = live(conn, ~p"/app/settings")

    assert html =~ "<meta name=\"csp-nonce\""
    assert html =~ "<meta name=\"csp-script-src\""
    assert html =~ "<meta name=\"csp-style-src\""
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
end
