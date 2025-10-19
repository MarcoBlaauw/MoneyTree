defmodule MoneyTreeWeb.MockAuthController do
  use MoneyTreeWeb, :controller

  def show(conn, _params) do
    json(conn, %{ok: true})
  end
end
