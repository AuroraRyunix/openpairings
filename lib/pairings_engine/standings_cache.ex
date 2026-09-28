defmodule PairingsEngine.StandingsCache do
  @moduledoc """
  Computed standings, kept until the data behind them changes.

  `PairingsEngine.Standings` replays every game from scratch on every call,
  on purpose: stored totals are never trusted. That stays true. What this
  adds is that the SAME replay is not done twice for the same data - the
  Standings, Players, Pairings and print pages, the public snapshot and the
  projector all ask for it, often several times per write, and on a
  450-player event each ask was a noticeable fraction of a second on the
  server.

  ## When a cached table is used

  A result is stored under

      {tournament id, data version, fingerprint}

  * the **data version** is `tournaments.data_version`, which database
    triggers change in the same transaction as every insert, update or
    delete of the tournament's players, rounds, pairings and byes (see the
    migration `AddStandingsDataVersion`). Whatever wrote - a page, an
    import, a restore, the pairing engine, a raw `update_all` - the version
    moves with it, and the old entries can never be read again. It is
    random, not a counter, so a rolled-back write cannot bring an old value
    back with other data behind it;
  * the **fingerprint** is a SHA-256 of the `%Tournament{}` struct the
    caller handed in (associations and metadata dropped) together with the
    variant asked for - which function, which round, which options.
    Standings are computed from the struct's settings, not from the row, so
    a settings change, or a caller asking about a struct it changed in
    memory, is a different key.

  So a hit is, by construction, what a fresh computation would return right
  now. `test/pairings_engine/standings_cache_test.exs` checks that claim
  against random sequences of writes.

  ## Bounds

  One ETS table, owned by this process. Per tournament, only the current
  version's entries are kept, at most `:per_tournament` of them (least
  recently used out first); at most `:max_tournaments` tournaments, and at
  most `:max_bytes` in all - the least recently used tournament goes first.
  Defaults are `@defaults` below, overridable with
  `config :pairings_engine, PairingsEngine.StandingsCache, ...`.
  `enabled: false` turns the whole thing off, which is also how the "before"
  numbers in docs/architecture.md were measured.
  """

  use GenServer

  import Ecto.Query

  alias PairingsEngine.Repo

  @table __MODULE__

  @defaults [enabled: true, per_tournament: 24, max_tournaments: 32, max_bytes: 128 * 1024 * 1024]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The cached result of `compute` for `tournament` and `variant`, or
  `compute.()` stored for next time. `compute` must depend on nothing but
  the struct, `variant` and the tournament's players, rounds, pairings and
  byes.
  """
  def fetch(tournament, variant, compute) when is_function(compute, 0) do
    with true <- active?(),
         %{id: id} when is_integer(id) <- tournament,
         version when is_integer(version) <- version(id) do
      key = {id, version, fingerprint(tournament, variant)}

      case lookup(key) do
        {:ok, value} ->
          value

        :miss ->
          value = compute.()
          store(key, value)
          value
      end
    else
      _ -> compute.()
    end
  end

  @doc """
  Runs `fun` with the cache out of the way for this process: every standings
  call inside it is computed afresh and nothing is stored. For tests that
  compare a cached result with a fresh one.
  """
  def bypass(fun) when is_function(fun, 0) do
    previous = Process.put(:standings_cache_bypass, true)

    try do
      fun.()
    after
      if previous,
        do: Process.put(:standings_cache_bypass, previous),
        else: Process.delete(:standings_cache_bypass)
    end
  end

  @doc "The tournament's current data version, or nil when it has none."
  def version(tournament_id) do
    Repo.one(from t in "tournaments", where: t.id == ^tournament_id, select: t.data_version)
  end

  @doc "Drops everything. For tests, and for an operator in a console."
  def clear do
    if table?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  @doc false
  def entries(tournament_id) do
    if table?(),
      do:
        :ets.select(@table, [{{{tournament_id, :"$1", :"$2"}, :_, :_}, [], [{{:"$1", :"$2"}}]}]),
      else: []
  end

  ## ---------- internals ----------

  defp config, do: Keyword.merge(@defaults, Application.get_env(:pairings_engine, __MODULE__, []))

  defp active? do
    Keyword.fetch!(config(), :enabled) and not Process.get(:standings_cache_bypass, false) and
      table?()
  end

  defp table?, do: :ets.whereis(@table) != :undefined

  # Associations can be anything a caller happened to preload, and the
  # metadata says nothing about the settings; neither is part of what the
  # standings are computed from.
  defp fingerprint(tournament, variant) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({settings(tournament), variant}, [:deterministic])
    )
  end

  defp settings(%mod{} = struct) do
    dropped =
      if function_exported?(mod, :__schema__, 1),
        do: [:__meta__ | mod.__schema__(:associations)],
        else: []

    {mod, struct |> Map.from_struct() |> Map.drop(dropped)}
  end

  defp settings(other), do: other

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, _used}] ->
        :ets.update_element(@table, key, {3, now()})
        {:ok, value}

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp store({id, version, _} = key, value) do
    :ets.insert(@table, {key, value, now()})
    GenServer.cast(__MODULE__, {:stored, id, version})
  rescue
    ArgumentError -> :ok
  end

  defp now, do: System.monotonic_time()

  ## ---------- the owner: bounds ----------

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:stored, id, version}, state) do
    cfg = config()

    # Only the version just stored is still readable; anything older for
    # this tournament is dead weight.
    :ets.select_delete(@table, [
      {{{id, :"$1", :_}, :_, :_}, [{:"=/=", :"$1", version}], [true]}
    ])

    trim_tournament(id, Keyword.fetch!(cfg, :per_tournament))
    trim_all(id, Keyword.fetch!(cfg, :max_tournaments), Keyword.fetch!(cfg, :max_bytes))
    {:noreply, state}
  end

  defp trim_tournament(id, limit) do
    keys =
      :ets.select(@table, [
        {{:"$1", :_, :"$2"}, [{:==, {:element, 1, :"$1"}, id}], [{{:"$1", :"$2"}}]}
      ])

    if length(keys) > limit do
      keys
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.take(length(keys) - limit)
      |> Enum.each(fn {key, _} -> :ets.delete(@table, key) end)
    end
  end

  defp trim_all(keep, max_tournaments, max_bytes) do
    by_tournament =
      @table
      |> :ets.select([{{{:"$1", :_, :_}, :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {id, used} -> {id, Enum.max(used)} end)
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    evict(by_tournament -- [keep], length(by_tournament), max_tournaments, max_bytes)
  end

  defp evict([], _count, _max_tournaments, _max_bytes), do: :ok

  defp evict([oldest | rest], count, max_tournaments, max_bytes) do
    if count > max_tournaments or bytes() > max_bytes do
      :ets.select_delete(@table, [{{{oldest, :_, :_}, :_, :_}, [], [true]}])
      evict(rest, count - 1, max_tournaments, max_bytes)
    else
      :ok
    end
  end

  defp bytes, do: :ets.info(@table, :memory) * :erlang.system_info(:wordsize)
end
