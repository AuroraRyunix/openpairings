defmodule PairingsEngine.PairTimingTest do
  use PairingsEngine.DataCase, async: false

  import ExUnit.CaptureLog
  import PairingsEngine.NextRoundPreviewFixture

  alias PairingsEngine.PairTiming

  setup do
    test = self()
    id = "pair-timing-test-#{System.unique_integer()}"
    events = for stage <- PairTiming.stages(), do: PairTiming.prefix() ++ [stage, :stop]

    :telemetry.attach_many(
      id,
      events,
      fn [_, _, stage, :stop], %{duration: d}, _, _ -> send(test, {:stage, stage, d}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp stages_seen(acc \\ []) do
    receive do
      {:stage, stage, _duration} -> stages_seen([stage | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a span returns what its function returned, and says how long it took" do
    assert PairTiming.span(:engine, fn -> :paired end) == :paired
    assert_received {:stage, :engine, duration} when is_integer(duration)
  end

  test "pairing a Swiss round times each of its stages" do
    t = plain_tournament(12)
    pair!(t)

    seen = stages_seen()

    for stage <- ~w(warnings load input engine save deviations broadcast status explanation)a do
      assert stage in seen, "no #{stage} span in #{inspect(seen)}"
    end
  end

  test "the next-round preview's runs are not timed as the click" do
    t = plain_tournament(10)
    pair!(t)
    finish_latest_round(t)
    pair!(t)
    [p | _] = latest_round(t).pairings |> Enum.filter(& &1.black_player_id)
    {:ok, _} = PairingsEngine.Tournaments.update_pairing_result(p, "")
    _ = stages_seen()

    {:ok, _preview} = PairingsEngine.NextRoundPreview.run(reload(t))

    refute Enum.any?(stages_seen(), &(&1 in [:input, :engine]))
  end

  test "the log handler is off unless asked for, and logs each stage when it is" do
    previous = Application.get_env(:pairings_engine, :pair_timing)
    on_exit(fn -> restore(previous) end)

    # The test configuration logs warnings only; the handler logs at info.
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    Application.delete_env(:pairings_engine, :pair_timing)

    unless System.get_env("PAIR_TIMING") in ["1", "true"] do
      PairTiming.detach()
      assert PairTiming.maybe_attach() == :ok
      refute capture_log(fn -> PairTiming.span(:save, fn -> :ok end) end) =~ "pair timing"
    end

    Application.put_env(:pairings_engine, :pair_timing, true)
    assert PairTiming.maybe_attach() == :ok
    on_exit(&PairTiming.detach/0)

    assert capture_log(fn -> PairTiming.span(:save, fn -> :ok end) end) =~
             ~r/pair timing: save \d+\.\d ms/
  end

  defp restore(nil), do: Application.delete_env(:pairings_engine, :pair_timing)
  defp restore(value), do: Application.put_env(:pairings_engine, :pair_timing, value)
end
