defmodule PairingsEngine.Fide.SyncTest do
  # Sync is a singleton GenServer (named process) started by the application
  # supervisor, so tests here mutate shared global state via :sys and fake
  # OTP messages rather than spinning up isolated instances. Kept `async:
  # false` since nothing else in the suite touches this process, but there's
  # no reason to risk interleaving with itself.
  use ExUnit.Case, async: false

  alias PairingsEngine.Fide.Sync

  setup do
    reset_state()
    Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Sync.topic())
    on_exit(fn -> reset_state() end)
    :ok
  end

  defp reset_state, do: :sys.replace_state(Sync, fn _ -> struct(Sync) end)
  defp raw_state, do: :sys.get_state(Sync)

  defp put_busy(status, extra \\ %{}) do
    fields = Map.merge(%{status: status}, extra) |> Map.to_list()
    :sys.replace_state(Sync, fn state -> struct(state, fields) end)
  end

  defp alive_dummy do
    spawn(fn -> Process.sleep(:infinity) end)
  end

  describe "task crash (:DOWN) handling" do
    test "an abnormal :DOWN for the current task resets state to :error and clears busy fields" do
      pid = alive_dummy()
      ref = make_ref()
      put_busy(:downloading, %{task_pid: pid, task_ref: ref})

      send(Sync, {:DOWN, ref, :process, pid, :killed})

      assert_receive {:fide_sync, %Sync{status: :error} = state}
      assert state.error =~ "crashed unexpectedly"
      assert state.task_pid == nil
      assert state.task_ref == nil
      assert state.watchdog_timer == nil

      assert raw_state().status == :error
    end

    test "a stale :DOWN (task_ref no longer matches) is ignored and does not clobber state" do
      stale_ref = make_ref()
      pid = alive_dummy()

      # Simulate: the sync already finished/was cancelled, so task_ref is nil.
      put_busy(:idle, %{task_ref: nil, task_pid: nil})

      send(Sync, {:DOWN, stale_ref, :process, pid, :killed})

      # No PubSub broadcast should have been triggered by the stale DOWN.
      refute_receive {:fide_sync, _}, 100
      assert raw_state().status == :idle
    end

    test "a :normal :DOWN is not treated as a crash" do
      pid = alive_dummy()
      ref = make_ref()
      put_busy(:downloading, %{task_pid: pid, task_ref: ref})

      send(Sync, {:DOWN, ref, :process, pid, :normal})

      refute_receive {:fide_sync, _}, 100
      assert raw_state().status == :downloading
    end
  end

  describe "watchdog" do
    test "firing while busy kills the task, fails the sync, and returns to a recoverable state" do
      pid = alive_dummy()
      put_busy(:downloading, %{task_pid: pid, task_ref: make_ref()})

      send(Sync, :watchdog_timeout)

      assert_receive {:fide_sync, %Sync{status: :error} = state}
      assert state.error =~ "stalled with no progress"
      assert state.task_pid == nil

      # Give the kill signal a moment to land.
      refute Process.alive?(pid)
    end

    test "firing while idle is a no-op" do
      put_busy(:idle)

      send(Sync, :watchdog_timeout)

      refute_receive {:fide_sync, _}, 100
      assert raw_state().status == :idle
    end
  end

  describe "cancel_sync/0" do
    test "kills the running task and resets to :idle" do
      pid = alive_dummy()
      put_busy(:importing, %{task_pid: pid, task_ref: make_ref()})

      Sync.cancel_sync()

      assert_receive {:fide_sync, %Sync{status: :idle} = state}
      assert state.task_pid == nil
      refute Process.alive?(pid)
    end

    test "is a no-op when nothing is running" do
      put_busy(:idle)

      Sync.cancel_sync()

      refute_receive {:fide_sync, _}, 100
      assert raw_state().status == :idle
    end
  end

  describe "start_sync/0 guarding" do
    test "does nothing while a sync is already in progress" do
      put_busy(:downloading, %{progress: "Downloading rating list… 3.0 of 41.0 MB"})

      Sync.start_sync()

      refute_receive {:fide_sync, _}, 100
      assert raw_state().progress == "Downloading rating list… 3.0 of 41.0 MB"
    end
  end
end
