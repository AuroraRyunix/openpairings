defmodule PairingsEngine.Tools.Session do
  @moduledoc """
  In-memory-only store backing the public, no-login arbiter tools at
  `/tools/norms` (see docs/tools.md) - the parsed tournaments an arbiter has
  uploaded there, keyed by a random token embedded in that page's download
  links (`GET /tools/download/:token/:form`, `PairingsEngineWeb.ToolsController`).

  Deliberately **not** `PairingsEngine.Repo`-backed: nothing an arbiter drops
  on this page - the uploaded file's parsed tournament/players, the
  chief-arbiter/organizer overrides, the FA1/IA1 candidate - is ever written
  to the database or to disk. It lives only in this process's ETS table, and
  is gone within an hour whether or not anyone comes back for it.

  ## Design

  A single `GenServer` owns a `:public` ETS table (`read_concurrency` +
  `write_concurrency`) so that `PairingsEngineWeb.ToolsController` - a
  different process from the `PairingsEngineWeb.ToolsNormsLive` that filled
  it in - can `get/1` straight from the table with no message pass through
  this server; the server itself only exists to own the table (so it isn't
  tied to whichever process happened to create it first) and to run the
  periodic expiry sweep.

  ## Expiry

  Every `put/1,2,3` stamps the entry with an absolute expiry (default one
  hour from now - see `@default_ttl_ms`), refreshed on every subsequent
  `put/2` for that token (a sliding TTL: touching a session - adding a file,
  editing the officials fields - keeps it alive another hour). Expiry is
  enforced two ways: lazily, on every `get/1` (an expired-but-not-yet-swept
  entry is deleted and treated as a miss), and by a periodic sweep
  (`@sweep_interval_ms`) that walks the table and deletes anything already
  past its expiry - a backstop for entries nobody ever calls `get/1` on
  again, so memory doesn't grow unbounded across many abandoned sessions.
  """

  use GenServer

  @table __MODULE__
  @default_ttl_ms :timer.hours(1)
  @sweep_interval_ms :timer.minutes(5)
  # Hard ceiling on live entries. This store backs an UNAUTHENTICATED upload
  # page (`/tools/norms`), so without a cap a flood of parallel uploads could
  # pin unbounded parsed-tournament data in memory for the full hour-long TTL.
  # A few hundred concurrent arbiter sessions is already far beyond any real
  # use; past this, the soonest-to-expire (oldest) entries are evicted to make
  # room, so a fresh upload always succeeds while total memory stays bounded.
  @max_entries 500
  # ...and a ceiling on how much those entries may *weigh*. Counting entries
  # alone was the wrong unit: one session can hold ten 5 MB uploads (see
  # `PairingsEngineWeb.ToolsNormsLive`), so 500 of them is gigabytes of parsed
  # tournament pinned for the full hour by anyone, with no login. Eviction
  # walks soonest-to-expire first for both limits, and always leaves at least
  # one entry, so a single oversized upload still works instead of evicting
  # itself and 404ing its own download link.
  @max_bytes 100_000_000

  defp max_entries,
    do: Application.get_env(:pairings_engine, :tools_session_max_entries, @max_entries)

  defp max_bytes, do: Application.get_env(:pairings_engine, :tools_session_max_bytes, @max_bytes)

  ## ---------- public API ----------

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Stores `data` under a fresh random token (see `token/0`). Returns the token."
  def put(data), do: put(token(), data)

  @doc """
  Upserts `data` under `token`, refreshing its TTL to `ttl_ms` (default one
  hour) from now. Returns `token` (so callers can chain a first `put/2` the
  same way `put/2` on an existing token reads).
  """
  def put(token, data, ttl_ms \\ @default_ttl_ms) do
    :ets.insert(@table, {token, data, expires_at(ttl_ms), :erlang.external_size(data)})
    enforce_cap()
    token
  end

  @doc "Fetches the data stored under `token`. `:error` if unknown or expired."
  def get(token) do
    case :ets.lookup(@table, token) do
      [{^token, data, expires_at, _bytes}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, data}
        else
          :ets.delete(@table, token)
          :error
        end

      [] ->
        :error
    end
  end

  @doc "Removes `token`, if present. Always returns `:ok`."
  def delete(token) do
    :ets.delete(@table, token)
    :ok
  end

  @doc "A fresh random URL-safe token - 24 bytes, same shape as a tournament's `public_slug`."
  def token, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

  ## ---------- GenServer ----------

  @impl true
  def init(:ok) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  defp sweep do
    now = System.monotonic_time(:millisecond)
    # {token, data, expires_at, bytes} - delete every row already expired.
    # `=<` (not `<`) so the boundary agrees with `get/1`'s `now < expires_at`
    # liveness check: an entry expiring this exact millisecond is expired
    # both ways.
    :ets.select_delete(@table, [{{:_, :_, :"$1", :_}, [{:"=<", :"$1", now}], [true]}])
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  # Keep the table at or below `@max_entries` AND `@max_bytes` by evicting the
  # soonest-to-expire (effectively oldest) rows first. Runs after every
  # `put/3`; a no-op in the overwhelmingly common case where the table is
  # under both. Any process may call this - the table is `:public` - and
  # concurrent callers only ever over-delete already-doomed rows, never
  # live-and-under-cap data.
  defp enforce_cap do
    if over_limit?() do
      @table
      |> :ets.tab2list()
      |> Enum.sort_by(fn {_token, _data, expires_at, _bytes} -> expires_at end)
      |> evict_until_within_limits()
    end

    :ok
  end

  defp over_limit? do
    :ets.info(@table, :size) > max_entries() or total_bytes() > max_bytes()
  end

  defp total_bytes do
    :ets.foldl(fn {_token, _data, _expires_at, bytes}, acc -> acc + bytes end, 0, @table)
  end

  # Walks oldest-first, dropping rows until both limits are satisfied. The
  # last remaining row is never evicted: a single upload larger than the whole
  # budget should still be usable by the person who just made it, and evicting
  # it would only break their download link without freeing anything for
  # anyone else.
  defp evict_until_within_limits(rows) do
    total = Enum.reduce(rows, 0, fn {_t, _d, _e, bytes}, acc -> acc + bytes end)
    {max_entries, max_bytes} = {max_entries(), max_bytes()}

    Enum.reduce(rows, {length(rows), total}, fn {token, _data, _expires, bytes}, {count, sum} ->
      if count > 1 and (count > max_entries or sum > max_bytes) do
        :ets.delete(@table, token)
        {count - 1, sum - bytes}
      else
        {count, sum}
      end
    end)

    :ok
  end

  defp expires_at(ttl_ms), do: System.monotonic_time(:millisecond) + ttl_ms
end
