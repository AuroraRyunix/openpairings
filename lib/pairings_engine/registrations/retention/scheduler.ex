defmodule PairingsEngine.Registrations.Retention.Scheduler do
  @moduledoc """
  Runs `PairingsEngine.Registrations.Retention` once a day.

  The same shape as `PairingsEngine.Backup.Scheduler`: a plain interval
  rather than a time of day, a first run a little after boot, and failures
  logged rather than raised. The first run is ten minutes in, after the
  backup's five, so the two do not start together.
  """
  use GenServer

  alias PairingsEngine.Registrations.Retention

  require Logger

  @interval :timer.hours(24)
  @first_run :timer.minutes(10)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Runs one now, for tests."
  def run_now, do: GenServer.call(__MODULE__, :run, 120_000)

  @impl true
  def init(opts) do
    interval =
      Keyword.get_lazy(opts, :interval, fn ->
        Application.get_env(:pairings_engine, :registration_retention_interval, @interval)
      end)

    {:ok, %{interval: interval}, {:continue, :schedule}}
  end

  # `:disabled` starts the process without a timer, which is what the test
  # environment wants: a run firing mid-test would write from a process that
  # does not own the sandbox connection. `run_now/0` still works.
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
    cleared = Retention.run()

    if cleared > 0 do
      Logger.info(
        "Registration retention: email cleared on #{cleared} registration(s) " <>
          "of tournaments that ended more than #{Retention.days()} day(s) ago"
      )
    end

    {:ok, cleared}
  rescue
    error ->
      Logger.error("Registration retention FAILED: #{Exception.message(error)}")
      {:error, Exception.message(error)}
  end
end
