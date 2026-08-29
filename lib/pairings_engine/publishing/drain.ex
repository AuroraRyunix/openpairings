defmodule PairingsEngine.Publishing.Drain do
  @moduledoc """
  Sends queued publishes on a timer.

  A deliberately dull process. It wakes up, asks
  `PairingsEngine.Publishing.drain/0` to send whatever is due, and goes back
  to sleep. All of the interesting behaviour - what is due, what the backoff
  is, what an error says - lives in the context, where it can be tested
  without a running process.

  ## Why a timer rather than a reaction

  Publishing is not urgent. Nothing in the hall waits on it, and the page it
  feeds is meant to be cached hard. A timer collapses a burst of writes -
  eight results entered in a minute - into one send, which is exactly what
  the whole-document snapshot wants. Reacting to each write would send eight
  nearly-identical documents and put the arbiter's flaky wifi in the path of
  every keystroke.

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

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Runs a drain immediately, for the 'Publish now' path and for tests."
  def drain_now, do: GenServer.call(__MODULE__, :drain, 30_000)

  @impl true
  def init(opts) do
    interval =
      Keyword.get_lazy(opts, :interval, fn ->
        Application.get_env(:pairings_engine, :publishing_drain_interval, @interval)
      end)

    {:ok, %{interval: interval}, {:continue, :schedule}}
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
    {:noreply, state}
  end

  @impl true
  def handle_call(:drain, _from, state) do
    {:reply, run(), state}
  end

  defp run do
    {sent, failed} = Publishing.drain()

    if sent > 0 or failed > 0 do
      Logger.info("OpenResults publish: #{sent} sent, #{failed} failed")
    end

    {sent, failed}
  end

  defp schedule(interval), do: Process.send_after(self(), :drain, interval)
end
