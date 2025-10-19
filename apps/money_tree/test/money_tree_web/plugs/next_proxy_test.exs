defmodule MoneyTreeWeb.Plugs.NextProxyTest do
  use MoneyTreeWeb.ConnCase, async: true

  alias MoneyTreeWeb.Plugs.NextProxy

  defmodule TestClient do
    @behaviour MoneyTreeWeb.Plugs.NextProxy.Client

    @impl true
    def request(method, url, headers, body, opts) do
      send(self(), {:proxy_request, method, url, headers, body, opts})

      {:ok,
       %Finch.Response{
         status: 200,
         headers: [
           {"content-type", "text/html"},
           {"cache-control", "no-store"},
           {"set-cookie", "ignored=true"}
         ],
         body: "<html>ok</html>"
       }}
    end
  end

  defmodule ErrorClient do
    @behaviour MoneyTreeWeb.Plugs.NextProxy.Client

    @impl true
    def request(_method, _url, _headers, _body, _opts), do: {:error, :timeout}
  end

  setup %{conn: conn} do
    conn =
      conn
      |> Map.put(:secret_key_base, String.duplicate("a", 64))
      |> Plug.Conn.put_private(:csp_nonce, "nonce-123")
      |> Plug.Conn.assign(:csp_nonce, "nonce-123")
      |> Plug.Conn.put_req_header("cookie", "_money_tree_session=test")

    %{conn: conn}
  end

  test "proxies requests and preserves security headers", %{conn: conn} do
    conn =
      conn
      |> Plug.Conn.put_req_header("accept", "text/html")
      |> Map.put(:remote_ip, {192, 168, 0, 2})
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.fetch_query_params()
      |> Map.put(:request_path, "/app/react")
      |> Map.put(:path_info, ["app", "react"])
      |> Map.put(:query_string, "")
      |> Map.put(:method, "GET")

    opts =
      NextProxy.init(
        client: TestClient,
        upstream: [scheme: "http", host: "next.local", port: 3100, path: "/"]
      )

    conn = NextProxy.call(conn, opts)

    assert conn.halted
    assert conn.status == 200
    assert conn.resp_body == "<html>ok</html>"
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/html"]
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
    assert Plug.Conn.get_resp_header(conn, "set-cookie") == []
    assert Plug.Conn.get_resp_header(conn, "x-csp-nonce") == ["nonce-123"]
    assert [csrf_header] = Plug.Conn.get_resp_header(conn, "x-csrf-token")
    assert csrf_header != ""

    assert_received {:proxy_request, "GET", "http://next.local:3100/app/react", headers, "",
                     _opts}

    header_map = Map.new(headers)
    assert header_map["host"] == "next.local:3100"
    assert header_map["cookie"] =~ "_money_tree_session=test"
    assert header_map["x-csp-nonce"] == "nonce-123"
    assert header_map["x-csrf-token"] == csrf_header
    assert header_map["x-forwarded-for"] =~ "192.168.0.2"
  end

  test "returns bad gateway when upstream errors", %{conn: conn} do
    opts =
      NextProxy.init(
        client: ErrorClient,
        upstream: [scheme: "http", host: "next.local", port: 3100, path: "/"]
      )

    conn =
      conn
      |> Map.put(:request_path, "/app/react")
      |> Map.put(:path_info, ["app", "react"])
      |> Map.put(:query_string, "")
      |> Map.put(:method, "GET")
      |> NextProxy.call(opts)

    assert conn.status == 502
    assert conn.halted
    assert conn.resp_body =~ "Next.js upstream is unavailable"
  end
end
