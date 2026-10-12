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

  ## Who gets asked

  The setting has three values, `mode/0`: `:auto` (download without asking),
  `:ask` and `:never`. A hosted server defaults to `:auto`, as it always did.
  A desktop install (`PairingsEngine.Authz.local_mode?/0`, the one switch the
  rest of the program reads for "whose laptop is this") defaults to `:ask`,
  because 41 MB on somebody's phone hotspot is the kind of surprise nobody
  puts in a feature list. In `:ask` the daily look still happens - one `HEAD`
  request, a few hundred bytes - but a stale or missing list only raises a
  pending state (`pending/0`), which `PairingsEngineWeb.FideDownloadNotice`
  turns into a banner with three buttons. Nothing is downloaded until a human
  says so. A stored "off" is still `:never`, on either edition.
  """
  use GenServer
  require Logger

  alias PairingsEngine.{Authz, Fide, Meta}
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

  @pending_key "fide_download_pending"
  @snooze_key "fide_ask_snoozed_until"
  @topic "fide_download_notice"

  @type mode :: :auto | :ask | :never

  @doc "PubSub topic carrying `{:fide_download_notice, :changed}`."
  def topic, do: @topic

  @doc """
  What the program does about a missing or newer list: `:auto`, `:ask` or
  `:never`. Nothing stored means `:ask` on a desktop install and `:auto` on a
  hosted one; a stored "off" is `:never` everywhere.
  """
  @spec mode() :: mode()
  def mode do
    case Meta.get(@setting) do
      "off" -> :never
      "ask" -> :ask
      "on" -> :auto
      _ -> if Authz.local_mode?(), do: :ask, else: :auto
    end
  end

  @doc "Whether the daily look at FIDE happens at all (any mode but `:never`)."
  def enabled?, do: mode() != :never

  @doc """
  Whether this machine may fetch the list without a human saying yes: always
  on a hosted server, and on a desktop install only in `:auto`.
  """
  def download_unasked?, do: not Authz.local_mode?() or mode() == :auto

  @doc "Hosted's two-state switch. Desktop uses `put_mode/1`."
  def put_enabled(true), do: put_mode(:auto)
  def put_enabled(false), do: put_mode(:never)

  def put_mode(:never) do
    Meta.put(@setting, "off")
    clear_pending()
  end

  def put_mode(:ask) do
    Meta.put(@setting, "ask")
    notify()
  end

  def put_mode(:auto) do
    # Hosted's default is "nothing stored"; desktop's is "ask", so there
    # "on" has to be written down.
    if Authz.local_mode?(), do: Meta.put(@setting, "on"), else: Meta.delete(@setting)
    clear_pending()
  end

  @doc """
  What the banner has to say, or nil: `:missing` (no list at all) or `:newer`
  (FIDE has a newer one). Only meaningful in `:ask`. The stored marker names
  the local list it was raised against, so a download - from the banner or by
  hand on the Connections page - retires it without anybody remembering to.
  """
  @spec pending() :: :missing | :newer | nil
  def pending do
    local = Fide.last_sync()

    with true <- mode() == :ask,
         marker when is_binary(marker) <- Meta.get(@pending_key),
         true <- marker == (local || "none") do
      if local == nil, do: :missing, else: :newer
    else
      _ -> nil
    end
  end

  @doc "Raises the pending state against the list that is here now."
  def raise_pending do
    Meta.put(@pending_key, Fide.last_sync() || "none")
    notify()
  end

  def clear_pending do
    Meta.delete(@pending_key)
    Meta.delete(@snooze_key)
    notify()
  end

  @doc "\"Later\": the banner stays away for 24 hours, across restarts."
  def snooze(now \\ DateTime.utc_now()) do
    Meta.put(@snooze_key, now |> DateTime.add(@day_seconds) |> DateTime.to_iso8601())
    notify()
  end

  def snoozed?(now \\ DateTime.utc_now()) do
    case Meta.get(@snooze_key) do
      nil ->
        false

      value ->
        case DateTime.from_iso8601(value) do
          {:ok, until, _} -> DateTime.compare(now, until) == :lt
          _ -> false
        end
    end
  end

  @doc """
  The banner's data for `PairingsEngineWeb.FideDownloadNotice`, or nil: a
  desktop install, in `:ask`, with something pending (or a download already
  running on its behalf). A snoozed banner stays hidden until it is not -
  except while a download runs, where hiding progress would be rude.
  """
  def notice do
    status = Sync.status()
    busy? = status.status in [:downloading, :importing]
    kind = pending()

    cond do
      not Authz.local_mode?() -> nil
      kind == nil -> nil
      busy? -> %{kind: kind, busy?: true, status: status}
      snoozed?() -> nil
      true -> %{kind: kind, busy?: false, status: status}
    end
  end

  @doc "Tells every open banner to look again."
  def notify do
    Phoenix.PubSub.broadcast(PairingsEngine.PubSub, @topic, {:fide_download_notice, :changed})
  end

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
  `:disabled | :not_due | :busy | :current | :updating | :pending | :unverified`
  (`:pending` is `:updating` with the question put to a human first).
  """
  def run_once(opts \\ []) do
    sync = Keyword.get(opts, :sync, &Sync.start_sync/0)
    busy? = Keyword.get(opts, :busy?, &sync_busy?/0)

    ask? = Keyword.get_lazy(opts, :ask?, fn -> mode() == :ask end)

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

            if ask? do
              raise_pending()
              :pending
            else
              sync.()
              :updating
            end

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
