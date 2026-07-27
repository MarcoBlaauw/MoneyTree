defmodule MoneyTreeWeb.HealthController do
  use MoneyTreeWeb, :controller

  alias MoneyTree.Health

  @doc """
  Public, unauthenticated liveness endpoint. Deliberately minimal: no
  database error text, latency numbers, or Oban queue names/state --
  anonymous callers should learn nothing beyond "is the app up".
  """
  def public_health(conn, _params) do
    status = Health.public_status()

    conn
    |> put_status(status_code(status[:status]))
    |> put_resp_header("cache-control", "no-store")
    |> json(status)
  end

  @doc """
  Owner-only detailed health summary (database latency/errors, per-queue
  Oban state).
  """
  def health(conn, _params) do
    summary = Health.summary()

    conn
    |> put_status(status_code(summary[:status]))
    |> put_resp_header("cache-control", "no-store")
    |> json(summary)
  end

  @doc """
  Owner-only detailed metrics (per-queue Oban job-state counts, database
  latency).
  """
  def metrics(conn, _params) do
    metrics = Health.metrics()

    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(metrics)
  end

  defp status_code("ok"), do: :ok
  defp status_code(_), do: :service_unavailable
end
