defmodule PairingsEngine.Updates.Checker do
  @moduledoc """
  Runs `PairingsEngine.Updates.check/0` on a timer and caches what it finds,
  so every page can show the notice for free.

  Same shape as `PairingsEngine.Publishing.Monitor` and deliberately so: the
  top bar reads this on every page render, and a `GenServer.call` there
  would put this process in the path of all of them. An `:ets` read touches
  no process, cannot block, and answers before anything has subscribed.

  ## Always supervised, idle everywhere but a desktop install

  Same reasoning as `PairingsEngine.Federations.BEL.Sync` in
  `PairingsEngine.Application`: a conditional child would turn every read of
  `current/0` into a "not running" branch every caller has to handle, for a
  process that costs nothing idle. So this is always in the supervision
  tree, and idleness is enforced at the one place that matters -
  `handle_continue/2` below never schedules a check at all unless
  `PairingsEngine.Updates.eligible?/0` says this is a desktop install. A
  hosted server therefore never sends itself so much as a `:check` message,
  which is a stronger guarantee than "the check function happens to no-op".

  ## Why the first check is soon, not in six hours

  An arbiter who has had this installed for months should not have to wait
  six hours after their next boot to hear about a release that shipped
  yesterday. A short delay rather than immediately, so it does not compete
  with the rest of application start.
  """
  use GenServer

  alias PairingsEngine.Updates

  @topic "system:updates"
  @table :update_notice

  @interval :timer.hours(6)
  @first_check :timer.seconds(10)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "PubSub topic carrying `{:update_notice, %{version:, tag:, url:} | nil}`."
  def topic, do: @topic

  @doc """
  The newest release known to be newer than this build, or `nil` - either
  because nothing has been checked yet, the last check found nothing newer,
  or the last check failed silently. All three look the same from here on
  purpose: a caller does not get to distinguish "not eligible to check" from
  "checked and there is nothing", and none of them is an error to show.
  """
  def current do
    case :ets.lookup(@table, :notice) do
      [{:notice, notice}] -> notice
      [] -> nil
    end
  rescue
    # The table does not exist until `init/1` has run, and a page can render
    # before then (or in a test that never started this process).
    ArgumentError -> nil
  end

  @doc """
  Runs a check right now, in the CALLING process rather than via a message
  to this GenServer - for tests.

  Deliberately NOT a `GenServer.call`. The same arrangement
  `PairingsEngine.Publishing.Drain`'s and `PairingsEngine.Fide.Sync`'s tests
  use, and for the same reason: a `Req.Test` stub and an
  `Ecto.Adapters.SQL.Sandbox` connection (`PairingsEngine.Updates.enabled?/0`
  reads `meta`) are each owned by whichever process calls them, and this
  process is a singleton started once for the whole test suite. Running the
  check here means the caller's own test process - already the owner of
  both - rather than needing `Req.Test.allow/3` and `Sandbox.allow/3` to
  reach a process that outlives any one test.
  """
  def check_now, do: run()

  @impl true
  def init(opts) do
    ensure_table()

    interval =
      Keyword.get_lazy(opts, :interval, fn ->
        Application.get_env(:pairings_engine, :updates_check_interval, @interval)
      end)

    {:ok, %{interval: interval}, {:continue, :schedule}}
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      _existing -> :ok
    end
  end

  # `:disabled` is the test environment's way of switching every timer off
  # in this app (see `PairingsEngine.Backup.Scheduler`, `Publishing.Monitor`)
  # - a tick firing mid-test would make a real request from a process no
  # test owns. `check_now/0` still works, so a test that wants a real run
  # asks for one explicitly.
  @impl true
  def handle_continue(:schedule, %{interval: :disabled} = state), do: {:noreply, state}

  # The only place eligibility is checked ONCE rather than on every tick -
  # deliberately: it is a boot-time property (`PairingsEngine.Authz.local_mode?/0`
  # never changes while the node is up), and a hosted server that never
  # schedules a first `:check` never schedules a second one either. `run/0`
  # still re-checks it (and the enabled setting, which CAN change) before
  # doing anything - see its comment.
  def handle_continue(:schedule, state) do
    if Updates.eligible?() do
      Process.send_after(self(), :check, @first_check)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:check, state) do
    run()
    Process.send_after(self(), :check, state.interval)
    {:noreply, state}
  end

  # Re-checks both eligibility and the setting, even though `eligible?/0` is
  # already implied by this process ever having scheduled a `:check` at all -
  # belt and braces on the property that matters most in this whole feature
  # (a hosted server must never contact GitHub), and the setting can flip
  # between two ticks six hours apart, which `handle_continue/2` cannot see.
  defp run do
    if Updates.eligible?() and Updates.enabled?() do
      case Updates.check() do
        {:ok, info} -> put(info)
        :no_update -> put(nil)
        :error -> :ok
      end
    end
  end

  # Written every successful check, broadcast only when the answer actually
  # changed - so a page that has been open for a week is not re-rendered
  # every six hours to show the exact same banner.
  defp put(notice) do
    previous = current()
    :ets.insert(@table, {:notice, notice})

    if notice != previous do
      Phoenix.PubSub.broadcast(PairingsEngine.PubSub, @topic, {:update_notice, notice})
    end
  end
end
