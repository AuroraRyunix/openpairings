defmodule PairingsEngine.TieLots do
  @moduledoc """
  A simulated drawing of lots for players still level after every tie-break
  (C.07 Article 4.2; VCL4THP Q204-Q206).

  The arbiter draws; the program puts the players of each tied place in a
  random order and records it as the tournament's manual ranking
  (`PairingsEngine.Tournaments.enable_manual_ranking/1`'s mechanism), so the
  order is what the standings, the print and the TRF then say.

  **Drawing again gives the same result.** The checklist says that a draw
  that gives something different when repeated lets the arbiter repeat it
  until it pleases. The order is therefore a function of the players and of
  `tournaments.lots_seed`, a number drawn once from the operating system's
  random source the first time lots are drawn and kept: the same ties
  always come out in the same order. Players who join a tie later, or ties
  that appear because a result changed, are ordered by the same seed.

  Only players level after the whole tie-break list are reordered; everyone
  else keeps the order the standings gave. Not offered for Keizer or team
  tournaments (they have no manual ranking of individuals).
  """

  import Ecto.Query

  alias PairingsEngine.{Repo, Standings, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  @doc """
  The tied groups of `entries` (`Standings.standings/1` output): every list
  of two or more entries sharing a place, in standing order.
  """
  def tied_groups(entries) do
    entries
    |> Enum.group_by(&Standings.place/1)
    |> Enum.filter(fn {_place, group} -> length(group) > 1 end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_place, group} -> Enum.sort_by(group, & &1.rank) end)
  end

  @doc "How many players of `entries` are level with somebody after every tie-break."
  def tied_count(entries), do: entries |> tied_groups() |> List.flatten() |> length()

  @doc """
  Draws lots for every tied group of `tournament` and records the result as
  its manual ranking. `{:ok, %{players: n, groups: m, tournament: t}}`, or
  `{:error, :no_ties | :not_supported | :archived | :handed_off}`.
  """
  def draw(%Tournament{} = tournament) do
    with :ok <- Tournaments.ensure_writable(tournament),
         :ok <- supported(tournament) do
      entries = Standings.standings(tournament)

      case tied_groups(entries) do
        [] ->
          {:error, :no_ties}

        groups ->
          seed = seed(tournament)
          tied_ids = groups |> List.flatten() |> MapSet.new(& &1.player.id)

          order =
            entries
            |> Enum.chunk_by(&(MapSet.member?(tied_ids, &1.player.id) and Standings.place(&1)))
            |> Enum.flat_map(&order_chunk(&1, tied_ids, seed))

          write(tournament, order)

          {:ok,
           %{
             players: MapSet.size(tied_ids),
             groups: length(groups),
             tournament: Tournaments.get_tournament!(tournament.id)
           }}
      end
    end
  end

  defp supported(%Tournament{pairing_system: "keizer"}), do: {:error, :not_supported}

  defp supported(%Tournament{} = t),
    do: if(Tournament.paired_as_teams?(t), do: {:error, :not_supported}, else: :ok)

  # A run of entries sharing a tied place is put in the drawn order; any other
  # entry (one place of its own) stays where it is. `chunk_by` keys an untied
  # entry `false`, so a run of untied neighbours is one chunk: kept as it is.
  defp order_chunk([first | _] = chunk, tied_ids, seed) do
    if MapSet.member?(tied_ids, first.player.id) and length(chunk) > 1,
      do: Enum.sort_by(chunk, &lot(seed, &1.player.id)),
      else: chunk
  end

  defp lot(seed, player_id),
    do: :crypto.hash(:sha256, <<seed::signed-64, player_id::signed-64>>)

  defp seed(%Tournament{lots_seed: seed}) when is_integer(seed), do: seed

  defp seed(%Tournament{id: id}) do
    # Set once, never replaced: the repeat of a draw must give the same order.
    candidate = :crypto.strong_rand_bytes(6) |> :binary.decode_unsigned()

    Repo.update_all(from(t in Tournament, where: t.id == ^id and is_nil(t.lots_seed)),
      set: [lots_seed: candidate]
    )

    Repo.one!(from t in Tournament, where: t.id == ^id, select: t.lots_seed)
  end

  defp write(tournament, order) do
    Repo.transaction(fn ->
      Repo.update_all(from(t in Tournament, where: t.id == ^tournament.id),
        set: [manual_ranking: true, manual_ranking_stale: false]
      )

      order
      |> Enum.with_index(1)
      |> Enum.each(fn {entry, rank} ->
        Repo.update_all(from(p in Player, where: p.id == ^entry.player.id),
          set: [manual_rank: rank]
        )
      end)
    end)

    Tournaments.broadcast_tournament_change(tournament.id, :players)
    :ok
  end
end
