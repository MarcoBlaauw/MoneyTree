defmodule MoneyTreeWeb.Owner.SecretBackendController do
  @moduledoc """
  Owner-only secret backend status API.
  """

  use MoneyTreeWeb, :controller

  alias MoneyTree.Secrets.Health

  def show(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(%{data: Health.summary()})
  end

  def revalidate(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(%{data: Health.summary(live?: true)})
  end
end
