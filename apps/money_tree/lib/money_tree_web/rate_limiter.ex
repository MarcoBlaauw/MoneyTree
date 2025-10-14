defmodule MoneyTreeWeb.RateLimiter do
  @moduledoc """
  Thin abstraction over request rate limiting to keep controllers decoupled from implementation.
  """

  @type bucket :: term()
  @type limit :: pos_integer()
  @type period :: pos_integer()

  @callback check(bucket(), limit(), period()) :: :ok | {:error, :rate_limited}

  @spec check(bucket(), limit(), period()) :: :ok | {:error, :rate_limited}
  def check(bucket, limit, period) do
    impl().check(bucket, limit, period)
  end

  defp impl do
    Application.get_env(:money_tree, :rate_limiter, MoneyTreeWeb.RateLimiter.Noop)
  end
end

defmodule MoneyTreeWeb.RateLimiter.Noop do
  @moduledoc false
  @behaviour MoneyTreeWeb.RateLimiter

  @impl true
  def check(_bucket, _limit, _period), do: :ok
end
