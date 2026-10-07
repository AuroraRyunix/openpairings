defmodule PairingsEngine.Tpn do
  @moduledoc """
  A Swiss tournament's pairing numbers (TPNs) changed by the arbiter without
  touching a rating: a TPN exchange between players of equal rating, and a
  TPN regeneration from the current ratings.

  FIDE's handling rules for Swiss tournaments (C.04.2) number the players by
  rating, then title, then name, and let the numbers be corrected - for a
  mistake or a rating change - only until the fourth round is paired. The
  rating order cannot cover every tie a competition's rules may break
  differently, so the verification checklist wants a manual order for
  equal ratings (VCL4THP Q147), an exchange only among players whose
  tournament rating is the same (Q148), a regeneration before round 4
  (Q153) that keeps the order the arbiter gave equal ratings (Q155), each
  confirmed by the arbiter (Q150, Q154; the TEC manual's Level 3), and
  neither after round 4 is paired (Q151).

  ## The numbers

  The numbers are `players.pairing_number`, issued at round 1
  (`Pairing.ensure_pairing_numbers/2`). Exchanging before round 1 issues
  them first, in the order round 1 would (`Pairing.initial_order/1`), and a
  player entered after that is placed by rating when round 1 is paired
  (`seed_newcomers/2`), never simply last. Once a round exists, a later
  entry is numbered last as it always was, and a regeneration places them.

  ## A regeneration

  Everybody numbered, and every active player still without a number, is
  sorted by rating, highest first; players of equal rating keep the order
  they had (their current numbers, newcomers after them by name), so an
  exchange the arbiter made between equal ratings survives (Q155). Then
  numbered 1..N.

  Both write the numbers only, never a rating, a result or a round; the
  rounds already paired keep their games, which are the players', not the
  numbers'.
  """

  import Ecto.Query

  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  # C.04.2: TPNs may be corrected only before the fourth round is paired.
  @last_round_before_lock 3

  @doc "Whether TPN exchange and regeneration are this tournament's at all: an individual Swiss."
  def applies?(%Tournament{} = t), do: t.pairing_system == "swiss" and not Tournament.team?(t)

  @doc "Whether they can be used now: an individual Swiss with fewer than four rounds paired."
  def editable?(%Tournament{} = t),
    do: applies?(t) and Engine.paired_rounds_count(t.id) <= @last_round_before_lock

  @doc """
  The numbering as it stands, `[{player, number}]` in number order: the
  numbers issued, then - while round 1 is not paired - the active players
  without one placed where round 1 will place them; once a round exists, a
  late entry without a number is listed last, as the next pairing numbers
  them. Before anything is issued, the order round 1 would issue.
  """
  def order(%Tournament{} = t) do
    players = Tournaments.list_players(t.id)
    active_ids = MapSet.new(Engine.active_players(t.id), & &1.id)
    before_round_one? = Engine.paired_rounds_count(t.id) == 0

    # Everybody who holds a number keeps a place, whatever their status now,
    # as the pairing and the public snapshot both treat a number once issued.
    numbered = players |> Enum.filter(&is_integer(&1.pairing_number)) |> sort_by_number()

    newcomers =
      players
      |> Enum.filter(&(is_nil(&1.pairing_number) and MapSet.member?(active_ids, &1.id)))
      |> Engine.initial_order(t)

    if before_round_one?,
      do: Enum.with_index(merge(numbered, newcomers, t), 1),
      else: Enum.zip(numbered ++ newcomers, numbers(numbered, newcomers))
  end

  defp numbers(numbered, newcomers) do
    highest = numbered |> Enum.map(& &1.pairing_number) |> Enum.max(fn -> 0 end)

    Enum.map(numbered, & &1.pairing_number) ++
      Enum.to_list((highest + 1)..(highest + length(newcomers))//1)
  end

  @doc """
  Round 1's numbering of a field some of which already has numbers: the
  newcomers (`players` without a number) are placed by rating among the
  numbered ones, whose order is kept, and everyone is numbered 1..N.
  Called by the Swiss pairing before round 1 instead of numbering the
  newcomers last. Returns `:seeded` when it wrote numbers, else `:none`.
  """
  def seed_newcomers(%Tournament{} = t, players) do
    if Enum.any?(players, &is_nil(&1.pairing_number)) and
         Enum.any?(Tournaments.list_players(t.id), &is_integer(&1.pairing_number)) do
      write(t, Enum.map(order(t), fn {p, _n} -> p.id end))
      :seeded
    else
      :none
    end
  end

  @doc """
  Exchanges the numbers of two players of the same tournament rating (both
  unrated counts as the same). Before round 1 the numbers are issued first.
  Refused: `{:error, :different_ratings}`, `{:error, :locked}` once round 4
  is paired, `{:error, :not_swiss}`, `{:error, :not_found}`.
  """
  def exchange(%Tournament{} = t, a_id, b_id) do
    with :ok <- guard(t) do
      players = Map.new(order(t), fn {p, _n} -> {p.id, p} end)

      case {Map.get(players, a_id), Map.get(players, b_id)} do
        {%Player{} = a, %Player{} = b} when a_id != b_id ->
          if Player.rating(a, t) == Player.rating(b, t),
            do: do_exchange(t, a, b),
            else: {:error, :different_ratings}

        _ ->
          {:error, :not_found}
      end
    end
  end

  defp do_exchange(t, a, b) do
    ids = Enum.map(order(t), fn {p, _n} -> p.id end)

    swapped =
      Enum.map(ids, fn
        id when id == a.id -> b.id
        id when id == b.id -> a.id
        id -> id
      end)

    write(t, swapped)
    {:ok, order(t)}
  end

  @doc """
  What a regeneration would change, `[{player, old_number, new_number}]` -
  the players whose number moves, in new-number order. `old_number` is nil
  for a player not yet numbered, listed only when their place differs from
  the one they would get anyway; a newcomer simply numbered where they
  belong changes nobody's number and is no Regeneration PIBE (TEC manual).
  """
  def regeneration_changes(%Tournament{} = t) do
    current = order(t)
    current_number = Map.new(current, fn {p, n} -> {p.id, n} end)
    issued = Map.new(Tournaments.list_players(t.id), &{&1.id, &1.pairing_number})

    t
    |> regenerated(current)
    |> Enum.with_index(1)
    |> Enum.reject(fn {p, n} -> issued[p.id] in [nil, n] and current_number[p.id] == n end)
    |> Enum.map(fn {p, n} -> {p, issued[p.id], n} end)
  end

  @doc """
  Regenerates the numbers from the current ratings, keeping the order of
  equal ratings (see the moduledoc). Refused like `exchange/3`.
  """
  def regenerate(%Tournament{} = t) do
    with :ok <- guard(t) do
      write(t, Enum.map(regenerated(t, order(t)), & &1.id))
      {:ok, order(t)}
    end
  end

  defp regenerated(t, current) do
    current
    |> Enum.sort_by(fn {p, n} -> {-Player.rating(p, t), n} end)
    |> Enum.map(fn {p, _n} -> p end)
  end

  # Numbered players kept in order; each newcomer goes before the first
  # numbered player rated below them.
  defp merge([], newcomers, _t), do: newcomers
  defp merge(numbered, [], _t), do: numbered

  defp merge([n | ns] = numbered, [c | cs] = newcomers, t) do
    if Player.rating(n, t) >= Player.rating(c, t),
      do: [n | merge(ns, newcomers, t)],
      else: [c | merge(numbered, cs, t)]
  end

  defp sort_by_number(players), do: Enum.sort_by(players, &{&1.pairing_number, &1.name, &1.id})

  defp write(t, ids) do
    Repo.transaction(fn ->
      ids
      |> Enum.with_index(1)
      |> Enum.each(fn {id, number} ->
        Repo.update_all(
          from(p in Player, where: p.id == ^id and p.tournament_id == ^t.id),
          set: [pairing_number: number]
        )
      end)
    end)

    Tournaments.broadcast_tournament_change(t.id, :players)
  end

  defp guard(t) do
    cond do
      refusal = Tournaments.write_refused(t.id) -> refusal
      not applies?(t) -> {:error, :not_swiss}
      not editable?(t) -> {:error, :locked}
      true -> :ok
    end
  end
end
