defmodule MoneyTreeWeb.StripeController do
  use MoneyTreeWeb, :controller

  def session(conn, params) do
    case stripe_client().create_connect_session(params) do
      {:ok, payload} ->
        json(conn, %{data: payload})

      {:error, :not_configured} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "stripe connect is not configured"})

      {:error, _reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "stripe session request failed"})
    end
  end

  defp stripe_client do
    Application.get_env(:money_tree, :stripe_client, MoneyTree.Stripe.Client)
  end
end
