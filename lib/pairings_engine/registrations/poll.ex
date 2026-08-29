defmodule PairingsEngine.Registrations.Poll do
  @moduledoc """
  Fetches entries from the results site on a timer.

  The same deliberately dull shape as `PairingsEngine.Publishing.Drain`: wake
  up, ask the context to do the work, go back to sleep. Everything
  interesting - which tournaments, what a failure means - lives in
  `PairingsEngine.Registrations.poll/0`, where it can be tested without a
  running process.

  ## Why this exists

  Pulling used to be a button. That was defensible while the arbiter also
  served the entry form: they were in the app, the entries were on the same
  machine, and the button was a refresh. It stopped being defensible when the
  form moved to the results site, because the entries then lived somewhere
  the arbiter had no view of at all. A queue nobody is told about is a queue
  that gets discovered on the morning of the tournament.

  The button is still there, and still says what it said - somebody standing
  at the door with a queue in front of them should not have to wait out a
  timer.

  ## What this is NOT

  Accepting. Nothing here adds a player to anything. Entries land in the
  review list marked "not yet arrived" and stay there until an arbiter
  decides, which is the whole model: a web form is a paper form left on a
  table, and a stranger filling one in has announced an intention rather than
  entered a tournament.

  ## The interval

  A minute. Nothing waits on an entry the way a hall waits on a pairing, so
  the cost of being a minute late is nil - while a minute is short enough
  that an arbiter watching the Registrations page during a busy sign-up
  window sees the list move without reaching for the button.
  """
  use GenServer

  alias PairingsEngine.{Publishing, Registrations}

  require Logger

  @interval :timer.minutes(1)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Runs a poll immediately, for tests and for a manual refresh."
  def poll_now, do: GenServer.call(__MODULE__, :poll, 60_000)

  @impl true
  def init(opts) do
    interval =
      Keyword.get_lazy(opts, :interval, fn ->
        Application.get_env(:pairings_engine, :registration_poll_interval, @interval)
      end)

    {:ok, %{interval: interval}, {:continue, :schedule}}
  end

  # `:disabled` starts the process without a timer, which is what the test
  # environment wants: a poll firing mid-test would query the database from a
  # process that does not own the sandbox connection. The process still
  # starts, so `poll_now/0` works and nothing has to special-case its
  # absence. Same arrangement as the publish drain.
  @impl true
  def handle_continue(:schedule, %{interval: :disabled} = state), do: {:noreply, state}

  def handle_continue(:schedule, state) do
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    run()
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:poll, _from, state) do
    {:reply, run(), state}
  end

  defp run do
    # Checked here rather than inside `poll/0` so the common case - a laptop
    # that has never been told about a results site - costs nothing at all,
    # not even the query that would find no tournaments.
    if Publishing.configured?() do
      {pulled, new} = Registrations.poll()

      if new > 0 do
        Logger.info("OpenResults registrations: #{new} new across #{pulled} tournament(s)")
      end

      {pulled, new}
    else
      {0, 0}
    end
  end

  defp schedule(interval), do: Process.send_after(self(), :poll, interval)
end
