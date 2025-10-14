defmodule MoneyTreeWeb.HealthController do
  use MoneyTreeWeb, :controller

  alias MoneyTree.Health

  def health(conn, _params) do
    summary = Health.summary()

    conn
    |> put_status(status_code(summary[:status]))
    |> put_resp_header("cache-control", "no-store")
    |> json(summary)
  end

  def metrics(conn, _params) do
    metrics = Health.metrics()

    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(metrics)
  end

  defp status_code("ok"), do: :ok
  defp status_code(_), do: :service_unavailable
end
