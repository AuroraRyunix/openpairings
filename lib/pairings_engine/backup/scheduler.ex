defmodule PairingsEngine.Backup.Scheduler do
  @moduledoc """
  Writes a backup on a timer, and prunes the old ones.

  The same deliberately dull shape as the publish drain and the registration
  poll: wake up, ask the context to do the work, go back to sleep.

  ## Why it runs on a plain interval rather than at a time of day

  Because "02:00" is a promise about a clock this process cannot keep. A
  laptop is asleep at 02:00 and the arbiter using it would get no backups at
  all; a server that reboots at 01:59 would skip the day. An interval since
  the last run works the same on both, and the machine that is on the most
  gets the most backups, which is the machine with the most to lose.

  ## The first one is soon, not in a day

  A fresh install, or one that has just been restarted after a crash, is
  exactly when there is most likely to be nothing on disk. Waiting a full
  interval to find that out is the wrong way round, so the first run is a few
  minutes after boot - late enough not to compete with start-up, early enough
  that a machine switched on for one tournament still gets one.

  ## Failures are logged, never raised

  A backup that cannot be written is a problem for the operator, not a reason
  to take down the app it is protecting. Full disks and unwritable directories
  are the ordinary failures here and neither is worth a crash loop.
  """
  use GenServer

  alias PairingsEngine.Backup

  require Logger

  @interval :timer.hours(24)
  @first_run :timer.minutes(5)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Runs one now, for the button and for tests."
  def run_now, do: GenServer.call(__MODULE__, :run, 120_000)

  @impl true
  def init(opts) do
    interval =
      Keyword.get_lazy(opts, :interval, fn ->
        Application.get_env(:pairings_engine, :backup_interval, @interval)
      end)

    {:ok, %{interval: interval}, {:continue, :schedule}}
  end

  # `:disabled` starts the process without a timer, which is what the test
  # environment wants: this one writes files and copies the whole database, and
  # a run firing mid-test would do both from a process that does not own the
  # sandbox connection. `run_now/0` still works.
  @impl true
  def handle_continue(:schedule, %{interval: :disabled} = state), do: {:noreply, state}

  def handle_continue(:schedule, state) do
    Process.send_after(self(), :run, @first_run)
    {:noreply, state}
  end

  @impl true
  def handle_info(:run, state) do
    run()
    Process.send_after(self(), :run, state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:run, _from, state), do: {:reply, run(), state}

  defp run do
    case Backup.create() do
      {:ok, path} ->
        pruned = Backup.prune()
        size = File.stat!(path).size

        Logger.info(
          "Backup written: #{Path.basename(path)} (#{div(size, 1_000_000)} MB)" <>
            if(pruned > 0, do: ", #{pruned} old one(s) removed", else: "")
        )

        {:ok, path}

      {:error, reason} ->
        # Loud enough to find in a log, quiet enough not to restart anything.
        # An operator whose disk is full needs to read this, not to discover
        # the app is in a crash loop because of the thing meant to protect it.
        Logger.error("Backup FAILED: #{reason}")
        {:error, reason}
    end
  end
end
