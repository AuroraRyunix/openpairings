defmodule PairingsEngine.Publishing.Monitor do
  @moduledoc """
  One poller, so every page can show the publishing state for free.

  ## Why this exists

  The indicator belongs in the top bar, where an arbiter sees it without
  going to look for it. That is exactly what makes it expensive:
  `Publishing.status/0` is an HTTP round trip with a fifteen-second timeout,
  and the top bar renders on every page of every session. Calling it there
  would mean one network request per page view per arbiter, and a settings
  page that takes fifteen seconds to appear whenever the results site is
  down - which is the moment somebody most wants to look at it.

  So it is polled once, here, and everything else reads a cached value that
  costs nothing.

  ## Two intervals, because the two halves are not alike

  **The queue depth** is a local `COUNT` against SQLite. It is cheap and it
  is the half that actually moves - an arbiter enters the last result of a
  round and wants to see something happen - so it is checked every few
  seconds.

  **The connection** is a network round trip that changes rarely: a results
  site that answered thirty seconds ago will almost certainly answer now.
  Polling it as often as the queue would be a request every few seconds,
  forever, from every installation, to say "still fine".

  ## Broadcast only on change

  A message per tick would wake every connected LiveView twenty times a
  minute to re-render an identical top bar. Subscribers hear from this only
  when the state, the queue depth, the latency band or the last-sent stamp
  actually differ.

  ## A light that says "now" is not enough

  The indicator answers "can this machine publish, right now". The failure
  it is worst at describing is the intermittent one: a hall's wifi that
  drops for fifteen seconds every few minutes shows green almost every time
  somebody looks, and the arbiter is left with results that arrive late for
  no visible reason.

  So the last twenty connection checks are kept - at one every thirty
  seconds, that is the last ten minutes - and the panel can say whether it
  has been steady, rather than only what it is at this instant.

  Kept in the process rather than the table: it is written once per check
  and read only when somebody opens the panel, so there is no reason for
  every page render to carry it.

  ## It never lets the caller wait

  The network check runs in a task, and its result arrives as a message. A
  poller that blocked in `handle_info` would make `status/0` - which every
  page calls - queue behind a fifteen-second timeout, reintroducing the
  freeze this exists to prevent, one level down.
  """
  use GenServer

  alias PairingsEngine.Publishing

  require Logger

  @topic "publishing:status"

  @queue_interval :timer.seconds(3)
  @connection_interval :timer.seconds(30)

  def topic, do: @topic

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @table :publishing_status

  @doc """
  The last known publishing state, or `nil` before the first check lands.

  `nil` is a real answer and callers must render it as one - see
  `PairingsEngineWeb.Components.ConnectionStatus`, which says "checking"
  rather than guessing green and correcting itself a second later.

  ## Why a table and not a `GenServer.call`

  The top bar reads this on **every render of every page**. A call would put
  this process in the path of all of them: fine while it is idle, and a
  queue behind a fifteen-second network check the moment it is not - which
  is precisely when every page would be trying to render the indicator
  saying so.

  An `:ets` read touches no process at all, cannot block, and answers during
  a dead render before any of this is subscribed. It also gives tests a
  seam: seed the table and render, with no poller and no network.
  """
  def status do
    case :ets.lookup(@table, :status) do
      [{:status, status}] -> status
      [] -> nil
    end
  rescue
    # The table does not exist until the Monitor starts, and a page must
    # render before then. Never let a status read take a page down: the
    # indicator is a convenience, the tournament is not.
    ArgumentError -> nil
  end

  @doc """
  Seeds the cache. For the Monitor itself, and for tests that need a state
  without a poller.
  """
  def put_status(status) do
    ensure_table()
    :ets.insert(@table, {:status, status})
    Phoenix.PubSub.broadcast(PairingsEngine.PubSub, @topic, {:publish_status, status})
    status
  end

  @doc """
  Forgets the cached state, so the next read answers `nil` again.

  For tests. A cache that outlived the test that seeded it would leak a
  publishing state into every later test's top bar.
  """
  def clear do
    ensure_table()
    :ets.delete(@table, :status)
    :ok
  end

  defp ensure_table do
    :ets.info(@table) == :undefined && :ets.new(@table, [:named_table, :public, :set])
  rescue
    ArgumentError -> :ok
  end

  @doc "Forces a connection check now, for a page that has just changed the settings."
  def refresh, do: send(__MODULE__, :check_connection)

  @impl true
  def init(_opts) do
    # Owned by this process, so it goes when the process does - but public,
    # because every page render reads it and none of them should have to
    # talk to a process to do so.
    # Tolerates one already being there. The table is owned by this process,
    # so an orderly stop takes it with them - but a crash-and-restart under
    # the supervisor can race its own predecessor's cleanup, and a Monitor
    # that refuses to start because the last one has not finished dying
    # would take the indicator down for good over a transient.
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      _existing -> :ok
    end

    intervals =
      Application.get_env(:pairings_engine, :publishing_monitor_interval, {
        @queue_interval,
        @connection_interval
      })

    {:ok,
     %{
       intervals: intervals,
       history: [],
       # Since this PROCESS started, which is not the same as uptime and is
       # never presented as though it were. See `stability/0`.
       started_at: DateTime.utc_now(),
       last_failure_at: nil
     }, {:continue, :schedule}}
  end

  # Disabled in test for the reason `Publishing.Drain` is: a tick firing
  # mid-test queries the database from a process that does not own the
  # sandbox connection. The process still starts, so `status/0` answers and
  # nothing has to special-case its absence.
  @impl true
  def handle_continue(:schedule, %{intervals: :disabled} = state), do: {:noreply, state}

  def handle_continue(:schedule, state) do
    send(self(), :check_connection)
    send(self(), :check_queue)
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_queue, state) do
    schedule(:check_queue, elem(state.intervals, 0))

    # Only the cheap half. Re-reading the connection here would defeat the
    # whole point of splitting them.
    case status() do
      nil -> :ok
      current -> put(%{current | pending: Publishing.pending_count()})
    end

    {:noreply, state}
  end

  def handle_info(:check_connection, state) do
    schedule(:check_connection, elem(state.intervals, 1))

    parent = self()

    Task.Supervisor.start_child(PairingsEngine.TaskSupervisor, fn ->
      status =
        try do
          Publishing.status()
        rescue
          error ->
            Logger.warning("Publishing status check failed: #{Exception.message(error)}")
            nil
        catch
          _, _ -> nil
        end

      if status, do: send(parent, {:connection, status})
    end)

    {:noreply, state}
  end

  def handle_info({:connection, status}, state) do
    put(status)

    state = %{
      state
      | history: record(state.history, status),
        last_failure_at:
          if(status.state == :connected, do: state.last_failure_at, else: DateTime.utc_now())
    }

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  What the last ten minutes of connection checks looked like, or `nil` when
  there have not been enough to say anything.

  `%{samples:, minutes:, failures:, worst_ms:, since:, last_failure_at:}`.
  Deliberately nil rather than an empty summary for the first few minutes
  after a restart: "steady for the last 10 minutes" is a claim, and a
  process that has been up for ninety seconds is not entitled to make it.

  ## Why there is no uptime percentage here

  A "99.9%" would be dishonest twice over.

  It could not measure what the number implies: when this app is down
  nothing polls, so the checks that would have failed are the ones that
  never happen. Anything computed from them describes how reachable the
  RESULTS SITE was during the moments this app was alive - not uptime of
  anything, and flattering by construction.

  And a percentage hides the shape that matters. 99.9% over a week is one
  ten-minute outage, which is fine on a Tuesday and ruinous during round
  four. "3 checks failed in the last 10 minutes" and "last drop 2 hours
  ago" say the thing a percentage averages away.

  Real uptime needs something outside this machine watching it. That is a
  monitor's job, not this app's, and claiming otherwise here would put a
  reassuring number where a true one belongs.
  """
  def stability do
    GenServer.call(__MODULE__, :stability)
  catch
    # The Monitor is not started in test and can be restarting in prod. A
    # panel must render without it.
    :exit, _ -> nil
  end

  @impl true
  def handle_call(:stability, _from, state),
    do: {:reply, summarise(state.history, state), state}

  # Newest first, capped. Twenty checks at one every thirty seconds is ten
  # minutes; the cap is in SAMPLES rather than by timestamp so a paused
  # laptop that wakes up does not report a ten-minute window it slept
  # through.
  @history 20

  defp record(history, status) do
    [{status.state, status.latency_ms} | history] |> Enum.take(@history)
  end

  # Fewer than four checks is two minutes of evidence, which is not a window.
  defp summarise(history, _state) when length(history) < 4, do: nil

  defp summarise(history, state) do
    latencies = for {_st, ms} <- history, is_integer(ms), do: ms

    %{
      samples: length(history),
      minutes: div(length(history) * 30, 60),
      failures: Enum.count(history, fn {st, _ms} -> st != :connected end),
      worst_ms: Enum.max(latencies, fn -> nil end),
      # Named `since` rather than `uptime`: it is when this process started,
      # so a deploy or a crash resets it. The wording that reaches the screen
      # says so.
      since: state.started_at,
      last_failure_at: state.last_failure_at
    }
  end

  # Written on every tick, broadcast only on a real change: the table read is
  # what pages use, and a message per tick would wake every connected
  # LiveView twenty times a minute to re-render an identical top bar.
  defp put(status) do
    previous = status()
    :ets.insert(@table, {:status, status})

    if changed?(previous, status) do
      Phoenix.PubSub.broadcast(PairingsEngine.PubSub, @topic, {:publish_status, status})
    end

    status
  end

  # Latency is compared in bands rather than exactly. It is a network
  # measurement, so it differs by a millisecond or two on every single check,
  # and comparing it raw would make "broadcast only on change" mean
  # "broadcast every time".
  defp changed?(nil, _new), do: true

  defp changed?(old, new) do
    {old.state, old.pending, old.last_published_at, band(old.latency_ms)} !=
      {new.state, new.pending, new.last_published_at, band(new.latency_ms)}
  end

  defp band(nil), do: nil
  defp band(ms) when ms < 100, do: div(ms, 10)
  defp band(ms), do: div(ms, 100) * 10

  defp schedule(message, interval), do: Process.send_after(self(), message, interval)
end
