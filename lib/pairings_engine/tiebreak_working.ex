defmodule PairingsEngine.TiebreakWorking do
  @moduledoc """
  How each tiebreak number was arrived at, one part per round.

  ## Why this is separate from `PairingsEngine.Standings`

  `Standings.tiebreak/4` answers "what is the number". This answers "where
  did the number come from", and the two are wanted at completely different
  times: the number on every standings render, the working only when a
  snapshot is published. Computing the working inside `compute_tiebreaks/3`
  would put a per-round allocation on the hottest path in the app to serve a
  page that is built a few times an hour.

  So this reads FINISHED entries - `Standings.standings/2`'s output, which
  already carries each player's `games`, their `adjusted_score` and their
  `completed_rounds` - and re-derives nothing that was already decided.

  ## Why it is published rather than recomputed downstream

  OpenResults renders the public standings, and its snapshot contract is
  explicit that the arbiter is the authority: it never calculates a placing,
  because "a server that recomputed could silently disagree with the hall".

  The temptation is to let it add up the opponents' finishing scores itself,
  since it already has them. That would be wrong much of the time. Buchholz
  sums each opponent's **Article 16 adjusted** score, not the score in their
  standings row: an opponent's unplayed rounds are re-valued, and a player's
  own unplayed rounds contribute a capped dummy score against a virtual
  opponent who appears in no row at all. A public page showing
  `4.0 + 3.5 + 3.0` beside a published `11.0` would be this app contradicting
  itself in front of the people it is meant to inform.

  ## The shape

  Every tiebreak's working is a list of parts, each with a `round`, an
  optional `opponent_id`, a `value`, and a `kind`:

    * `:played` - a real game against a real opponent, counted.
    * `:virtual` - counted, but with no opponent to name. Article 16's dummy
      for the player's own unplayed round, and for Progressive Score a round
      they have no record for at all. Labelling it is the whole point: an
      unnamed contribution is exactly what makes the arithmetic look broken.
    * `:cut` - a real contribution that a cut modifier discarded (Buchholz
      Cut-1 and friends). Carried so the list still explains its own total.
    * `:excluded` - counted as zero by the tiebreak's own rule rather than by
      a cut: a Koya opponent below the 50% threshold, or a round that simply
      is not what this tiebreak counts.

  `round` is the join key. Every consumer of this already renders a
  round-by-round table, so the working lands as one more column against rows
  it is already drawing rather than as a second list to reconcile.

  Direct Encounter is deliberately absent: it is not a per-round sum but a
  mini-match among players tied on everything else, decided in a separate
  pass over the whole group (`Standings.add_direct_encounter/2`). A caller
  gets no entry for it and should say nothing rather than invent a
  decomposition.
  """

  alias PairingsEngine.Tournaments.Player

  @doc """
  The codes worth publishing the working for.

  Not every tiebreak's arithmetic is worth sending. A reader with the round
  results already in front of them can see for themselves how many games
  were won (Article 7.1/7.2), how many were played with Black (BPG), and
  what the running score was after each round (Progressive, Article 6) - the
  public site derives that last one already, to print the score column on a
  player's card.

  What nobody can derive from the published document is anything built on an
  opponent's **Article 16 adjusted** score, because the adjustment is not in
  the payload and cannot be: it depends on that opponent's own unplayed
  rounds. That is the Buchholz family, Sonneborn-Berger and Koya. Average
  rating is here too - the ratings are published, but which one a cut
  modifier discarded is not.

  This is a size decision as well as a principled one. Sending every code's
  parts made a 300-player, 11-round payload roughly six times bigger; the
  ones left out are the cheap-to-derive half.
  """
  def publishable_codes, do: ~w(BH BHC1 BHC2 MBH SB KS ARO AROC1)

  @doc """
  `%{player_id => %{code => %{total: float, parts: [part]}}}` for `codes`.

  `entries` must be `Standings.standings/2`'s output for the same tournament
  - the parts are read off the entries, not recomputed from the database.

  A code with no meaningful decomposition (Direct Encounter, or one this
  module does not know) is simply absent from a player's map. That is the
  honest answer and it degrades well: a renderer shows the number with no
  working rather than a working that is missing a piece.
  """
  def working(entries, tournament, codes) do
    by_id = Map.new(entries, &{&1.player.id, &1})

    Map.new(entries, fn entry ->
      working =
        for code <- codes,
            parts = parts(code, entry, by_id, tournament),
            parts != nil,
            into: %{} do
          {code, %{total: total(parts), parts: parts}}
        end

      {entry.player.id, working}
    end)
  end

  @doc """
  The sum a list of parts explains - counted parts only.

  A `:cut` or `:excluded` part is carried so the list can show what was
  discarded and why, and must not be added back in.
  """
  def total(parts) do
    parts
    |> Enum.filter(&(&1.kind in [:played, :virtual]))
    |> Enum.map(& &1.value)
    |> Enum.sum()
    |> round_f(2)
  end

  ## ---------- one clause per tiebreak ----------

  # Article 8.1 and its cut modifiers (14.1-14.4).
  defp parts("BH", entry, by_id, t), do: buchholz_parts(entry, by_id, t)
  defp parts("BHC1", entry, by_id, t), do: cut_parts(entry, by_id, t, 1, 0)
  defp parts("BHC2", entry, by_id, t), do: cut_parts(entry, by_id, t, 2, 0)
  defp parts("MBH", entry, by_id, t), do: cut_parts(entry, by_id, t, 1, 1)

  # Article 9.1: the opponent's adjusted score times what was scored against
  # them, so a loss contributes nothing and a draw half. The value is that
  # product - the number that actually enters the sum - and the round it came
  # from is enough to line it up against the result already on screen.
  defp parts("SB", entry, by_id, t) do
    Enum.map(entry.games, fn g ->
      case opponent(g, by_id) do
        nil -> virtual_part(g, entry, t, &(&1 * g.points))
        opp -> played_part(g, opp, round_f(opp.adjusted_score * g.points, 2))
      end
    end)
  end

  # Article 9.2: only opponents on at least half the maximum score count.
  # The rest are shown at zero rather than left out - "I beat them and it did
  # not help" is precisely the question this tiebreak raises.
  defp parts("KS", entry, by_id, t) do
    threshold = entry.completed_rounds * t.points_win / 2

    Enum.map(entry.games, fn g ->
      opp = opponent(g, by_id)

      cond do
        is_nil(opp) -> excluded_part(g, nil, g.voluntary)
        opp.points >= threshold -> played_part(g, opp, round_f(g.points, 2))
        true -> excluded_part(g, opp.player.id, false)
      end
    end)
  end

  # Article 6: the running total after each round, summed. The value is that
  # round's running score, which is also the only reading of "progressive"
  # that makes the column legible - the numbers grow.
  #
  # Walks 1..horizon rather than the player's own games, exactly as
  # `Standings.tiebreak("PS", ...)` does. A player who withdrew still has a
  # running total for the rounds after they left - it stops climbing, but it
  # keeps being added - and a parts list that stopped at their last game
  # would total less than the column beside it. That is not hypothetical: it
  # is what the first version of this function did, and the fixture that
  # caught it is the withdrawal one.
  defp parts("PS", entry, by_id, _t) do
    by_round = Map.new(entry.games, &{&1.round, &1})

    case round_horizon(by_id) do
      0 ->
        []

      horizon ->
        1..horizon
        |> Enum.map_reduce(0.0, fn round, running ->
          game = Map.get(by_round, round)
          running = running + if(game, do: game.points, else: 0.0)

          part = %{
            round: round,
            opponent_id: game && game.opponent_id,
            value: round_f(running, 2),
            # A round the player has no record for still contributes its
            # running total, so it is counted - there is simply nobody to
            # name against it.
            kind: if(game, do: :played, else: :virtual),
            voluntary: false
          }

          {part, running}
        end)
        |> elem(0)
    end
  end

  # Article 7.1: rounds worth as many points as a win, played or not - so a
  # forfeit win and a full-point bye both count, which is the part people
  # query. 7.2 is the same list restricted to games won over the board.
  defp parts("WIN", entry, _by_id, t), do: count_parts(entry, &(&1.points >= t.points_win))

  defp parts("WON", entry, _by_id, _t),
    do: count_parts(entry, &(&1.played and &1.outcome == :win))

  defp parts("BPG", entry, _by_id, _t), do: count_parts(entry, &(&1.played and &1.colour == :b))

  # Article 10.1. The parts are opponents' ratings and `total/1` is their
  # SUM, not the average the standings column shows - a caller printing both
  # divides by the counted parts. Stated here because it is the one tiebreak
  # whose total is not the column's own number.
  defp parts("ARO", entry, by_id, _t), do: rating_parts(entry, by_id, 0)
  defp parts("AROC1", entry, by_id, _t), do: rating_parts(entry, by_id, 1)

  # Direct Encounter, and anything this module has not been taught, get no
  # decomposition. See the moduledoc.
  defp parts(_code, _entry, _by_id, _t), do: nil

  ## ---------- the Buchholz family ----------

  # Mirrors `Standings.buchholz_contributions/3`, keeping the round and the
  # opponent that function drops because the sum does not need them.
  defp buchholz_parts(entry, by_id, t) do
    Enum.map(entry.games, fn g ->
      case opponent(g, by_id) do
        nil -> virtual_part(g, entry, t, & &1)
        opp -> played_part(g, opp, round_f(opp.adjusted_score, 2))
      end
    end)
  end

  # `Standings.cut/3` sorts the values and drops from the ends, which loses
  # WHICH game went. This drops the same ones under the same rule and marks
  # them instead, so a reader sees a discarded round rather than a total that
  # does not match the column beside it.
  defp cut_parts(entry, by_id, t, n_lowest, n_highest) do
    all = buchholz_parts(entry, by_id, t)

    all
    |> drop_lowest_with_vur_priority(n_lowest)
    |> drop_highest(n_highest)
    |> mark_cut(all)
  end

  # Article 16.5's rule, part for part with
  # `Standings.drop_lowest_with_vur_priority/2`: an unplayed round the player
  # chose goes before a lower real score.
  defp drop_lowest_with_vur_priority(parts, 0), do: parts
  defp drop_lowest_with_vur_priority([], _n), do: []

  defp drop_lowest_with_vur_priority(parts, n) do
    candidates =
      case Enum.filter(parts, & &1.voluntary) do
        [] -> parts
        voluntary -> voluntary
      end

    parts
    |> List.delete(Enum.min_by(candidates, & &1.value))
    |> drop_lowest_with_vur_priority(n - 1)
  end

  defp drop_highest(parts, 0), do: parts

  defp drop_highest(parts, n) do
    parts
    |> List.delete(Enum.max_by(parts, & &1.value))
    |> drop_highest(n - 1)
  end

  # Whatever `all` holds that `kept` no longer does was discarded by a cut.
  # Consumed one at a time rather than by set membership, so two rounds that
  # contributed the same number do not cancel each other out.
  defp mark_cut(kept, all) do
    {marked, _leftover} =
      Enum.map_reduce(all, kept, fn part, remaining ->
        if part in remaining do
          {part, List.delete(remaining, part)}
        else
          {%{part | kind: :cut}, remaining}
        end
      end)

    marked
  end

  ## ---------- ratings ----------

  defp rating_parts(entry, by_id, cut_lowest) do
    entry.games
    |> Enum.map(fn g ->
      case opponent(g, by_id) do
        nil ->
          excluded_part(g, nil, g.voluntary)

        opp ->
          part = counted(g, opp.player.id, Player.rating(opp.player) / 1)
          if g.played, do: part, else: %{part | kind: :excluded, value: 0.0}
      end
    end)
    |> cut_lowest_rating(cut_lowest)
  end

  defp cut_lowest_rating(parts, 0), do: parts

  defp cut_lowest_rating(parts, n) do
    case Enum.filter(parts, &(&1.kind == :played)) do
      [] ->
        parts

      counted ->
        lowest = Enum.min_by(counted, & &1.value)
        index = Enum.find_index(parts, &(&1 == lowest))

        parts
        |> List.replace_at(index, %{lowest | kind: :cut})
        |> cut_lowest_rating(n - 1)
    end
  end

  ## ---------- part constructors ----------

  defp count_parts(entry, counts?) do
    Enum.map(entry.games, fn g ->
      if counts?.(g),
        do: counted(g, g.opponent_id, 1.0),
        else: excluded_part(g, g.opponent_id, false)
    end)
  end

  defp played_part(game, opp, value), do: counted(game, opp.player.id, value)

  # Article 16.4's capped dummy: the player's own score, never more than a
  # draw in every round. `transform` is how the tiebreak uses it - Buchholz
  # takes it as it stands, Sonneborn-Berger multiplies by what was scored.
  defp virtual_part(game, entry, t, transform) do
    value = entry.points |> min(t.points_draw * t.rounds_count) |> transform.() |> round_f(2)

    %{
      round: game.round,
      opponent_id: nil,
      value: value,
      kind: :virtual,
      voluntary: game.voluntary
    }
  end

  defp counted(game, opponent_id, value) do
    %{round: game.round, opponent_id: opponent_id, value: value, kind: :played, voluntary: false}
  end

  defp excluded_part(game, opponent_id, voluntary) do
    %{
      round: game.round,
      opponent_id: opponent_id,
      value: 0.0,
      kind: :excluded,
      voluntary: voluntary
    }
  end

  # The highest round NUMBER anyone has a record for. Same definition as
  # `Standings.round_horizon/1`, and it must stay the same: Progressive Score
  # is summed over it.
  defp round_horizon(by_id) do
    by_id
    |> Map.values()
    |> Enum.flat_map(& &1.games)
    |> Enum.map(& &1.round)
    |> Enum.max(fn -> 0 end)
  end

  defp opponent(%{opponent_id: nil}, _by_id), do: nil
  defp opponent(%{opponent_id: id}, by_id), do: Map.get(by_id, id)

  defp round_f(value, places) when is_number(value), do: Float.round(value / 1, places)
end
