defmodule MoneyTreeWeb.TellerWebhookController do
  use MoneyTreeWeb, :controller

  @doc false
  def handle(conn, _params) do
    conn
    |> put_status(:not_implemented)
    |> json(%{error: "webhook handling not implemented"})
  end
end
