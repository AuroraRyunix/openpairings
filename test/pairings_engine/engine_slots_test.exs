defmodule PairingsEngine.EngineSlotsTest do
  @moduledoc """
  The machine-wide count of engine runs and the per-tournament lock. Each
  test runs a server of its own with the limits it names, so the
  application's own server - and every other test pairing a tournament -
  never notices.
  """
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias PairingsEngine.EngineSlots

  setup do
    name = :"engine_slots_#{System.unique_integer([:positive])}"
    start_supervised!({EngineSlots, name: name})
    {:ok, opts: [server: name, limit: 1]}
  end

  # A process that takes a slot and keeps it until told to go.
  defp holder(pool, key, opts) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:requested, self(), EngineSlots.request(pool, key, opts)})

        receive do
          :go -> :ok
        end
      end)

    assert_receive {:requested, ^pid, reply}
    {pid, reply}
  end

  defp stop(pid) do
    ref = Process.monitor(pid)
    send(pid, :go)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  test "grants up to the limit, then queues", %{opts: opts} do
    {first, {:ok, _ref}} = holder(:pairing, 1, opts)
    assert {:queued, ref} = EngineSlots.request(:pairing, 2, opts)

    # The holder leaving - by any route - hands its slot on.
    stop(first)
    assert_receive {:engine_slot, ^ref, :granted}
  end

  test "one tournament is one run, however many tabs ask", %{opts: opts} do
    {first, {:ok, _ref}} = holder(:pairing, 7, Keyword.put(opts, :limit, 5))

    assert {:error, :engine_already_pairing} =
             EngineSlots.request(:pairing, 7, Keyword.put(opts, :limit, 5))

    # A different tournament is not held up by it.
    assert {:ok, _} = EngineSlots.request(:pairing, 8, Keyword.put(opts, :limit, 5))

    # And once the first is done, the same tournament may pair again.
    stop(first)
    assert {:ok, _} = EngineSlots.request(:pairing, 7, Keyword.put(opts, :limit, 5))
  end

  test "a waiting run also holds its tournament's lock", %{opts: opts} do
    {first, {:ok, _}} = holder(:pairing, 1, opts)
    {second, {:queued, _}} = holder(:pairing, 2, opts)

    assert {:error, :engine_already_pairing} = EngineSlots.request(:pairing, 2, opts)

    stop(first)
    stop(second)
  end

  test "pools are separate", %{opts: opts} do
    {first, {:ok, _}} = holder(:pairing, nil, opts)
    assert {:ok, _} = EngineSlots.request(:preview, nil, opts)
    assert {:ok, _} = EngineSlots.request(:explanation, nil, opts)
    stop(first)
  end

  test "run/4: busy when no slot comes free in time, and the place is given up", %{opts: opts} do
    {first, {:ok, _}} = holder(:pairing, 1, opts)

    assert {:error, :engine_busy} =
             EngineSlots.run(:pairing, 2, fn -> :never end, Keyword.put(opts, :wait, 20))

    # Gave up its place: tournament 2 is not still waiting.
    stop(first)
    assert :ran = EngineSlots.run(:pairing, 2, fn -> :ran end, opts)
  end

  test "run/4: says it is queued before it waits", %{opts: opts} do
    {first, {:ok, _}} = holder(:pairing, 1, opts)
    test = self()

    task =
      Task.async(fn ->
        EngineSlots.run(:pairing, 2, fn -> :paired end,
          server: opts[:server],
          limit: 1,
          on_queued: fn -> send(test, :queued) end
        )
      end)

    assert_receive :queued
    stop(first)
    assert Task.await(task) == :paired
  end

  test "run/4: a run past its time is stopped, and its slot comes back", %{opts: opts} do
    assert {:error, :engine_timeout} =
             EngineSlots.run(:pairing, 1, fn -> Process.sleep(:infinity) end,
               server: opts[:server],
               limit: 1,
               timeout: 50
             )

    assert :again = EngineSlots.run(:pairing, 1, fn -> :again end, opts)
  end

  test "run/4: a run that crashes is an error, not a crashed page", %{opts: opts} do
    assert {:error, :engine_failed} =
             EngineSlots.run(:pairing, 1, fn -> raise "no" end,
               server: opts[:server],
               limit: 1,
               timeout: 5_000
             )

    assert :fine = EngineSlots.run(:pairing, 1, fn -> :fine end, opts)
  end
end
