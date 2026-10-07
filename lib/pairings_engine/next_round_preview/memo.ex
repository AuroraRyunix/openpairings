defmodule PairingsEngine.NextRoundPreview.Memo do
  @moduledoc """
  Every outcome the next-round preview has paired, remembered, so that a
  result entered for one of the open games costs no pairing at all.

  An outcome's pairing depends on two things: everything the pairing reads
  except the results of the round being played - the players, the earlier
  rounds, the byes, the settings, the forbidden pairings - and the results
  of that round's boards. `PairingsEngine.NextRoundPreview.base_state/2`
  splits the data that way: a `base` digest of the first, and the round's
  results as a map. An outcome is stored under its `base` and the digest of
  its full set of results (`key/1`), so:

    * a result entered for an open game: the new preview's outcomes are a
      subset of the old ones - every one is found here;
    * a result cleared: the outcomes in which that game keeps its old
      result are found, only the others are paired;
    * anything else changed - a player, a decided board's result, a
      setting, a forbidden pairing, an absence: a new `base`, or keys never
      seen, and every outcome is paired again.

  Content-addressed, so a stored outcome is never stale: nothing has to be
  invalidated, only evicted. Bounded: at most `@bases_per_tournament`
  bases per tournament (the oldest dropped first), `@max_outcomes` outcomes
  per base, and `@max_tournaments` tournaments. Outcomes are kept as
  compressed binaries, each distinct pairing once - most outcomes of a
  round share their pairing with others. Lost on a restart, which costs
  one full run.

  One ETS table owned by this process; reads go straight to the table,
  writes through the process.
  """

  use GenServer

  @table __MODULE__
  @bases_per_tournament 3
  # 3^7: a full run at the cap (729 outcomes) plus room for the outcomes
  # a cleared result adds.
  @max_outcomes 2_187
  @max_tournaments 32

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The digest an outcome is stored under: its round's full set of results."
  def key(results) when is_map(results), do: digest(results)

  @doc false
  def digest(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))

  @doc """
  The stored outcomes among `keys` for `base`: `%{key => outcome}`, the
  keys not found left out.
  """
  def fetch(tournament_id, base, keys) do
    {found, _decoded} =
      Enum.reduce(keys, {%{}, %{}}, fn key, {found, decoded} ->
        case :ets.lookup(@table, {:outcome, tournament_id, base, key}) do
          [{_, pairing}] ->
            {outcome, decoded} = decode(tournament_id, base, pairing, decoded)
            {if(outcome, do: Map.put(found, key, outcome), else: found), decoded}

          [] ->
            {found, decoded}
        end
      end)

    if found != %{}, do: touch(tournament_id, base)
    found
  rescue
    ArgumentError -> %{}
  end

  defp decode(tournament_id, base, pairing, decoded) do
    case Map.fetch(decoded, pairing) do
      {:ok, outcome} ->
        {outcome, decoded}

      :error ->
        case :ets.lookup(@table, {:pairing, tournament_id, base, pairing}) do
          [{_, blob}] ->
            outcome = :erlang.binary_to_term(blob)
            {outcome, Map.put(decoded, pairing, outcome)}

          [] ->
            {nil, decoded}
        end
    end
  end

  @doc """
  Stores `outcomes` - `[{key, outcome}]` - for `base`. Encoded here, in the
  caller, so only binaries travel to the table's owner.
  """
  def store(_tournament_id, _base, []), do: :ok

  def store(tournament_id, base, outcomes) do
    encoded =
      Enum.map(outcomes, fn {key, outcome} ->
        blob = :erlang.term_to_binary(outcome, [:compressed])
        {key, :crypto.hash(:sha256, blob), blob}
      end)

    GenServer.call(__MODULE__, {:store, tournament_id, base, encoded})
  catch
    :exit, _ -> :ok
  end

  @doc "How many outcomes are stored for `tournament_id` and `base`."
  def size(tournament_id, base) do
    :ets.select_count(@table, [{{{:outcome, tournament_id, base, :_}, :_}, [], [true]}])
  rescue
    ArgumentError -> 0
  end

  @doc "Forgets everything. For tests."
  def clear do
    GenServer.call(__MODULE__, :clear)
  catch
    :exit, _ -> :ok
  end

  defp touch(tournament_id, base) do
    GenServer.cast(__MODULE__, {:touch, tournament_id, base})
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_call({:store, tournament_id, base, encoded}, _from, state) do
    bases = bases(tournament_id)
    known? = List.keymember?(bases, base, 0)
    stored = if known?, do: size(tournament_id, base), else: 0

    # A base that would grow past the bound starts again from this run.
    if stored + length(encoded) > @max_outcomes, do: drop_base(tournament_id, base)

    for {key, pairing, blob} <- Enum.take(encoded, @max_outcomes) do
      :ets.insert(@table, {{:pairing, tournament_id, base, pairing}, blob})
      :ets.insert(@table, {{:outcome, tournament_id, base, key}, pairing})
    end

    put_bases(tournament_id, [{base, now()} | List.keydelete(bases, base, 0)])
    evict_tournaments()
    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:touch, tournament_id, base}, state) do
    bases = bases(tournament_id)

    if List.keymember?(bases, base, 0),
      do: put_bases(tournament_id, [{base, now()} | List.keydelete(bases, base, 0)])

    {:noreply, state}
  end

  defp bases(tournament_id) do
    case :ets.lookup(@table, {:bases, tournament_id}) do
      [{_, bases}] -> bases
      [] -> []
    end
  end

  # Newest first; the ones past the bound are dropped with their outcomes.
  defp put_bases(tournament_id, bases) do
    bases = Enum.sort_by(bases, &elem(&1, 1), :desc)
    {kept, dropped} = Enum.split(bases, @bases_per_tournament)
    Enum.each(dropped, fn {base, _at} -> drop_base(tournament_id, base) end)
    :ets.insert(@table, {{:bases, tournament_id}, kept})
  end

  defp drop_base(tournament_id, base) do
    :ets.match_delete(@table, {{:outcome, tournament_id, base, :_}, :_})
    :ets.match_delete(@table, {{:pairing, tournament_id, base, :_}, :_})
  end

  defp evict_tournaments do
    tournaments = :ets.match(@table, {{:bases, :"$1"}, :"$2"})

    if length(tournaments) > @max_tournaments do
      tournaments
      |> Enum.map(fn [id, bases] ->
        {id, bases |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)}
      end)
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.take(length(tournaments) - @max_tournaments)
      |> Enum.each(fn {id, _at} ->
        :ets.match_delete(@table, {{:outcome, id, :_, :_}, :_})
        :ets.match_delete(@table, {{:pairing, id, :_, :_}, :_})
        :ets.delete(@table, {:bases, id})
      end)
    end
  end

  defp now, do: System.monotonic_time()
end
