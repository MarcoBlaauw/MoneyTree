defmodule MoneyTreeWeb.ErrorJSONTest do
  use MoneyTreeWeb.ConnCase, async: true

  test "renders 404" do
    assert MoneyTreeWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert MoneyTreeWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
