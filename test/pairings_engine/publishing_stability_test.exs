defmodule PairingsEngine.PublishingStabilityTest do
  @moduledoc """
  What the light cannot say on its own.

  It answers "can this machine publish, right now", and the failure it
  describes worst is the intermittent one: a hall's wifi that drops for
  fifteen seconds every few minutes reads green almost every time somebody
  looks, while results arrive late for no visible reason.

  So the last twenty connection checks are kept - ten minutes at one every
  thirty seconds - and the panel can say whether it has BEHAVED, not only
  what it is.
  """
  use ExUnit.Case, async: false

  alias PairingsEngine.Publishing.Monitor

  # The Monitor is not started in test (its poller would make a network
  # request per tick), so these drive it directly with a private instance.
  setup do
    {:ok, pid} =
      GenServer.start_link(Monitor, [], name: :"stability_#{System.unique_integer([:positive])}")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, monitor: pid}
  end

  defp feed(pid, checks) do
    for {state, ms} <- checks do
      send(
        pid,
        {:connection,
         %{
           state: state,
           latency_ms: ms,
           pending: 0,
           message: "x",
           endpoint: "https://x",
           last_published_at: nil,
           last_publish_bytes: nil
         }}
      )
    end

    # One synchronous call flushes the mailbox ahead of it.
    GenServer.call(pid, :stability)
  end

  test "says nothing until there is enough evidence to say it", %{monitor: pid} do
    # "Steady for the last 10 minutes" from a process that started ninety
    # seconds ago would be a lie told confidently.
    assert feed(pid, []) == nil
    assert feed(pid, [{:connected, 40}, {:connected, 42}]) == nil
  end

  test "reports a steady window with its worst check", %{monitor: pid} do
    window = feed(pid, for(_ <- 1..8, do: {:connected, 40}) ++ [{:connected, 180}])

    assert window.failures == 0
    assert window.worst_ms == 180
    assert window.samples == 9
    assert window.minutes == 4
  end

  test "counts the drops that a green light would hide", %{monitor: pid} do
    # The whole point: it is answering NOW, and it has not been steady.
    checks =
      for i <- 1..12 do
        if rem(i, 5) == 0, do: {:unreachable, nil}, else: {:connected, 30}
      end

    window = feed(pid, checks)

    assert window.failures == 2
    assert window.worst_ms == 30
  end

  test "keeps ten minutes, not everything", %{monitor: pid} do
    # Capped in SAMPLES, so a laptop that slept does not report a window it
    # was not awake for.
    window = feed(pid, for(_ <- 1..60, do: {:connected, 25}))

    assert window.samples == 20
    assert window.minutes == 10
  end

  test "a window of only failures still reports, rather than crashing on no latency", %{
    monitor: pid
  } do
    window = feed(pid, for(_ <- 1..6, do: {:unreachable, nil}))

    assert window.failures == 6
    assert window.worst_ms == nil
  end

  describe "what it reports instead of an uptime percentage" do
    test "names when the last drop was, not a fraction", %{monitor: pid} do
      # A percentage would be dishonest twice: this app cannot see the checks
      # it failed to make while it was down, and 99.9% over a week is one
      # ten-minute outage - fine on a Tuesday, ruinous in round four.
      window = feed(pid, for(_ <- 1..8, do: {:connected, 20}))
      assert window.last_failure_at == nil
      assert window.since

      window = feed(pid, [{:unreachable, nil}])
      assert window.last_failure_at
    end

    test "a recovered connection still remembers the drop", %{monitor: pid} do
      # The whole point. It is green NOW; the question the panel answers is
      # whether it has been.
      window =
        feed(pid, [{:connected, 20}, {:unreachable, nil}] ++ for(_ <- 1..6, do: {:connected, 20}))

      assert window.failures == 1
      assert window.last_failure_at
    end

    test "`since` is when this process started, which a deploy resets", %{monitor: pid} do
      # Named and worded as such on screen. Calling it uptime would claim
      # something a process that restarts on every deploy cannot back.
      window = feed(pid, for(_ <- 1..5, do: {:connected, 20}))

      assert DateTime.diff(DateTime.utc_now(), window.since) < 5
    end
  end

  test "stability/0 answers nil when no Monitor is running" do
    # Every page renders this. It must never be the reason one fails.
    assert Monitor.stability() == nil
  end
end
