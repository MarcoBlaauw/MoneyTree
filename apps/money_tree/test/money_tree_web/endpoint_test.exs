defmodule MoneyTreeWeb.EndpointTest do
  use MoneyTreeWeb.ConnCase, async: true

  import MoneyTree.AccountsFixtures
  import Phoenix.LiveViewTest

  alias MoneyTreeWeb.Auth

  describe "session configuration" do
    test "uses shared cookie name with strict same-site and secure flags" do
      opts = Plug.Session.init(Auth.session_plug_options())

      conn =
        :get
        |> Plug.Test.conn("/", %{})
        |> Plug.Conn.fetch_cookies()
        |> Plug.Session.call(opts)
        |> Plug.Conn.fetch_session()
        |> Plug.Conn.put_session(:test_value, "ok")
        |> Plug.Conn.send_resp(200, "ok")

      cookie = conn.resp_cookies[Auth.session_cookie_name()]

      assert cookie
      assert cookie.same_site == "Strict"
      assert cookie.http_only
      assert cookie.secure == Auth.secure_cookies?()
    end
  end

  describe "content security policy" do
    test "assigns nonce and injects CSP header", %{conn: conn} do
      conn = get(conn, ~p"/login")

      assert nonce = conn.assigns[:csp_nonce]
      [header] = get_resp_header(conn, "content-security-policy")

      assert header =~ "default-src 'self'"
      assert header =~ "script-src 'self' 'nonce-#{nonce}'"
      assert header =~ "style-src 'self' 'nonce-#{nonce}'"
      assert header =~ "connect-src 'self'"

      expected_scheme = if conn.scheme == :https, do: "wss", else: "ws"

      expected_port =
        case {conn.scheme, conn.port} do
          {:http, 80} -> nil
          {:https, 443} -> nil
          {_, nil} -> nil
          {_, port} -> port
        end

      expected_origin =
        if is_nil(expected_port) do
          "#{expected_scheme}://#{conn.host}"
        else
          "#{expected_scheme}://#{conn.host}:#{expected_port}"
        end

      assert header =~ expected_origin

      alternate_scheme = if expected_scheme == "ws", do: "wss", else: "ws"
      alternate_origin = "#{alternate_scheme}://#{conn.host}"

      assert header =~ alternate_origin
      assert is_binary(conn.private[:csp_nonce])
    end
  end

  describe "liveview websocket session" do
    test "requires a valid session token for websocket connects", %{conn: conn} do
      user = user_fixture()
      %{token: token} = session_fixture(user, %{context: "test"})
      cookie_name = Auth.session_cookie_name()

      authed_conn =
        conn
        |> recycle()
        |> init_test_session(%{user_token: token})
        |> put_req_cookie(cookie_name, token)

      assert {:ok, _view, _html} = live(authed_conn, ~p"/app/dashboard")

      invalid_conn =
        conn
        |> recycle()
        |> init_test_session(%{user_token: token})
        |> put_req_cookie(cookie_name, "invalid")

      assert {:error, {:redirect, %{to: "/login"}}} = live(invalid_conn, ~p"/app/dashboard")
    end
  end
end
