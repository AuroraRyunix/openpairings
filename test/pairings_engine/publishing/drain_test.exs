defmodule PairingsEngine.Publishing.DrainTest do
  @moduledoc """
  The debounced nudge, and how it stays out of the 30-second timer's way.

  Drain is a singleton GenServer started by the application supervisor, so
  the wiring tests below mutate its shared state via `:sys` rather than spin
  up an isolated instance - the same arrangement
  `test/pairings_engine/fide/sync_test.exs` uses for the same reason, and
  they never let a real timer fire: this process runs with
  `interval: :disabled` for the whole suite (`config/test.exs`), and a test
  that left it otherwise would risk a later, unrelated test's assertions
  racing a stray drain.

  The debounce logic itself is instead exercised by calling `handle_cast/2`
  and `handle_info/2` directly. That keeps `Process.send_after`'s timer and
  `Publishing.drain/0`'s database and HTTP calls inside the *test's own*
  process - the one that already owns this test's sandboxed connection and
  `Req.Test` stub - so nothing here needs `Sandbox.allow/3` or
  `Req.Test.allow/3` to reach either.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Publishing, Repo}
  alias PairingsEngine.Publishing.Drain
  alias PairingsEngine.Tournaments.Tournament

  setup do
    Publishing.put_endpoint("https://openresults.example/")
    Publishing.put_token("s3cret")
    reset_singleton()
    on_exit(&reset_singleton/0)
    :ok
  end

  # Always restores `interval: :disabled` - what `config/test.exs` starts
  # this process with - and cancels any timer a test armed along the way, so
  # a failed assertion mid-test can never leak a live nudge into whatever
  # test happens to run next.
  defp reset_singleton do
    :sys.replace_state(Drain, fn state ->
      case state.nudge_timer do
        ref when is_reference(ref) -> Process.cancel_timer(ref)
        nil -> :ok
      end

      %{state | interval: :disabled, nudge_delay: :timer.seconds(2), nudge_timer: nil}
    end)
  end

  defp singleton_state, do: :sys.get_state(Drain)

  defp stub(fun), do: Req.Test.stub(PairingsEngine.PublishingTest, fun)

  defp tournament(opts \\ []) do
    Repo.insert!(%Tournament{
      name: "Gent Spring Open",
      type: "swiss",
      rounds_count: 3,
      publish_to_openresults: Keyword.get(opts, :publish, true),
      public_slug: "gent-#{System.unique_integer([:positive])}"
    })
  end

  describe "the real singleton, exactly as it boots in test" do
    test "enqueue reaches it, but interval: :disabled makes the nudge inert" do
      t = tournament()

      assert :ok = Publishing.enqueue(t)
      # No sleep needed: `enqueue/1`'s cast and this `:sys` call are both
      # sent from this same process, so Erlang delivers them to Drain in
      # that order and it has already handled the cast by the time it can
      # answer this.
      assert singleton_state().nudge_timer == nil

      assert Publishing.queued(t.id)
    end

    test "enqueue_id/1 reaches it the same way" do
      t = tournament()

      assert :ok = Publishing.enqueue_id(t.id)
      assert singleton_state().nudge_timer == nil
    end

    test "a tournament that has not opted in neither queues nor nudges" do
      t = tournament(publish: false)

      assert :ok = Publishing.enqueue(t)

      refute Publishing.queued(t.id)
      assert singleton_state().nudge_timer == nil
    end

    test "the wiring really does call nudge/0 - it schedules once the process is not disabled" do
      # Proves enqueue calls Drain.nudge/0 without ever letting the timer
      # fire: an hour cannot elapse inside a test, and `reset_singleton/0`
      # (setup's `on_exit`) cancels the pending timer regardless.
      :sys.replace_state(Drain, fn state ->
        %{state | interval: :timer.hours(1), nudge_delay: :timer.hours(1)}
      end)

      t = tournament()
      Publishing.enqueue(t)

      assert is_reference(singleton_state().nudge_timer)
    end
  end

  describe "the debounce state machine, driven directly" do
    setup do
      %{state: %{interval: :timer.hours(1), nudge_delay: 5, nudge_timer: nil}}
    end

    test "a nudge schedules exactly one fire", %{state: state} do
      {:noreply, state} = Drain.handle_cast(:nudge, state)

      assert is_reference(state.nudge_timer)
      assert_receive :nudge_fire, 200
    end

    test "a second nudge while one is already pending changes nothing", %{state: state} do
      {:noreply, state1} = Drain.handle_cast(:nudge, state)
      {:noreply, state2} = Drain.handle_cast(:nudge, state1)
      {:noreply, state3} = Drain.handle_cast(:nudge, state2)

      assert state3.nudge_timer == state1.nudge_timer
    end

    test "once it fires, a further nudge schedules again" do
      state = %{interval: :timer.hours(1), nudge_delay: 5, nudge_timer: nil}

      {:noreply, state} = Drain.handle_cast(:nudge, state)
      first = state.nudge_timer
      assert_receive :nudge_fire, 200

      {:noreply, state} = Drain.handle_info(:nudge_fire, state)
      assert state.nudge_timer == nil

      {:noreply, state} = Drain.handle_cast(:nudge, state)
      assert is_reference(state.nudge_timer)
      assert state.nudge_timer != first
    end

    test "disabled means the cast is a no-op, timer and all" do
      state = %{interval: :disabled, nudge_delay: 5, nudge_timer: nil}

      {:noreply, state} = Drain.handle_cast(:nudge, state)

      assert state.nudge_timer == nil
      refute_receive :nudge_fire, 50
    end

    test "a fire that arrives after the process went disabled still does not drain", %{
      state: state
    } do
      # Not reachable through normal operation - `handle_cast` never
      # schedules while disabled - but a test flipping the flag mid-flight
      # (or a boundary this code cannot see) must not reach the database.
      t = tournament()
      Publishing.enqueue(t)
      stub(fn _conn -> flunk("nothing should have been sent") end)

      {:noreply, state} = Drain.handle_cast(:nudge, state)
      disabled = %{state | interval: :disabled}

      {:noreply, result} = Drain.handle_info(:nudge_fire, disabled)

      assert result.nudge_timer == nil
      assert Publishing.queued(t.id)
    end

    test "the fire runs a real drain and clears the pending timer", %{state: state} do
      t = tournament()
      Publishing.enqueue(t)
      stub(fn conn -> Req.Test.json(conn, %{"ok" => true}) end)

      {:noreply, state} = Drain.handle_cast(:nudge, state)
      assert is_reference(state.nudge_timer)

      {:noreply, state} = Drain.handle_info(:nudge_fire, state)

      assert state.nudge_timer == nil
      refute Publishing.queued(t.id)
    end

    test "a failed send during the fire still clears the pending timer, for the backstop to retry",
         %{state: state} do
      t = tournament()
      Publishing.enqueue(t)
      stub(fn conn -> Plug.Conn.send_resp(conn, 500, "nope") end)

      {:noreply, state} = Drain.handle_cast(:nudge, state)
      {:noreply, state} = Drain.handle_info(:nudge_fire, state)

      assert state.nudge_timer == nil
      # Still queued, now backed off - the 30-second timer is what comes
      # back for this, not another nudge.
      entry = Publishing.queued(t.id)
      assert entry
      assert entry.attempts == 1
    end
  end

  describe "the periodic tick and a manual drain" do
    test "handle_info(:drain, ...) cancels a pending nudge rather than leaving it stray" do
      state = %{interval: :timer.hours(1), nudge_delay: :timer.hours(1), nudge_timer: nil}
      {:noreply, state} = Drain.handle_cast(:nudge, state)
      assert is_reference(state.nudge_timer)

      {:noreply, state} = Drain.handle_info(:drain, state)

      assert state.nudge_timer == nil
    end

    test "handle_call(:drain, ...) does the same, and still returns the real result" do
      state = %{interval: :timer.hours(1), nudge_delay: :timer.hours(1), nudge_timer: nil}
      {:noreply, state} = Drain.handle_cast(:nudge, state)

      {:reply, {sent, failed}, state} = Drain.handle_call(:drain, self(), state)

      assert {sent, failed} == {0, 0}
      assert state.nudge_timer == nil
    end
  end
end
