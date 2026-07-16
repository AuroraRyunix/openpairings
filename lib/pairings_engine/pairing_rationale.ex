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
  alias PairingsEngine.{Repo, Standings, Keizer, Tournaments}
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
    prior_bye_players = players_with_prior_bye(tournament.id, prior)

    pairings = Enum.sort_by(round.pairings, & &1.board)

    boards =
      pairings
      |> Enum.map(fn p ->
        board_context(p, tournament, score_by_player, ladder, colour_hist, played_before)
      end)
      |> Enum.map(fn b ->
        if b.is_bye, do: annotate_bye(b, prior_bye_players), else: b
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
      summary: %{
        boards: Enum.count(boards, &(not &1.is_bye)),
        byes: Enum.count(boards, & &1.is_bye),
        floaters: Enum.count(boards, & &1.floater),
        rematches: Enum.count(boards, & &1.rematch)
      }
    }
  end

  ## ---------- per-board analysis ----------

  defp board_context(pairing, tournament, scores, ladder, colour_hist, played_before) do
    white = pairing.white_player
    black = pairing.black_player
    is_bye = pairing.black_player_id == nil or pairing.result == "bye"

    white_side = side(white, :w, scores, ladder, colour_hist)
    black_side = if is_bye, do: nil, else: side(black, :b, scores, ladder, colour_hist)

    floater =
      not is_bye && white_side && black_side &&
        white_side.score != black_side.score

    rematch =
      not is_bye && black &&
        MapSet.member?(played_before, pair_key(white.id, black.id))

    %{
      board: pairing.board,
      category: category_for(tournament, white),
      is_bye: is_bye,
      floater: !!floater,
      float_up: floater && lower_scored_id(white_side, black_side),
      float_down: floater && higher_scored_id(white_side, black_side),
      rematch: !!rematch,
      white: white_side,
      black: black_side
    }
  end

  defp side(nil, _colour, _scores, _ladder, _hist), do: nil

  defp side(player, colour, scores, ladder, colour_hist) do
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
      colour_ok: colour_matches_due?(colour, due)
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

  defp players_with_prior_bye(_tournament_id, through) when through < 1, do: MapSet.new()

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

    MapSet.new(from_pairings ++ from_byes)
  end

  defp annotate_bye(bye_board, prior_bye_players) do
    player = bye_board.white.player

    Map.put(bye_board, :bye_detail, %{
      player: player,
      had_prior_bye: MapSet.member?(prior_bye_players, player.id),
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
