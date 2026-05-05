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
    webauthn_credential_fixture(context.user, %{kind: "passkey", label: "MacBook Touch ID"})
    webauthn_credential_fixture(context.user, %{kind: "security_key", label: "YubiKey 5C"})

    {:ok, context}
  end

  test "renders sectioned settings home and CSP meta tags", %{conn: conn, user: user} do
    {:ok, view, html} = live(conn, ~p"/app/settings")

    assert html =~ "<meta name=\"csp-nonce\""
    assert html =~ "<meta name=\"csp-script-src\""
    assert html =~ "<meta name=\"csp-style-src\""
    assert html =~ "Settings"
    assert html =~ user.email
    assert html =~ "Example User"
    assert html =~ "Settings areas"
    assert html =~ "Profile"
    assert html =~ "Security"
    assert html =~ "Sessions &amp; devices"
    assert html =~ "Data &amp; privacy"

    refute render(view) =~ "Save alert preferences"
  end

  test "supports direct section routes", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/app/settings/notifications")

    assert html =~ "Payment alerts"
    assert html =~ "Save alert preferences"
    refute html =~ "Authentication posture"
  end

  test "locking hides data and requires unlock", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/app/settings")

    view |> element("button", "Lock") |> render_click()
    assert render(view) =~ "Settings are locked"

    assert view |> element("button", "Refresh") |> render_click() =~ "Unlock settings"

    view |> element("button", "Unlock") |> render_click()
    refute render(view) =~ "Settings are locked"
  end

  test "users can update their profile", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/app/settings")

    view
    |> form("#profile-form", %{
      profile: %{
        encrypted_full_name: "Updated User",
        email: "updated.user@example.com"
      }
    })
    |> render_submit()

    html = render(view)
    assert html =~ "Profile updated."
    assert html =~ "Updated User"
    assert html =~ "updated.user@example.com"
  end

  test "users can update alert preferences", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/app/settings/notifications")

    view
    |> form("#notification-preferences-form", %{
      notifications: %{
        email_enabled: "false",
        dashboard_enabled: "true",
        upcoming_enabled: "true",
        due_today_enabled: "true",
        overdue_enabled: "true",
        recovered_enabled: "false",
        upcoming_lead_days: "5",
        resend_interval_hours: "12",
        max_resends: "1"
      }
    })
    |> render_submit()

    html = render(view)
    assert html =~ "Alert preferences updated."
    assert html =~ "value=\"5\""
    assert html =~ "value=\"12\""
    assert html =~ "value=\"1\""
  end

  test "sessions section renders current sessions", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/app/settings/sessions")

    assert render(view) =~ "Recent access"
    assert render(view) =~ "browser"
    assert render(view) =~ "mobile"
  end

  test "security section renders credential inventory", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/app/settings/security")

    assert html =~ "Authentication posture"
    assert html =~ "Magic links"
    assert html =~ "MacBook Touch ID"
    assert html =~ "YubiKey 5C"
    assert html =~ "Still enabled"
    assert html =~ "Register passkey"
    assert html =~ "Register security key"
    assert html =~ "Remove"
  end

  test "shows warning for non-local ollama url", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/app/settings/privacy")

    view
    |> form("#ai-settings-form", %{
      "ai" => %{
        "base_url" => "https://ollama.example.com"
      }
    })
    |> render_change()

    assert render(view) =~ "Non-local Ollama URL detected"
  end
end
