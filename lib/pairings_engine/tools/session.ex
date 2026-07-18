defmodule PairingsEngine.Tools.Session do
  @moduledoc """
  In-memory-only store backing the public, no-login arbiter tools at
  `/tools/norms` (see docs/tools.md) — the parsed tournaments an arbiter has
  uploaded there, keyed by a random token embedded in that page's download
  links (`GET /tools/download/:token/:form`, `PairingsEngineWeb.ToolsController`).

  Deliberately **not** `PairingsEngine.Repo`-backed: nothing an arbiter drops
  on this page — the uploaded file's parsed tournament/players, the
  chief-arbiter/organizer overrides, the FA1/IA1 candidate — is ever written
  to the database or to disk. It lives only in this process's ETS table, and
  is gone within an hour whether or not anyone comes back for it.

  ## Design

  A single `GenServer` owns a `:public` ETS table (`read_concurrency` +
  `write_concurrency`) so that `PairingsEngineWeb.ToolsController` — a
  different process from the `PairingsEngineWeb.ToolsNormsLive` that filled
  it in — can `get/1` straight from the table with no message pass through
  this server; the server itself only exists to own the table (so it isn't
  tied to whichever process happened to create it first) and to run the
  periodic expiry sweep.

  ## Expiry

  Every `put/1,2,3` stamps the entry with an absolute expiry (default one
  hour from now — see `@default_ttl_ms`), refreshed on every subsequent
  `put/2` for that token (a sliding TTL: touching a session — adding a file,
  editing the officials fields — keeps it alive another hour). Expiry is
  enforced two ways: lazily, on every `get/1` (an expired-but-not-yet-swept
  entry is deleted and treated as a miss), and by a periodic sweep
  (`@sweep_interval_ms`) that walks the table and deletes anything already
  past its expiry — a backstop for entries nobody ever calls `get/1` on
  again, so memory doesn't grow unbounded across many abandoned sessions.
  """

  use GenServer

  @table __MODULE__
  @default_ttl_ms :timer.hours(1)
  @sweep_interval_ms :timer.minutes(5)

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
    :ets.insert(@table, {token, data, expires_at(ttl_ms)})
    token
  end

  @doc "Fetches the data stored under `token`. `:error` if unknown or expired."
  def get(token) do
    case :ets.lookup(@table, token) do
      [{^token, data, expires_at}] ->
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

  @doc "A fresh random URL-safe token — 24 bytes, same shape as a tournament's `public_slug`."
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
    # {token, data, expires_at} — delete every row already expired. `=<`
    # (not `<`) so the boundary agrees with `get/1`'s `now < expires_at`
    # liveness check: an entry expiring this exact millisecond is expired
    # both ways.
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp expires_at(ttl_ms), do: System.monotonic_time(:millisecond) + ttl_ms
end
