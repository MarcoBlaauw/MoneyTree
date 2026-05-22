defmodule MoneyTreeWeb.EvaluationControllerTest do
  use MoneyTreeWeb.ConnCase

  import MoneyTree.AccountsFixtures
  import MoneyTree.MortgagesFixtures

  alias MoneyTreeWeb.Auth

  @session_cookie Auth.session_cookie_name()

  describe "evaluation status summary API" do
    test "returns deterministic status summary for the authenticated user", %{conn: conn} do
      user = user_fixture()
      %{token: token} = session_fixture(user)

      mortgage_fixture(user, %{
        nickname: "Home loan",
        home_value_estimate: nil,
        last_reviewed_at: nil
      })

      conn =
        conn
        |> put_req_header("cookie", "#{@session_cookie}=#{token}")
        |> get(~p"/api/evaluations/status-summary")

      assert %{
               "data" => %{
                 "generated_at" => generated_at,
                 "counts" => %{
                   "incomplete" => 1,
                   "needs_review" => 1,
                   "stale" => 0,
                   "opportunity" => 0,
                   "expiring" => 0
                 },
                 "items" => items
               }
             } = json_response(conn, 200)

      assert {:ok, _generated_at, 0} = DateTime.from_iso8601(generated_at)
      assert Enum.any?(items, &(&1["domain"] == "mortgage" and &1["status"] == "incomplete"))
      assert Enum.all?(items, &(&1["source"] == "deterministic"))
    end
  end
end
