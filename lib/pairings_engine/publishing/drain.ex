defmodule PairingsEngine.Publishing.Drain do
  @moduledoc """
  Sends queued publishes on a timer.

  A deliberately dull process. It wakes up, asks
  `PairingsEngine.Publishing.drain/0` to send whatever is due, and goes back
  to sleep. All of the interesting behaviour - what is due, what the backoff
  is, what an error says - lives in the context, where it can be tested
  without a running process.

  ## A timer, plus a debounced nudge

  Publishing is not urgent - nothing in the hall waits on it, and the page it
  feeds is meant to be cached hard - but "not urgent" stopped meaning
  "invisible" the day a top-bar pill started sitting amber for however long a
  publish takes to go out. Waiting out this whole timer's period for
  something that already happened was a cost nobody meant to pay just for
  having a visible indicator.

  So every successful `Publishing.enqueue/1` and `enqueue_id/1` also calls
  `nudge/0`, which schedules a one-off drain `@nudge_delay` out instead of
  waiting for the next tick. It is deliberately NOT "react to every write":
  a further nudge while one is already scheduled changes nothing, so eight
  results entered in a minute still collapse into one send, which is exactly
  what the whole-document snapshot wants. Reacting unconditionally to each
  write would send eight nearly-identical documents and put the arbiter's
  flaky wifi in the path of every keystroke - the nudge keeps that property
  and just shortens the common case (one write, then quiet) from "up to 30
  seconds" to "a couple of seconds".

  The 30-second timer keeps running underneath it, unchanged, and is what
  actually retries a publish that failed: nothing enqueues again for a
  tournament already sitting in backoff, so nothing nudges, and the tick is
  the only thing that ever comes back for it.

  The nudge is a cast, never a call: `enqueue_id/1` runs on every write the
  application makes, and blocking that on this process - even for the
  length of a healthy round trip - would be a bigger cost than the wait it
  replaces.

  ## Failures are not this process's business

  `drain/0` never raises, and a publish that fails is an ordinary outcome
  recorded on its queue row. So there is nothing here to supervise around:
  the process does not crash when the network is down, because the network
  being down is the normal case this whole mechanism exists for.
  """
  use GenServer

  alias PairingsEngine.Publishing

  require Logger

  # Long enough to collapse a burst of result entry into one send; short
  # enough that a spectator refreshing after a round is announced sees it.
  @interval :timer.seconds(30)

  # How long a nudge waits before it drains - long enough to collapse a
  # burst of enqueues (pairing a round can touch every tournament in it)
  # into one send; short enough that the top-bar pill is not what made the
  # 30-second timer's period visible for the first time.
  @nudge_delay :timer.seconds(2)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Runs a drain immediately, for the 'Publish now' path and for tests."
  def drain_now, do: GenServer.call(__MODULE__, :drain, 30_000)

  @doc """
  Asks for a drain soon, without blocking the caller.

  Fire-and-forget and debounced: repeated calls while one is already
  scheduled change nothing, so a burst of enqueues collapses into one
  scheduled drain rather than one HTTP round trip per tournament. See the
  moduledoc for how this and the 30-second timer divide the work.

  Safe to call whether or not this process is up. `enqueue_id/1` runs on
  every write the application makes and must never raise just because the
  drain happened to be between a crash and its restart.
  """
  def nudge do
    GenServer.cast(__MODULE__, :nudge)
  rescue
    # `GenServer.cast/2` on an atom is a plain `send/2` under the hood, and
    # sending to a name nothing has registered raises rather than dropping
    # the message quietly - unlike sending to a pid, which is silent. That
    # is the one way this can fail, and it must fail as silently as the pid
    # case would.
    ArgumentError -> :ok
  end

  @impl true
  def init(opts) do
    interval =
      Keyword.get_lazy(opts, :interval, fn ->
        Application.get_env(:pairings_engine, :publishing_drain_interval, @interval)
      end)

    nudge_delay = Keyword.get(opts, :nudge_delay, @nudge_delay)

    {:ok, %{interval: interval, nudge_delay: nudge_delay, nudge_timer: nil},
     {:continue, :schedule}}
  end

  # `:disabled` starts the process without a timer, which is what the test
  # environment wants: this is the only worker in the tree that schedules
  # work in `init`, and a drain firing mid-test would query the database from
  # a process that does not own the sandbox connection. The process still
  # starts, so `drain_now/0` works and nothing has to special-case its
  # absence.
  @impl true
  def handle_continue(:schedule, %{interval: :disabled} = state), do: {:noreply, state}

  def handle_continue(:schedule, state) do
    # Before the first tick, not on every one: see `Publishing.backfill/0` for
    # why this is a boot-time reconciliation rather than a poll.
    Publishing.backfill()
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:drain, state) do
    run()
    schedule(state.interval)
    {:noreply, clear_nudge(state)}
  end

  # Guards `:disabled` too, even though `handle_cast(:nudge, ...)` already
  # refuses to schedule this while disabled and so should never send it: a
  # timer already in flight the moment something disables this process (only
  # tests do that, via `:sys.replace_state/2`) must not go on to touch the
  # database just because the message it scheduled was already in the
  # mailbox. Cheap to guard twice, expensive to be wrong once.
  def handle_info(:nudge_fire, %{interval: :disabled} = state) do
    {:noreply, %{state | nudge_timer: nil}}
  end

  # The debounce window elapsed with nobody having asked for another one.
  # Deliberately does not call `schedule/1` - that is the periodic timer's
  # job alone, and letting a nudge touch it would mean a busy hall could
  # keep pushing the 30-second backstop further out for as long as writes
  # kept coming.
  def handle_info(:nudge_fire, state) do
    run()
    {:noreply, %{state | nudge_timer: nil}}
  end

  @impl true
  def handle_call(:drain, _from, state) do
    {:reply, run(), clear_nudge(state)}
  end

  # `:disabled` is what `config/test.exs` sets: no timer ever gets armed in
  # `init/1`, and a nudge must honour the same rule - a scheduled drain
  # firing mid-test would query the database from a process that does not
  # own the sandbox connection, exactly as a live periodic tick would.
  @impl true
  def handle_cast(:nudge, %{interval: :disabled} = state), do: {:noreply, state}

  # Already have one scheduled. A second, third or hundredth nudge before it
  # fires changes nothing about when it will - that is the whole debounce.
  def handle_cast(:nudge, %{nudge_timer: ref} = state) when is_reference(ref) do
    {:noreply, state}
  end

  def handle_cast(:nudge, state) do
    timer = Process.send_after(self(), :nudge_fire, state.nudge_delay)
    {:noreply, %{state | nudge_timer: timer}}
  end

  defp run do
    {sent, failed} = Publishing.drain()

    if sent > 0 or failed > 0 do
      Logger.info("OpenResults publish: #{sent} sent, #{failed} failed")
    end

    {sent, failed}
  end

  defp schedule(interval), do: Process.send_after(self(), :drain, interval)

  # A drain that already ran - the periodic tick, or a manual `drain_now/0`
  # - makes a pending nudge redundant. Cancelling it is not required for
  # correctness (an extra `run/0` finding nothing due is harmless) but there
  # is no reason to leave a stray timer message coming for no purpose.
  defp clear_nudge(%{nudge_timer: nil} = state), do: state

  defp clear_nudge(%{nudge_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | nudge_timer: nil}
  end
end
