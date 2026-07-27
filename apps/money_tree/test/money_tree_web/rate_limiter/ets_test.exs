defmodule MoneyTreeWeb.RateLimiter.EtsTest do
  use ExUnit.Case, async: false

  alias MoneyTreeWeb.RateLimiter.Ets

  test "allows calls under the limit and blocks once exceeded within the same window" do
    bucket = {:test_bucket, System.unique_integer([:positive])}

    assert :ok = Ets.check(bucket, 3, 60)
    assert :ok = Ets.check(bucket, 3, 60)
    assert :ok = Ets.check(bucket, 3, 60)
    assert {:error, :rate_limited} = Ets.check(bucket, 3, 60)
  end

  test "different buckets are tracked independently" do
    bucket_a = {:test_bucket, System.unique_integer([:positive])}
    bucket_b = {:test_bucket, System.unique_integer([:positive])}

    assert :ok = Ets.check(bucket_a, 1, 60)
    assert {:error, :rate_limited} = Ets.check(bucket_a, 1, 60)
    assert :ok = Ets.check(bucket_b, 1, 60)
  end

  test "resets after the window elapses" do
    bucket = {:test_bucket, System.unique_integer([:positive])}

    assert :ok = Ets.check(bucket, 1, 1)
    assert {:error, :rate_limited} = Ets.check(bucket, 1, 1)

    Process.sleep(1100)

    assert :ok = Ets.check(bucket, 1, 1)
  end
end
