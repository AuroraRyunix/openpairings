defmodule PairingsEngine.NextRoundPreview.Cache do
  @moduledoc """
  The latest finished next-round preview per tournament, with the
  `PairingsEngine.NextRoundPreview.fingerprint/1` of the data it was worked
  out from.

  A preview of a large field takes minutes, so it is worked out once, on
  the Pairings page, and kept here: the print view prints what is stored
  when the fingerprint still matches and says it is out of date otherwise,
  and a second arbiter opening the preview gets it at once. A stale entry
  is never read - the fingerprint moves with every result, withdrawal and
  setting - so nothing has to be invalidated.

  One ETS table owned by this process; at most `@max_tournaments` entries,
  the oldest dropped first. Lost on a restart, which costs one
  recomputation.
  """

  use GenServer

  @table __MODULE__
  @max_tournaments 32

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The stored preview for `tournament_id` if it was worked out from `fingerprint`."
  def get(tournament_id, fingerprint) do
    case :ets.lookup(@table, tournament_id) do
      [{^tournament_id, ^fingerprint, preview, _at}] when not is_nil(fingerprint) -> preview
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Stores `preview` for `tournament_id`, replacing whatever was there."
  def put(tournament_id, fingerprint, preview) do
    GenServer.call(__MODULE__, {:put, tournament_id, fingerprint, preview})
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_call({:put, id, fingerprint, preview}, _from, state) do
    :ets.insert(@table, {id, fingerprint, preview, System.monotonic_time()})

    if :ets.info(@table, :size) > @max_tournaments do
      {oldest, _at} =
        :ets.foldl(
          fn {key, _f, _p, at}, acc ->
            if acc == nil or at < elem(acc, 1), do: {key, at}, else: acc
          end,
          nil,
          @table
        )

      :ets.delete(@table, oldest)
    end

    {:reply, :ok, state}
  end
end
