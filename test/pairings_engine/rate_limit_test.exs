defmodule PairingsEngine.RateLimitTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.RateLimit

  # Keys are namespaced per test so the shared ETS table can't leak counts
  # between them.
  defp key, do: "key-#{System.unique_integer([:positive])}"

  test "allows up to the bucket's maximum, then stops" do
    key = key()
    %{max: max} = RateLimit.config(:mobile_enroll)

    for _ <- 1..max do
      assert RateLimit.allow?(:mobile_enroll, key)
      RateLimit.record(:mobile_enroll, key)
    end

    refute RateLimit.allow?(:mobile_enroll, key)
  end

  test "clear/2 hands the allowance straight back" do
    key = key()
    %{max: max} = RateLimit.config(:mobile_enroll)

    for _ <- 1..max, do: RateLimit.record(:mobile_enroll, key)
    refute RateLimit.allow?(:mobile_enroll, key)

    RateLimit.clear(:mobile_enroll, key)

    assert RateLimit.allow?(:mobile_enroll, key)
  end

  test "buckets are counted separately, and so are keys" do
    key = key()
    other = key()
    %{max: max} = RateLimit.config(:mobile_enroll)

    for _ <- 1..max, do: RateLimit.record(:mobile_enroll, key)

    refute RateLimit.allow?(:mobile_enroll, key)
    assert RateLimit.allow?(:login_email, key)
    assert RateLimit.allow?(:mobile_enroll, other)
  end

  test "the log-in bucket is the tighter of the two" do
    assert RateLimit.config(:login_email).max < RateLimit.config(:mobile_enroll).max
  end

  test "an unknown bucket raises rather than silently allowing everything" do
    assert_raise KeyError, fn -> RateLimit.allow?(:not_a_bucket, "k") end
  end
end
