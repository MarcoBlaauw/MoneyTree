defmodule MoneyTreeWeb.StripeClientStub do
  @moduledoc false

  def create_connect_session(params), do: dispatch(:create_connect_session, params)

  defp dispatch(key, arg) do
    case Process.get({__MODULE__, key}) do
      nil -> raise "stub not configured for #{inspect(key)}"
      fun when is_function(fun, 1) -> fun.(arg)
      value -> value
    end
  end
end

defmodule MoneyTreeWeb.StripeControllerTest do
  use MoneyTreeWeb.ConnCase

  import MoneyTree.AccountsFixtures

  alias MoneyTreeWeb.Auth

  @session_cookie Auth.session_cookie_name()

  setup %{conn: conn} do
    user = user_fixture()
    %{token: token} = session_fixture(user)

    conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

    original_client = Application.get_env(:money_tree, :stripe_client)
    Application.put_env(:money_tree, :stripe_client, MoneyTreeWeb.StripeClientStub)

    on_exit(fn ->
      Process.delete({MoneyTreeWeb.StripeClientStub, :create_connect_session})
      restore_env(:stripe_client, original_client)
    end)

    {:ok, conn: conn}
  end

  describe "authentication" do
    test "requires a valid session for Stripe endpoints", %{conn: conn} do
      conn = Plug.Conn.delete_req_header(conn, "cookie")
      response = post(conn, ~p"/api/stripe/session", %{})
      assert response.status == 401
    end
  end

  describe "POST /api/stripe/session" do
    test "returns Stripe session payload", %{conn: conn} do
      Process.put({MoneyTreeWeb.StripeClientStub, :create_connect_session}, fn params ->
        assert params == %{}
        {:ok, %{url: "https://connect.stripe.com/oauth/authorize?state=abc", state: "abc"}}
      end)

      response =
        conn
        |> post(~p"/api/stripe/session", %{})
        |> json_response(200)

      assert response == %{
               "data" => %{
                 "url" => "https://connect.stripe.com/oauth/authorize?state=abc",
                 "state" => "abc"
               }
             }
    end

    test "returns 503 when Stripe Connect is not configured", %{conn: conn} do
      Process.put({MoneyTreeWeb.StripeClientStub, :create_connect_session}, fn _ ->
        {:error, :not_configured}
      end)

      response =
        conn
        |> post(~p"/api/stripe/session", %{})
        |> json_response(503)

      assert response == %{"error" => "stripe connect is not configured"}
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:money_tree, key)
  defp restore_env(key, value), do: Application.put_env(:money_tree, key, value)
end
