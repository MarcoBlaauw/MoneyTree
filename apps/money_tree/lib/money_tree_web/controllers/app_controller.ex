defmodule MoneyTreeWeb.AppController do
  use MoneyTreeWeb, :controller

  def index(conn, _params) do
    redirect(conn, to: ~p"/app/dashboard")
  end

  def accounts(conn, _params) do
    redirect(conn, to: ~p"/app/accounts")
  end

  def categorization(conn, _params) do
    redirect(conn, to: ~p"/app/transactions/categorization")
  end
end
