defmodule PairingsEngine.PairingRationale do
  @moduledoc """
  Explains *why a round was paired the way it was* — the shared analysis
  behind both the audit-trail's rich `"pairing.round_paired"` payload
  (`PairingsEngine.Audit`) and the visual "Explain this round's pairings"
  page (`PairingsEngineWeb.PairingExplainLive`). Computing it in one place
  guarantees the stored audit entry and the live page describe the same
  underlying facts.

  This is a *live analysis of the current data*, not a replay of anything
  stored: it recomputes the pre-round standings (via
  `PairingsEngine.Standings`, or `PairingsEngine.Keizer` for Keizer
  tournaments), regroups the paired players into pre-round score brackets,
  derives each player's FIDE due colour from their prior game history, and
  checks every pairing for a rematch. For a Swiss round it can therefore
  point at the floater (a pairing whose two players came from different score
  brackets — someone "paired up" or "paired down") and name the
  pairing-allocated bye recipient, exactly the "why did it do this" the
  arbiter asked for.

  ## What is and isn't knowable

  JaVaFo (the FIDE Dutch-system engine used for Swiss) is an opaque binary —
  its internal tie-break reasoning cannot be extracted. What we *can* capture
  is the input state that constrains its decision (each player's pre-round
  score, starting rank, colour history) and observable properties of its
  output (which brackets each pairing spans, who floated, who got the bye).
  Round-robin is fully deterministic (a Berger schedule slot), and Keizer's
  ladder values are computed by us, so for those systems the explanation is
  exact rather than inferred.
  """

  import Ecto.Query
  alias PairingsEngine.{Repo, Standings, Keizer, Tournaments, Pairing, PlayerCard}
  alias PairingsEngine.Tournaments.{Round, Player}

  @doc """
  Computes the full pairing rationale for `round_number` of `tournament`, or
  `nil` if that round hasn't been paired.

  Returns a map shaped for both callers:

      %{
        round_number: integer,
        pairing_system: "swiss" | "round_robin" | "keizer",
        pair_by_category: boolean,
        boards: [board_context],
        byes: %{allocated: board_context | nil, requested: [%{player:, type:}]},
        score_groups: [%{score: float, player_ids: [id], count: int, odd: boolean}],
        berger: map | nil,   # round-robin only
        summary: %{boards: int, byes: int, floaters: int, rematches: int}
      }

  where each `board_context` carries `:board`, `:category`, `:is_bye`,
  `:floater`, `:rematch`, and a `:white` / `:black` side map
  (`%{player:, score:, pairing_number:, standings_rank:, colour:, colour_due:,
  colour_ok:, ladder_value:}`).
  """
  def for_round(tournament, round_number) do
    case Tournaments.get_round(tournament.id, round_number) do
      nil -> nil
      round -> build(tournament, round, round_number)
    end
  end

  defp build(tournament, round, round_number) do
    prior = round_number - 1

    score_by_player = pre_round_scores(tournament, prior)
    ladder = ladder_values(tournament, prior)
    colour_hist = colour_history(tournament.id, prior)
    played_before = prior_opponents(tournament.id, prior)
    {prior_bye_players, prior_pairing_bye_players} = players_with_prior_bye(tournament.id, prior)

    pairings = Enum.sort_by(round.pairings, & &1.board)

    boards =
      pairings
      |> Enum.map(fn p ->
        board_context(
          p,
          tournament,
          score_by_player,
          ladder,
          colour_hist,
          played_before,
          prior_bye_players
        )
      end)
      |> Enum.map(fn b ->
        if b.is_bye, do: annotate_bye(b, prior_bye_players, prior_pairing_bye_players), else: b
      end)

    score_groups = score_groups(boards)

    allocated_bye = Enum.find(boards, & &1.is_bye)

    requested_byes =
      tournament.id
      |> Tournaments.list_byes_for_round(round_number)
      |> Enum.map(fn b -> %{player: b.player, type: b.type} end)

    %{
      round_number: round_number,
      pairing_system: tournament.pairing_system,
      pair_by_category: tournament.pair_by_category,
      boards: boards,
      byes: %{allocated: allocated_bye, requested: requested_byes},
      score_groups: score_groups,
      berger: berger_info(tournament, round_number),
      pairing_gap: pairing_gap(tournament, round_number),
      summary: %{
        boards: Enum.count(boards, &(not &1.is_bye)),
        byes: Enum.count(boards, & &1.is_bye),
        floaters: Enum.count(boards, & &1.floater),
        rematches: Enum.count(boards, & &1.rematch)
      }
    }
  end

  ## ---------- cross-round player trails ----------

  @doc """
  Per-player tournament trail up to and including `through_round`, for the
  cross-round strip + score sparkline shown in a **pinned** dot popover on the
  bracket map (`PairingsEngineWeb.PairingExplainLive`). Returns
  `%{player_id => %{rounds: [round_entry], summary: summary}}`.

  Each `round_entry` is a map:

      %{round:, current:, colour: "W" | "B" | "bye" | "absent",
        result:, outcome:, opponent_name:, opponent_seed:, score:}

  `summary` is a "how has this player's tournament gone so far" digest, all
  through `through_round`:

      %{colour: %{w: count, b: count},       # real (non-bye) games played
        floats: %{up: count, down: count},   # rounds paired up vs down
        avg_opponent_rating: integer | nil,   # mean rating of real opponents
        byes: count}

  Design choices, so callers don't re-derive facts:

    * Running `score` after each round comes from `pre_round_scores/2` — the
      SAME per-system honest standings the bracket bands use (Keizer routes to
      the ladder, everything else to `Standings`). A naive cumulative sum of
      per-game points would be WRONG for Keizer, so we never do that. The
      float direction in `summary` reuses the SAME per-round entering scores
      (`scores_by_round[r - 1]`), and calls a round "down" for the
      HIGHER-scored player exactly like `board_context/7`'s `float_down` (the
      higher-scored id) — a player paired down met a lower-scored opponent.
    * `colour` / `result` / `opponent` reuse `Standings`' existing per-game
      records plus `PlayerCard.result_label/2` rather than re-parsing result
      strings. `outcome` is a coarse atom (`:win | :draw | :loss |
      :forfeit_win | :forfeit_loss | :bye | :pending | :absent`) for styling,
      derived from the game map's own fields, not from the label text.
    * The current round is always the last entry. `Standings` emits no game
      record for a still-unplayed pairing, so the current round's colour /
      opponent are read straight from its pairings and marked `:pending`
      (`result: ""`) until a result is entered. A pending round therefore
      never counts toward `summary.colour`/`floats`/`avg_opponent_rating`
      either — those are "games played", and a bye is always resolved
      immediately (its result is set at creation), so `Standings` already
      has a game record for it even in the current round.
    * Rounds a player wasn't paired in (absent, or not yet entered) show an
      honest `"absent"` row rather than being skipped, and contribute nothing
      to the summary counts.

  Returns `%{}` for round 1 or earlier — a first round has no history worth a
  trail, so the view renders no extra chrome for it.
  """
  def player_trails(_tournament, through_round) when through_round < 2, do: %{}

  def player_trails(tournament, through_round) do
    scores_by_round =
      Map.new(0..through_round, fn r -> {r, pre_round_scores(tournament, r)} end)

    entries = Standings.standings(tournament, through_round: through_round)
    by_id = Map.new(entries, fn e -> {e.player.id, e} end)
    current_sides = current_round_sides(tournament, through_round)

    Map.new(entries, fn e ->
      games_by_round = Map.new(e.games, fn g -> {g.round, g} end)

      rounds =
        Enum.map(1..through_round, fn r ->
          trail_round(
            r,
            through_round,
            e.player.id,
            Map.get(games_by_round, r),
            Map.get(current_sides, e.player.id),
            by_id,
            tournament,
            Map.get(scores_by_round, r)
          )
        end)

      summary = trail_summary(e, by_id, scores_by_round, through_round)

      {e.player.id, %{rounds: rounds, summary: summary}}
    end)
  end

  # "Pairing fairness" digest for one player through `through_round` — see
  # the `summary` shape documented on player_trails/2.
  defp trail_summary(e, by_id, scores_by_round, through_round) do
    real_games = Enum.filter(e.games, &(not is_nil(&1.opponent_id) and &1.round <= through_round))

    ratings =
      real_games
      |> Enum.map(fn g -> Map.get(by_id, g.opponent_id) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Player.rating(&1.player))
      |> Enum.reject(&(&1 <= 0))

    # Every stat here counts the same thing — games with a real opponent and
    # a recorded result — so all four share one denominator. Deriving floats
    # from `real_games` (rather than walking 1..through_round and consulting
    # the pending round's pairings) is what keeps that true: a still-unplayed
    # current round has no `Standings` record, so it drops out of the float
    # counts exactly as it already drops out of colour/avg_opponent_rating.
    # Its float direction is not lost to the reader — the pinned dot's own
    # ▲/▼ badge and the "this round" strip row both still show it.
    {up, down} =
      Enum.reduce(real_games, {0, 0}, fn g, {up, down} ->
        entering = Map.get(scores_by_round, g.round - 1)
        own = running_score(entering, e.player.id)
        theirs = running_score(entering, g.opponent_id)

        cond do
          # Higher entering score paired down (mirrors board_context/7's
          # float_down: higher_scored_id/2), lower entering score up.
          own > theirs -> {up, down + 1}
          own < theirs -> {up + 1, down}
          true -> {up, down}
        end
      end)

    %{
      colour: %{w: Enum.count(real_games, &(&1.colour == :w)), b: Enum.count(real_games, &(&1.colour == :b))},
      floats: %{up: up, down: down},
      avg_opponent_rating: if(ratings == [], do: nil, else: round(Enum.sum(ratings) / length(ratings))),
      byes: Enum.count(e.games, &(is_nil(&1.opponent_id) and &1.round <= through_round))
    }
  end

  # Colour/opponent for each player in the current round, read from its
  # pairings so an unplayed (result == "") current round still knows who is
  # playing whom and with which colour — Standings emits no game record until
  # a result exists.
  defp current_round_sides(tournament, round_number) do
    case Tournaments.get_round(tournament.id, round_number) do
      nil ->
        %{}

      round ->
        Enum.reduce(round.pairings, %{}, fn p, acc ->
          is_bye = p.black_player_id == nil or p.result == "bye"

          acc =
            if p.white_player_id do
              Map.put(acc, p.white_player_id, %{
                colour: "W",
                opponent_id: if(is_bye, do: nil, else: p.black_player_id),
                bye: is_bye
              })
            else
              acc
            end

          if p.black_player_id && not is_bye do
            Map.put(acc, p.black_player_id, %{
              colour: "B",
              opponent_id: p.white_player_id,
              bye: false
            })
          else
            acc
          end
        end)
    end
  end

  # No recorded game this round.
  defp trail_round(r, current, player_id, nil, current_side, by_id, _tournament, scores) do
    score = running_score(scores, player_id)

    if r == current and current_side do
      opp = current_side.opponent_id && Map.get(by_id, current_side.opponent_id)

      %{
        round: r,
        current: true,
        colour: if(current_side.bye, do: "bye", else: current_side.colour),
        result: "",
        outcome: :pending,
        opponent_name: opp && opp.player.name,
        opponent_seed: opp && opp.player.pairing_number,
        score: score
      }
    else
      %{
        round: r,
        current: r == current,
        colour: "absent",
        result: "",
        outcome: :absent,
        opponent_name: nil,
        opponent_seed: nil,
        score: score
      }
    end
  end

  # A recorded game (played, forfeit, or bye).
  defp trail_round(r, current, player_id, game, _current_side, by_id, tournament, scores) do
    opp = game.opponent_id && Map.get(by_id, game.opponent_id)

    colour =
      cond do
        is_nil(game.opponent_id) -> "bye"
        game.colour == :w -> "W"
        game.colour == :b -> "B"
        true -> "-"
      end

    %{
      round: r,
      current: r == current,
      colour: colour,
      result: PlayerCard.result_label(game, tournament),
      outcome: trail_outcome(game, tournament),
      opponent_name: opp && opp.player.name,
      opponent_seed: opp && opp.player.pairing_number,
      score: running_score(scores, player_id)
    }
  end

  # Coarse outcome atom for styling, from the game map's own fields (mirrors
  # PlayerCard.result_label/2's branching without re-reading its text output).
  defp trail_outcome(%{opponent_id: nil}, _tournament), do: :bye

  defp trail_outcome(%{played: false} = game, tournament) do
    if game.points >= tournament.points_win, do: :forfeit_win, else: :forfeit_loss
  end

  defp trail_outcome(%{points: points}, tournament) do
    cond do
      points >= tournament.points_win -> :win
      points <= tournament.points_loss -> :loss
      true -> :draw
    end
  end

  defp running_score(scores, player_id) do
    case Map.get(scores, player_id) do
      %{score: s} -> s
      _ -> 0.0
    end
  end

  ## ---------- per-board analysis ----------

  defp board_context(
         pairing,
         tournament,
         scores,
         ladder,
         colour_hist,
         played_before,
         prior_bye_players
       ) do
    white = pairing.white_player
    black = pairing.black_player
    is_bye = pairing.black_player_id == nil or pairing.result == "bye"

    white_side = side(white, :w, scores, ladder, colour_hist, prior_bye_players)
    black_side = if is_bye, do: nil, else: side(black, :b, scores, ladder, colour_hist, prior_bye_players)

    floater =
      not is_bye && white_side && black_side &&
        white_side.score != black_side.score

    rematch =
      not is_bye && black &&
        MapSet.member?(played_before, pair_key(white.id, black.id))

    # A rematch is an anomaly worth flagging UNLESS this tournament's own
    # settings intentionally create back-to-back rematches (round-robin or
    # Swiss "match format" — an immediate second leg against the same
    # opponent is the expected, designed behaviour there, not a data
    # problem). `rematch` itself keeps its original meaning (any prior
    # meeting at all) since it also feeds the audit log and the neutral
    # "REMATCH" board tag; this is a separate, additive fact.
    match_format_expected? = !!(tournament.rr_match_format || tournament.swiss_match_format)
    rematch_anomaly = !!rematch && not match_format_expected?

    %{
      board: pairing.board,
      category: category_for(tournament, white),
      is_bye: is_bye,
      floater: !!floater,
      float_up: floater && lower_scored_id(white_side, black_side),
      float_down: floater && higher_scored_id(white_side, black_side),
      rematch: !!rematch,
      rematch_anomaly: rematch_anomaly,
      white: white_side,
      black: black_side
    }
  end

  defp side(nil, _colour, _scores, _ladder, _hist, _prior_bye_players), do: nil

  defp side(player, colour, scores, ladder, colour_hist, prior_bye_players) do
    %{score: score, standings_rank: rank} =
      Map.get(scores, player.id, %{score: 0.0, standings_rank: nil})

    due = due_colour(Map.get(colour_hist, player.id, []))

    %{
      player: player,
      score: score,
      pairing_number: player.pairing_number,
      standings_rank: rank,
      ladder_value: Map.get(ladder, player.id),
      colour: colour,
      colour_due: due,
      colour_ok: colour_matches_due?(colour, due),
      had_prior_bye: MapSet.member?(prior_bye_players, player.id)
    }
  end

  defp category_for(%{pair_by_category: true}, %Player{category: c}) when c not in [nil, ""], do: c
  defp category_for(%{pair_by_category: true}, _player), do: "Uncategorized"
  defp category_for(_tournament, _player), do: nil

  defp lower_scored_id(w, b), do: if(w.score < b.score, do: w.player.id, else: b.player.id)
  defp higher_scored_id(w, b), do: if(w.score > b.score, do: w.player.id, else: b.player.id)

  ## ---------- score brackets ----------

  # Pre-round score brackets over exactly the players this round actually
  # paired (both colours plus the pairing-allocated bye recipient) — the set
  # JaVaFo was asked to pair. Highest bracket first; `odd` flags a bracket
  # that couldn't pair entirely within itself and therefore had to float a
  # player to an adjacent bracket.
  defp score_groups(boards) do
    boards
    |> Enum.flat_map(fn b -> [b.white, b.black] end)
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(& &1.score)
    |> Enum.map(fn {score, sides} ->
      ids = sides |> Enum.map(& &1.player.id) |> Enum.uniq()

      %{
        score: score,
        player_ids: ids,
        count: length(ids),
        odd: rem(length(ids), 2) == 1
      }
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  ## ---------- colours ----------

  # Each player's colour sequence over real (non-bye) games in rounds `<=
  # through`, in round order.
  defp colour_history(_tournament_id, through) when through < 1, do: %{}

  defp colour_history(tournament_id, through) do
    rounds =
      Repo.all(
        from r in Round,
          where: r.tournament_id == ^tournament_id and r.number <= ^through,
          order_by: r.number,
          preload: [pairings: []]
      )

    for round <- rounds, p <- round.pairings, p.result != "bye", reduce: %{} do
      acc ->
        acc =
          if p.white_player_id,
            do: Map.update(acc, p.white_player_id, [:w], &(&1 ++ [:w])),
            else: acc

        if p.black_player_id,
          do: Map.update(acc, p.black_player_id, [:b], &(&1 ++ [:b])),
          else: acc
    end
  end

  @doc """
  The FIDE due colour for a player given their prior colour sequence
  (`[:w | :b]`, oldest first): the colour that restores balance, or — when
  balanced — the alternation of their last colour. `nil` when there's no
  history (no preference yet). Exposed for focused testing.
  """
  def due_colour([]), do: nil

  def due_colour(colours) do
    whites = Enum.count(colours, &(&1 == :w))
    blacks = Enum.count(colours, &(&1 == :b))

    cond do
      whites > blacks -> :b
      blacks > whites -> :w
      # Balanced — due colour is the opposite of the most recent one (FIDE
      # colour alternation, C.04.2.D).
      true -> alternate(List.last(colours))
    end
  end

  defp alternate(:w), do: :b
  defp alternate(:b), do: :w
  defp alternate(_), do: nil

  defp colour_matches_due?(_colour, nil), do: nil
  defp colour_matches_due?(colour, due), do: colour == due

  ## ---------- rematch / bye history ----------

  defp prior_opponents(_tournament_id, through) when through < 1, do: MapSet.new()

  defp prior_opponents(tournament_id, through) do
    Repo.all(
      from p in "pairings",
        join: r in Round,
        on: p.round_id == r.id,
        where:
          r.tournament_id == ^tournament_id and r.number <= ^through and
            not is_nil(p.black_player_id),
        select: {p.white_player_id, p.black_player_id}
    )
    |> MapSet.new(fn {w, b} -> pair_key(w, b) end)
  end

  # Returns `{combined, pairing_allocated_only}` — `combined` is every player
  # who's had ANY bye before (a real pairing-allocated one, JaVaFo
  # WIN_BYE/DRAW_BYE, OR a requested/absence bye recorded in the "byes"
  # table), which is what the existing "already had a bye" note has always
  # meant and continues to mean. `pairing_allocated_only` is the strict
  # subset from actual bye pairings alone — used to flag the narrower,
  # rarer anomaly of a player receiving more than one *engine-assigned* bye,
  # which FIDE Dutch pairing normally avoids whenever an alternative exists
  # (unlike a requested/absence bye, which can legitimately repeat).
  defp players_with_prior_bye(_tournament_id, through) when through < 1,
    do: {MapSet.new(), MapSet.new()}

  defp players_with_prior_bye(tournament_id, through) do
    from_pairings =
      Repo.all(
        from p in "pairings",
          join: r in Round,
          on: p.round_id == r.id,
          where:
            r.tournament_id == ^tournament_id and r.number <= ^through and p.result == "bye",
          select: p.white_player_id
      )

    from_byes =
      Repo.all(
        from b in "byes",
          where: b.tournament_id == ^tournament_id and b.round <= ^through,
          select: b.player_id
      )

    {MapSet.new(from_pairings ++ from_byes), MapSet.new(from_pairings)}
  end

  defp annotate_bye(bye_board, prior_bye_players, prior_pairing_bye_players) do
    player = bye_board.white.player

    Map.put(bye_board, :bye_detail, %{
      player: player,
      had_prior_bye: MapSet.member?(prior_bye_players, player.id),
      had_prior_pairing_bye: MapSet.member?(prior_pairing_bye_players, player.id),
      convention:
        "The pairing-allocated bye goes to the lowest-ranked eligible player " <>
          "who has not already received one (standard Dutch-system convention)."
    })
  end

  ## ---------- pre-round scores ----------

  defp pre_round_scores(%{pairing_system: "keizer"} = tournament, through) do
    tournament
    |> Keizer.standings(through_round: through)
    |> Map.new(fn e -> {e.player.id, %{score: e.points, standings_rank: e.rank}} end)
  end

  defp pre_round_scores(tournament, through) do
    tournament
    |> Standings.standings(through_round: through)
    |> Map.new(fn e -> {e.player.id, %{score: e.total, standings_rank: e.rank}} end)
  end

  # Keizer ladder value (going into this round) per player, for the Keizer
  # explanation; empty for every other system.
  defp ladder_values(%{pairing_system: "keizer"} = tournament, through) do
    tournament
    |> Keizer.standings(through_round: through)
    |> Map.new(fn e -> {e.player.id, e.value} end)
  end

  defp ladder_values(_tournament, _through), do: %{}

  ## ---------- round-robin Berger info ----------

  defp berger_info(%{pairing_system: "round_robin"} = tournament, round_number) do
    n = length(schedulable_players(tournament.id))
    effective_n = if rem(n, 2) == 0, do: n, else: n + 1
    cycle_length = max(effective_n - 1, 1)

    if tournament.rr_match_format do
      match_number = div(round_number + 1, 2)
      leg = if rem(round_number, 2) == 0, do: 2, else: 1

      %{
        match_format: true,
        match_number: match_number,
        leg: leg,
        deterministic: true
      }
    else
      %{
        match_format: false,
        cycle: div(round_number - 1, cycle_length) + 1,
        cycle_round: Integer.mod(round_number - 1, cycle_length) + 1,
        total_cycles: tournament.rr_cycles,
        deterministic: true
      }
    end
  end

  defp berger_info(_tournament, _round_number), do: nil

  defp schedulable_players(tournament_id) do
    Repo.all(
      from p in Player,
        where:
          p.tournament_id == ^tournament_id and p.status == "active" and
            p.absent == false and p.forfeit == false and not is_nil(p.pairing_number)
    )
  end

  ## ---------- starting-rank / pairing-number gap ----------

  # A round-specific absentee (excluded from just this round via
  # `absent_rounds`, not permanently inactive/forfeited) still holds their
  # global, tournament-wide `pairing_number` — see
  # `PairingsEngine.Pairing.eligible_players/2` and `active_players/1`'s doc
  # comments. If that absentee's pairing number sits anywhere but the very
  # bottom of the field, this round's actually-eligible players have a GAP
  # in the middle of their starting-rank sequence — exactly the condition
  # `PairingsEngine.Pairing.do_pair_single/4` already works around
  # internally (a local contiguous 1..M rank remap) because sending it
  # straight to JaVaFo crashes the real jar. Surfaced here as an
  # informational note (the engine already handles it correctly), not an
  # error — `nil` when there is no gap.
  defp pairing_gap(tournament, round_number) do
    eligible_numbers =
      tournament.id
      |> Pairing.eligible_players(round_number)
      |> Enum.map(& &1.pairing_number)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    case gaps_in(eligible_numbers) do
      [] ->
        nil

      missing_numbers ->
        missing_players =
          tournament.id
          |> Pairing.active_players()
          |> Enum.filter(&(&1.pairing_number in missing_numbers))
          |> Enum.sort_by(& &1.pairing_number)

        %{missing_numbers: missing_numbers, players: missing_players}
    end
  end

  defp gaps_in(sorted_numbers) do
    sorted_numbers
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [a, b] -> if b - a > 1, do: Enum.to_list((a + 1)..(b - 1)), else: [] end)
  end

  ## ---------- serialization for the audit log ----------

  @doc """
  Condenses a `for_round/2` result into a compact, JSON-serializable
  `details` map for the `"pairing.round_paired"` audit entry — plain names,
  scores, colours, floater/rematch flags and the bye recipient, no Ecto
  structs. This is the durable record of the pairing decision that sits
  alongside the live `PairingsEngineWeb.PairingExplainLive` view.
  """
  def audit_payload(nil), do: %{}

  def audit_payload(rationale) do
    %{
      round: rationale.round_number,
      pairing_system: rationale.pairing_system,
      pair_by_category: rationale.pair_by_category,
      board_count: rationale.summary.boards,
      bye_count: rationale.summary.byes,
      floater_count: rationale.summary.floaters,
      rematch_count: rationale.summary.rematches,
      berger: rationale.berger,
      allocated_bye: bye_payload(rationale.byes.allocated),
      requested_byes:
        Enum.map(rationale.byes.requested, fn b ->
          %{player: b.player.name, type: b.type}
        end),
      score_groups:
        Enum.map(rationale.score_groups, fn g ->
          %{score: g.score, count: g.count, odd: g.odd}
        end),
      boards: Enum.map(rationale.boards, &board_payload/1)
    }
  end

  defp board_payload(b) do
    %{
      board: b.board,
      category: b.category,
      bye: b.is_bye,
      floater: b.floater,
      rematch: b.rematch,
      white: side_payload(b.white),
      black: side_payload(b.black)
    }
  end

  defp side_payload(nil), do: nil

  defp side_payload(s) do
    %{
      name: s.player.name,
      score: s.score,
      pairing_number: s.pairing_number,
      standings_rank: s.standings_rank,
      colour: to_string(s.colour),
      colour_due: s.colour_due && to_string(s.colour_due),
      colour_ok: s.colour_ok,
      ladder_value: s.ladder_value
    }
  end

  defp bye_payload(nil), do: nil

  defp bye_payload(%{bye_detail: detail}) do
    %{player: detail.player.name, had_prior_bye: detail.had_prior_bye}
  end

  defp bye_payload(_), do: nil

  defp pair_key(a, b), do: {min(a, b), max(a, b)}
end
