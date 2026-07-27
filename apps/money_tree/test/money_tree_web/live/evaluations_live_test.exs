defmodule MoneyTreeWeb.EvaluationsLiveTest do
  use MoneyTreeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders evaluation status counts and refreshes", %{conn: conn} do
    {:ok, %{conn: conn}} = register_and_log_in_user(%{conn: conn})

    {:ok, view, html} = live(conn, ~p"/app/evaluations")

    assert html =~ "Evaluations"
    assert html =~ "Needs review"

    html = render_click(view, "refresh")
    assert html =~ "Current items"
  end
end
