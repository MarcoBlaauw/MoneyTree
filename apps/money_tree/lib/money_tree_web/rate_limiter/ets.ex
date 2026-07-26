defmodule MoneyTreeWeb.RateLimiter.Ets do
  @moduledoc """
  Single-node, ETS-backed fixed-window rate limiter.

  Each bucket is limited to `limit` calls per `period` seconds. Windows are
  keyed by `div(monotonic_seconds, period)`, so a bucket's count resets at
  each period boundary rather than sliding continuously.

  This is a per-node limiter: in a multi-node deployment each node enforces
  its own limit independently, so the effective cluster-wide limit is
  `limit * node_count`. That's an acceptable tradeoff for a single-node
  deployment; a clustered deployment that needs a precise shared limit
  should back this behaviour with a shared store (e.g. Redis) instead.
  """

  @behaviour MoneyTreeWeb.RateLimiter

  use GenServer

  @table __MODULE__
  @sweep_interval :timer.minutes(5)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl MoneyTreeWeb.RateLimiter
  @spec check(MoneyTreeWeb.RateLimiter.bucket(), MoneyTreeWeb.RateLimiter.limit(), MoneyTreeWeb.RateLimiter.period()) ::
          :ok | {:error, :rate_limited}
  def check(bucket, limit, period) when is_integer(limit) and is_integer(period) and period > 0 do
    now = System.monotonic_time(:second)
    window = div(now, period)
    key = {bucket, window}
    expires_at = window * period + period

    count = :ets.update_counter(@table, key, {2, 1}, {key, 0, expires_at})

    if count > limit do
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:second)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end
end
