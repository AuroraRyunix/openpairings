defmodule PairingsEngine.Fide.AutoSync do
  @moduledoc """
  Keeps the local FIDE rating list from falling more than a day behind the
  list FIDE serves, while the program runs.

  Once a day (and on start-up when the last look is more than a day old) it
  asks `PairingsEngine.Fide.Freshness` whether FIDE's list is newer than the
  local one - a single `HEAD` request - and only then starts the ordinary
  `PairingsEngine.Fide.Sync` download. FIDE publishes monthly, so in practice
  that is one 41 MB download a month, not one a day.

  ## Offline, and switching it off

  A desktop install is often offline. A failed look is silent (a log line) and
  retried at the next hourly tick; it is never an error on screen. The whole
  thing is a setting - `enabled?/0`, stored in `meta` as `fide_auto_sync`,
  switched on the Connections page, **on by default** - and
  `config :pairings_engine, :fide_auto_sync, false` (the test and dev setups)
  keeps the process from ever scheduling anything.

  With no list downloaded at all it fetches one, because a program with no
  list is the stalest case there is.
  """
  use GenServer
  require Logger

  alias PairingsEngine.{Fide, Meta}
  alias PairingsEngine.Fide.{Freshness, Sync}

  @setting "fide_auto_sync"
  @checked_key "fide_last_check"
  @day_seconds 24 * 60 * 60
  @first_tick :timer.seconds(45)
  @tick :timer.hours(1)

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Whether the automatic daily update is switched on (default: on)."
  def enabled?, do: Meta.get(@setting) != "off"

  def put_enabled(true), do: Meta.delete(@setting)
  def put_enabled(false), do: Meta.put(@setting, "off")

  @doc """
  Whether a look at FIDE is due: the setting is on and the last successful
  look is more than a day old (or there never was one).
  """
  def due?(now \\ DateTime.utc_now()) do
    enabled?() and
      case Meta.get(@checked_key) do
        nil ->
          true

        value ->
          case DateTime.from_iso8601(value) do
            {:ok, at, _} -> DateTime.diff(now, at) >= @day_seconds
            _ -> true
          end
      end
  end

  @doc """
  One pass: if a look is due, ask FIDE and start the download when it is newer
  (or when there is no list yet). Returns what happened, for tests and logs:
  `:disabled | :not_due | :busy | :current | :updating | :unverified`.
  """
  def run_once(opts \\ []) do
    sync = Keyword.get(opts, :sync, &Sync.start_sync/0)
    busy? = Keyword.get(opts, :busy?, &sync_busy?/0)

    cond do
      not enabled?() ->
        :disabled

      not due?() ->
        :not_due

      busy?.() ->
        :busy

      true ->
        case if(Fide.last_sync() == nil, do: :stale, else: Freshness.check()) do
          :stale ->
            note_checked()
            sync.()
            :updating

          :current ->
            note_checked()
            :current

          :unverified ->
            # The server could not be asked (offline), or does not date its
            # list. Not recorded as a look, so the next tick tries again - a
            # HEAD request is all that costs.
            :unverified
        end
    end
  end

  defp note_checked, do: Meta.put(@checked_key, DateTime.to_iso8601(DateTime.utc_now()))

  defp sync_busy? do
    Sync.status().status in [:downloading, :importing]
  end

  ## GenServer

  @impl true
  def init(opts) do
    if Keyword.get(opts, :auto, auto_configured?()) do
      Process.send_after(self(), :tick, Keyword.get(opts, :first_tick, @first_tick))
    end

    {:ok, %{interval: Keyword.get(opts, :interval, @tick)}}
  end

  @impl true
  def handle_info(:tick, state) do
    try do
      run_once()
    rescue
      e -> Logger.warning("FIDE auto-sync pass failed: #{Exception.message(e)}")
    end

    Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp auto_configured?, do: Application.get_env(:pairings_engine, :fide_auto_sync, true)
end
