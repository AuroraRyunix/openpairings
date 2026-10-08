defmodule PairingsEngine.ManualRoundRobin do
  @moduledoc """
  What a round-robin round paired by hand breaks (VCL4THP Q100-Q102).

  A round robin is normally its Berger table, paired whole in one click
  (`PairingsEngine.RoundRobin`). A round can instead be created empty and
  paired by hand, and any round can be edited by hand - both inside the
  manual pairing alteration Swiss uses (`PairingsEngine.ManualPairing`),
  where the "pairing checker" is the table's own round. This module holds
  the round-robin rules the hand-made boards are judged against:

    * **Everyone meets everyone exactly once per cycle (Q101).** A pair
      that already met in another round of the same cycle is a repeat
      (`:rr_repeat`). When the session finishes, the whole cycle is
      checked: the pairs still to meet must split into exactly the rounds
      the cycle has left (`:rr_incomplete` when they cannot). An odd field
      counts the round's bye as a game against a phantom player, as the
      table does - one bye per player per cycle.
    * **No three same colours in a row (Q102).** A player given the same
      colour in three consecutive rounds (`:rr_colour_three`). The checklist
      asks it of a double round robin not paired from the table; it is
      asked of every round-robin round paired by hand here, since the
      table never does it within a cycle and a hand easily does.

  Neither is refused: like every hand-edit warning, they are listed in the
  edit's confirmation and need an explicit tick (Level 3), and the round
  that differs from the table is recorded as an MPA PIBE.

  The completion check is exact - it searches for the remaining rounds -
  but within a step budget: a search that runs out of it (a large field
  whose degrees all fit, but whose factorisation is slow to find) passes
  rather than raising a false alarm.
  """

  import Ecto.Query

  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.{Repo, RoundRobin}
  alias PairingsEngine.Tournaments.{Round, Tournament}

  @budget 50_000

  @doc """
  The breaches among `boards` - `{white_id, black_id}` per board,
  `{player_id, nil}` for a player who sits out - in round `round_number` of
  `t`, judged against every other round already paired. Maps with a
  `:kind` (`:rr_repeat` with the `:round` they met, `:rr_colour_three` with
  the `:colour`, `:rr_outside` for a player who is not in the table,
  `:rr_incomplete` with the `:cycle`) and the `:players` (ids) concerned.

  With `complete: true` (`boards` being the whole round) the cycle's
  completion is checked as well.
  """
  def warnings(%Tournament{} = t, round_number, boards, opts \\ []) do
    frozen = t.id |> Engine.full_roster_players() |> Enum.map(& &1.id)

    if length(frozen) < 2 do
      []
    else
      do_warnings(t, frozen, round_number, boards, opts)
    end
  end

  defp do_warnings(t, frozen, round_number, boards, opts) do
    cycle_len = RoundRobin.total_rounds(length(frozen), 1)
    cycle = div(round_number - 1, cycle_len)
    span = (cycle * cycle_len + 1)..(cycle * cycle_len + cycle_len)
    others = other_rounds(t.id, round_number)
    in_cycle = Enum.filter(others, fn {number, _pairs} -> number in span end)
    frozen_set = MapSet.new(frozen)
    pairs = for {w, b} <- boards, is_integer(w) and is_integer(b), do: {w, b}

    met =
      for {number, round_pairs} <- in_cycle, {a, b} <- round_pairs, into: %{} do
        {key(a, b), number}
      end

    outside =
      for {w, b} <- boards,
          id <- [w, b],
          is_integer(id),
          not MapSet.member?(frozen_set, id),
          uniq: true,
          do: %{kind: :rr_outside, players: [id]}

    repeats =
      for {w, b} <- pairs, number = Map.get(met, key(w, b)), number != nil do
        %{kind: :rr_repeat, players: [w, b], round: number}
      end

    incomplete =
      if Keyword.get(opts, :complete, false),
        do: completion(frozen, cycle_len, cycle, in_cycle, pairs),
        else: []

    Enum.concat([outside, repeats, colours(others, round_number, pairs), incomplete])
  end

  @doc """
  The first pair round `number` of the table (`table`, as
  `RoundRobin.table_round/2` gives it) would pair a second time in its
  cycle, given the rounds already paired: `{a, b, round_they_met}`, or nil.
  """
  def table_conflict(%Tournament{} = t, number, table) do
    cycle_len = RoundRobin.total_rounds(length(Engine.full_roster_players(t.id)), 1)
    cycle = div(number - 1, cycle_len)
    span = (cycle * cycle_len + 1)..(cycle * cycle_len + cycle_len)

    met =
      for {n, pairs} <- other_rounds(t.id, number), n in span, {a, b} <- pairs, into: %{} do
        {key(a, b), n}
      end

    Enum.find_value(table, fn
      {a, b} when is_integer(b) ->
        case Map.get(met, key(a, b)) do
          nil -> nil
          n -> {a, b, n}
        end

      _bye ->
        nil
    end)
  end

  # Every round of the tournament but `except`, as `{number, [{white, black}]}`.
  defp other_rounds(tournament_id, except) do
    from(r in Round,
      where: r.tournament_id == ^tournament_id and r.number != ^except,
      order_by: r.number,
      preload: :pairings
    )
    |> Repo.all()
    |> Enum.map(fn round ->
      {round.number,
       for(
         p <- round.pairings,
         is_integer(p.white_player_id) and is_integer(p.black_player_id),
         do: {p.white_player_id, p.black_player_id}
       )}
    end)
  end

  defp key(a, b), do: if(a < b, do: {a, b}, else: {b, a})

  ## ---------- three same colours in a row (Q102) ----------

  defp colours(others, round_number, pairs) do
    by_round =
      Map.new(others, fn {number, round_pairs} ->
        {number,
         Enum.reduce(round_pairs, %{}, fn {w, b}, acc ->
           acc |> Map.put(w, "w") |> Map.put(b, "b")
         end)}
      end)

    Enum.flat_map(pairs, fn {w, b} ->
      Enum.flat_map([{w, "w"}, {b, "b"}], fn {id, colour} ->
        at = fn n ->
          if n == round_number, do: colour, else: by_round |> Map.get(n, %{}) |> Map.get(id)
        end

        three? =
          Enum.any?((round_number - 2)..round_number, fn start ->
            Enum.all?(start..(start + 2), &(at.(&1) == colour))
          end)

        if three?, do: [%{kind: :rr_colour_three, players: [id], colour: colour}], else: []
      end)
    end)
  end

  ## ---------- everyone meets everyone once per cycle (Q101) ----------

  # The pairs of the cycle still to meet must split into exactly the rounds
  # the cycle has left - a 1-factorisation of what remains, with a phantom
  # opponent standing for the bye on an odd field.
  defp completion(frozen, cycle_len, cycle, in_cycle, pairs) do
    phantom? = rem(length(frozen), 2) == 1
    vertices = if phantom?, do: frozen ++ [:phantom], else: frozen
    rounds = Enum.map(in_cycle, &elem(&1, 1)) ++ [pairs]
    left = cycle_len - length(rounds)

    used =
      for round_pairs <- rounds,
          edge <- round_edges(round_pairs, frozen, phantom?),
          into: MapSet.new() do
        edge
      end

    adjacency =
      Map.new(vertices, fn v ->
        {v,
         for(
           u <- vertices,
           u != v,
           not MapSet.member?(used, key(u, v)),
           into: MapSet.new(),
           do: u
         )}
      end)

    off = for {v, near} <- adjacency, MapSet.size(near) != left, is_integer(v), do: v

    cond do
      left < 0 or off != [] or
          Enum.any?(adjacency, fn {_v, near} -> MapSet.size(near) != left end) ->
        [%{kind: :rr_incomplete, players: Enum.sort(off), cycle: cycle + 1}]

      left == 0 ->
        []

      match?({:fail, _}, factorise(adjacency, left, @budget)) ->
        [%{kind: :rr_incomplete, players: [], cycle: cycle + 1}]

      true ->
        []
    end
  end

  # A round's games, plus a game against the phantom for each player of the
  # table it leaves out (the bye) on an odd field.
  defp round_edges(round_pairs, frozen, phantom?) do
    frozen_set = MapSet.new(frozen)

    games =
      for {a, b} <- round_pairs,
          MapSet.member?(frozen_set, a) and MapSet.member?(frozen_set, b),
          do: key(a, b)

    seated = round_pairs |> Enum.flat_map(&Tuple.to_list/1) |> MapSet.new()

    byes =
      if phantom?,
        do: for(p <- frozen, not MapSet.member?(seated, p), do: key(p, :phantom)),
        else: []

    games ++ byes
  end

  # `{:ok, budget}`, `{:fail, budget}` or `:exhausted`: whether `adjacency`
  # (every vertex of degree `rounds`) splits into `rounds` perfect matchings.
  defp factorise(_adjacency, 0, budget), do: {:ok, budget}

  defp factorise(adjacency, rounds, budget) do
    adjacency |> Map.keys() |> match(adjacency, [], rounds, budget)
  end

  defp match(_free, _adjacency, _chosen, _rounds, budget) when budget <= 0, do: :exhausted

  defp match([], adjacency, chosen, rounds, budget) do
    rest =
      Enum.reduce(chosen, adjacency, fn {a, b}, acc ->
        acc
        |> Map.update!(a, &MapSet.delete(&1, b))
        |> Map.update!(b, &MapSet.delete(&1, a))
      end)

    factorise(rest, rounds - 1, budget)
  end

  defp match(free, adjacency, chosen, rounds, budget) do
    free_set = MapSet.new(free)

    # The most constrained vertex first.
    {v, candidates} =
      free
      |> Enum.map(fn v -> {v, adjacency |> Map.fetch!(v) |> MapSet.intersection(free_set)} end)
      |> Enum.min_by(fn {_v, near} -> MapSet.size(near) end)

    rest = List.delete(free, v)

    Enum.reduce_while(Enum.sort(candidates), {:fail, budget - 1}, fn u, {:fail, left} ->
      case match(List.delete(rest, u), adjacency, [{v, u} | chosen], rounds, left) do
        {:ok, _} = found -> {:halt, found}
        {:fail, after_try} -> {:cont, {:fail, after_try - 1}}
        :exhausted -> {:halt, :exhausted}
      end
    end)
  end
end
