defmodule PairingsEngine.RateLimitTest do
  # Deliberately synchronous. `PairingsEngineWeb.ConnCase` now wipes the
  # shared counter table in its setup, and these tests read a count back
  # across several statements - run concurrently with a web test, the wipe
  # would land in the middle of one of them. Sync modules run after the
  # async ones, so nothing can clear the table underneath these.
  use ExUnit.Case, async: false

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

  test "concurrent hits are all counted - the increment is atomic, not read-then-write" do
    # Read-then-write lost hits under exactly the traffic these buckets are
    # for: several requests from one abuser land on several schedulers, each
    # reads the same count and writes back the same number, and a burst is
    # counted as one.
    key = key()
    parent = self()

    # Every process is parked on the same barrier and released at once, so
    # the 200 increments genuinely overlap rather than queueing up behind
    # each other the way a plain `Enum.map` over tasks would.
    workers =
      for _ <- 1..200 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> RateLimit.record(:public_register, key)
          end
        end)
      end

    for _ <- workers, do: assert_receive({:ready, _})
    for w <- workers, do: send(w.pid, :go)
    for w <- workers, do: Task.await(w)

    assert RateLimit.count(:public_register, key) == 200
  end

  test "a hit on an untouched key starts the window at one" do
    key = key()
    RateLimit.record(:mobile_enroll, key)
    assert RateLimit.count(:mobile_enroll, key) == 1
  end

  test "an unknown bucket raises rather than silently allowing everything" do
    assert_raise KeyError, fn -> RateLimit.allow?(:not_a_bucket, "k") end
  end
end
