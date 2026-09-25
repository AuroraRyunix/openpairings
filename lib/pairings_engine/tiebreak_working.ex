defmodule PairingsEngine.TiebreakWorking do
  @moduledoc """
  How each tiebreak number was arrived at, one part per round.

  ## Where it comes from

  From `Ainalrami.Tiebreaks.working/2` - the same library, and the same
  elements, that produce the numbers in `PairingsEngine.Standings`. Before the
  standings moved to Ainalrami (docs/tiebreak-gate-2026-09.md) this module
  re-derived the working with its own copy of the arithmetic; a working and a
  number computed by two different pieces of code can disagree, and here they
  would disagree on exactly the forfeits the move fixed. Now the counted parts
  add up to the number by construction (Ainalrami's tests hold that for every
  code).

  It is asked for rarely - when a snapshot is published - so it builds its own
  event from the FINISHED entries rather than riding on the standings' hot
  path.

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
      for the player's own unplayed round - a bye, or since C.07 2026 a
      forfeit - and for Progressive Score a round without a game.
    * `:cut` - a real contribution that a cut modifier discarded (Buchholz
      Cut-1 and friends). Carried so the list still explains its own total.
    * `:excluded` - counted as zero by the tiebreak's own rule rather than by
      a cut: a Koya opponent below the 50% threshold, or a round that simply
      is not what this tiebreak counts.

  `round` is the join key. Every consumer of this already renders a
  round-by-round table, so the working lands as one more column against rows
  it is already drawing rather than as a second list to reconcile.

  Direct Encounter is deliberately absent: it is not a per-round sum but an
  ordering of the players tied on everything else (C.07 Article 6). A caller
  gets no entry for it and should say nothing rather than invent a
  decomposition.
  """

  alias PairingsEngine.Standings
  alias PairingsEngine.Standings.AinalramiBridge

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

  # The codes Ainalrami has a per-round working for.
  @from_ainalrami ~w(BH BHC1 BHC2 MBH SB KS PS ARO AROC1)

  @doc """
  `%{player_id => %{code => %{total: float, parts: [part]}}}` for `codes`.

  `entries` must be `Standings.standings/2`'s output for the same tournament.

  A code with no meaningful decomposition (Direct Encounter, one this module
  does not know, a Buchholz code in a round robin, a rating code Article 10
  drops) is simply absent from a player's map. That is the honest answer and
  it degrades well: a renderer shows the number with no working rather than a
  working that is missing a piece.
  """
  def working([], _tournament, _codes), do: %{}

  def working([first | _] = entries, tournament, codes) do
    event = AinalramiBridge.event(entries, tournament, first.completed_rounds)

    # One code at a time, so a code Ainalrami refuses for this event (C.07
    # Article 8: no Buchholz in a round robin) costs only its own entry.
    from_ainalrami =
      for code <- codes, code in @from_ainalrami, into: %{} do
        c07 = AinalramiBridge.c07_code(code)

        case Ainalrami.Tiebreaks.working(event, [c07]) do
          {:ok, %{^c07 => parts}} -> {code, parts}
          _ -> {code, nil}
        end
      end

    Map.new(entries, fn entry ->
      working =
        for code <- codes,
            parts = parts(code, entry, from_ainalrami, tournament),
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

  # Article 7.1: rounds worth as many points as a win, played or not - so a
  # forfeit win and a full-point bye both count, which is the part people
  # query. 7.2 is the same list restricted to games won over the board.
  #
  # `Standings.win_points/1`: "as many points as awarded for a win" is
  # measured in the currency the round's points are recorded in, the SWAR
  # 3-2-1 presence point included.
  defp parts("WIN", entry, _work, t) do
    win = Standings.win_points(t)
    count_parts(entry, &(&1.points >= win))
  end

  defp parts("WON", entry, _work, _t),
    do: count_parts(entry, &(&1.played and &1.outcome == :win))

  defp parts("BPG", entry, _work, _t),
    do: count_parts(entry, &(&1.played and &1.colour == :b))

  defp parts(code, entry, work, _t) when code in @from_ainalrami do
    case work[code] do
      nil -> nil
      by_id -> by_id |> Map.get(entry.player.id, []) |> Enum.map(&part/1)
    end
  end

  # Direct Encounter, and anything this module has not been taught, get no
  # decomposition. See the moduledoc.
  defp parts(_code, _entry, _work, _t), do: nil

  # Ainalrami's part in this module's shape. A virtual part names nobody - it
  # is the dummy, not the scheduled opponent a forfeit had. An excluded part
  # shows zero, what it counts for; Ainalrami carries the value it would
  # have had.
  defp part(%{round: round, opponent: opponent, value: value, kind: kind, vur?: vur?}) do
    %{
      round: round,
      opponent_id: if(kind == :virtual, do: nil, else: opponent),
      value: if(kind == :excluded, do: 0.0, else: round_f(value, 2)),
      kind: kind,
      voluntary: vur?
    }
  end

  defp count_parts(entry, counts?) do
    entry.games
    |> Enum.sort_by(& &1.round)
    |> Enum.map(fn g ->
      %{
        round: g.round,
        opponent_id: g.opponent_id,
        value: if(counts?.(g), do: 1.0, else: 0.0),
        kind: if(counts?.(g), do: :played, else: :excluded),
        voluntary: false
      }
    end)
  end

  defp round_f(value, places) when is_number(value), do: Float.round(value / 1, places)
end
