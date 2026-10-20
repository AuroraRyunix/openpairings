defmodule PairingsEngine.EngineSlotsLimitTest do
  @moduledoc "Which limits apply where: the hosted edition counts, a desktop install does not."
  use ExUnit.Case, async: false

  alias PairingsEngine.EngineSlots

  setup do
    local = Application.get_env(:pairings_engine, :local_mode)
    slots = Application.get_env(:pairings_engine, :engine_slots)
    timeout = Application.get_env(:pairings_engine, :pairing_timeout_ms)

    on_exit(fn ->
      Application.put_env(:pairings_engine, :local_mode, local)
      Application.put_env(:pairings_engine, :engine_slots, slots)

      if timeout,
        do: Application.put_env(:pairings_engine, :pairing_timeout_ms, timeout),
        else: Application.delete_env(:pairings_engine, :pairing_timeout_ms)
    end)
  end

  test "hosted: the configured number, or two" do
    Application.put_env(:pairings_engine, :local_mode, false)
    Application.put_env(:pairings_engine, :engine_slots, pairing: 1)
    assert EngineSlots.limit(:pairing) == 1

    Application.put_env(:pairings_engine, :engine_slots, [])
    assert EngineSlots.limit(:pairing) == 2
    assert EngineSlots.limit(:preview) == 1
    assert EngineSlots.pairing_timeout() == 180_000
  end

  test "desktop: no machine-wide cap and no time limit" do
    Application.put_env(:pairings_engine, :local_mode, true)
    Application.put_env(:pairings_engine, :engine_slots, pairing: 1)
    Application.put_env(:pairings_engine, :pairing_timeout_ms, 10)

    assert EngineSlots.limit(:pairing) == :infinity
    assert EngineSlots.pairing_timeout() == :infinity
  end
end
