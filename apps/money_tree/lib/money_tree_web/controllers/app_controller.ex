defmodule MoneyTreeWeb.AppController do
  use MoneyTreeWeb, :controller

  def index(conn, _params) do
    redirect(conn, to: ~p"/app/dashboard")
  end
end
