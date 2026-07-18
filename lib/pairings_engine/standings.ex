defmodule PairingsEngine.Standings do
  @moduledoc """
  Standings and tiebreak calculation per the FIDE Tie-Break Regulations (C.07,
  in force from 1 March 2026).

  Individual tiebreaks implemented: BH, BHC1, BHC2, MBH, SB, DE, WIN, WON,
  BPG, PS, KS, ARO, AROC1. Team tiebreaks (MP/GP/BB) arrive with team events.

  Unplayed rounds follow Article 16: an opponent's score is adjusted (trailing
  voluntarily-unplayed rounds count as draws), and the participant's own
  unplayed rounds contribute a capped "dummy opponent" score to Buchholz-style
  sums.
  """

  import Ecto.Query
  alias PairingsEngine.Repo
  alias PairingsEngine.Tournaments
  alias PairingsEngine.Tournaments.{Pairing, Round}

  @doc """
  Returns standings entries with the tournament's configured tiebreaks:
  `[%{player: p, points: float, extra_points: float, total: float, rank: n, tiebreaks: %{"BH" => v, ...}}]`

  `points` is game points only; `extra_points` is the player's administrative
  bonus (SWAR "XtPts"); `total` is `points + extra_points`. Ranking sorts by
  `total` — which equals `points` unless the tournament opted in via
  `tournament.count_extra_points` (SWAR parity #12, default off; see
  `docs/extra-points.md`) — then the tournament's configured tiebreaks.
  FIDE tiebreaks (Buchholz, Sonneborn-Berger, etc.) always keep using
  opponents' game `points`, never `total`, regardless of the toggle —
  administrative bonus points never leak into another player's tiebreak
  inputs.

  Accepts `through_round: n` to compute standings using only rounds `<= n`
  (and byes recorded for those rounds) — i.e. "standings as they stood right
  after round n". This is exactly the same code path ordinary standings use
  once a tournament is mid-way through (they simply never see rounds beyond
  the latest paired one), so a past round number produces the same honest
  figures the tournament actually showed at the time. Omit the option (or
  pass a round `>=` the latest paired round) for the current/overall
  standings.
  """
  def standings(tournament, opts \\ []),
    do: build_standings(tournament, tournament.tiebreaks, opts)

  @doc """
  Same as `standings/1`, but the `:tiebreaks` map on every entry is guaranteed
  to include BH, BHC1, SB, PS and DE, regardless of which codes the tournament
  is actually configured to use (the player grid displays these columns
  unconditionally). Ranking and ordering still follow the tournament's own
  configured tiebreaks, so `:rank` matches `standings/1` exactly.
  """
  def grid_standings(tournament) do
    codes = Enum.uniq(tournament.tiebreaks ++ ~w(BH BHC1 SB PS DE))
    build_standings(tournament, codes, [])
  end

  # Ranking key shared by `build_standings/3` and `add_direct_encounter/2` so
  # they can never drift apart: `total` (points + extra_points) when the
  # tournament opted in to counting extra points, otherwise plain `points`.
  defp rank_score(e, tournament),
    do: if(tournament.count_extra_points, do: e.total, else: e.points)

  defp build_standings(tournament, tiebreak_codes, opts) do
    players = Tournaments.list_players(tournament.id)
    games_by_player = games_by_player(tournament, players, opts)

    entries =
      Enum.map(players, fn player ->
        games = Map.get(games_by_player, player.id, [])
        points = total_points(games)
        extra_points = (player.extra_points || 0.0) |> round_f(1)

        %{
          player: player,
          games: games,
          points: points,
          extra_points: extra_points,
          total: round_f(points + extra_points, 1)
        }
      end)

    entries = compute_tiebreaks(entries, tournament, tiebreak_codes)

    entries
    |> Enum.sort_by(fn e ->
      tb_values = Enum.map(tournament.tiebreaks, &Map.get(e.tiebreaks, &1, 0.0))
      # Ranking sorts by `total` (points + extra_points) only when the
      # tournament opted in to counting extra points; otherwise it's plain
      # game `points` — see the moduledoc/doc above and docs/extra-points.md.
      # ARO-style tiebreaks sort descending like the rest (higher = better).
      rank_score = rank_score(e, tournament)
      [-rank_score | Enum.map(tb_values, &(-&1))]
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {e, rank} -> Map.put(e, :rank, rank) end)
  end

  @doc "Number of rounds that have at least one pairing."
  def rounds_paired(tournament_id) do
    Repo.aggregate(from(r in Round, where: r.tournament_id == ^tournament_id), :count)
  end

  ## ---------- manual standings override (SWAR parity #23) ----------
  #
  # See docs/manual-standings.md for the full design write-up. Short
  # version: `tournament.manual_ranking` lets the arbiter hand-order the
  # displayed standings via `players.manual_rank`, managed exclusively by
  # `PairingsEngine.Tournaments.enable_manual_ranking/1`,
  # `reseed_manual_ranking/1` and `move_manual_rank/3`. This never touches
  # points or tiebreaks — `apply_manual_ranking/2` only ever rewrites
  # `:rank` on entries `standings/2` (or `grid_standings/1`) already
  # computed, purely for display. Not offered for Keizer tournaments — see
  # the doc — so callers never apply this to `PairingsEngine.Keizer.standings/1`
  # output.

  @doc """
  Reorders already-computed `entries` (from `standings/2` or
  `grid_standings/1`) by `tournament.manual_ranking`, reassigning `:rank`
  to match — display only, every other field (`:points`, `:tiebreaks`,
  `:total`, ...) is untouched. A no-op, returning `entries` unchanged, when
  `tournament.manual_ranking` is false.

  Ordering: players with a `manual_rank` (always a plain positive `1..N`
  value — never sign-encoded, see `manual_ranking_stale?/1` for where
  staleness actually lives) sort by it ascending; a player with no
  `manual_rank` yet (added after the mode was switched on, before anyone
  re-seeded — see `manual_ranking_incomplete?/1`) sorts after every ranked
  player, in their own computed-tiebreak order.
  """
  def apply_manual_ranking(entries, tournament) do
    if tournament.manual_ranking do
      entries
      |> Enum.sort_by(fn e -> {manual_sort_key(e.player.manual_rank), e.rank} end)
      |> Enum.with_index(1)
      |> Enum.map(fn {e, rank} -> Map.put(e, :rank, rank) end)
    else
      entries
    end
  end

  defp manual_sort_key(nil), do: {1, 0}
  defp manual_sort_key(rank) when is_integer(rank), do: {0, rank}

  @doc """
  True if `tournament`'s manual order is stale — a pairing result or bye
  was entered/changed since it was last (re)seeded/confirmed, invalidating
  the hand-set order without discarding it. Reads the persisted
  `tournaments.manual_ranking_stale` column directly — see
  `PairingsEngine.Tournaments.invalidate_manual_ranking/1` for how it's
  set, and `reseed_manual_ranking/1` / `move_manual_rank/3` for how it's
  cleared.
  """
  def manual_ranking_stale?(%PairingsEngine.Tournaments.Tournament{} = tournament),
    do: tournament.manual_ranking_stale

  @doc """
  True if `entries` contains a player never placed in the manual order —
  added to the tournament after `manual_ranking` was switched on, before
  anyone re-seeded. Distinct from `manual_ranking_stale?/1` (a *result*
  invalidating the order) — this is the roster having grown underneath it.
  """
  def manual_ranking_incomplete?(entries) do
    Enum.any?(entries, &is_nil(&1.player.manual_rank))
  end

  ## ---------- game extraction ----------

  # One record per player per paired round:
  # %{round: n, opponent_id: id | nil, colour: :w | :b | nil, points: float,
  #   played: boolean (over the board), voluntary: boolean (for unplayed)}
  #
  # `opts[:through_round]`, when set, limits rounds (and byes) to `<= n` —
  # this is how round-scoped ("as of round n") standings are computed.
  defp games_by_player(tournament, players, opts) do
    through_round = Keyword.get(opts, :through_round)

    rounds_query =
      from r in Round,
        where: r.tournament_id == ^tournament.id,
        order_by: r.number,
        preload: [pairings: []]

    rounds_query =
      case through_round do
        nil -> rounds_query
        n -> from r in rounds_query, where: r.number <= ^n
      end

    rounds = Repo.all(rounds_query)

    byes = byes_by_player_round(tournament.id, through_round)
    player_ids = MapSet.new(players, & &1.id)

    for round <- rounds,
        pairing <- round.pairings,
        record <- pairing_records(pairing, round.number, tournament),
        MapSet.member?(player_ids, record.player_id),
        reduce: %{} do
      acc -> Map.update(acc, record.player_id, [record], &(&1 ++ [record]))
    end
    |> add_bye_records(byes, tournament)
  end

  defp byes_by_player_round(tournament_id, through_round) do
    query =
      from b in "byes",
        where: b.tournament_id == ^tournament_id,
        select: %{player_id: b.player_id, round: b.round, type: b.type}

    query =
      case through_round do
        nil -> query
        n -> from b in query, where: b.round <= ^n
      end

    Repo.all(query)
  end

  @doc """
  Points a bye of `type` (a `"byes"`-table row's `type`: `"requested-half"`,
  `"requested-zero"`, `"absent"`, or (for completeness) `"pairing-allocated"`)
  is worth under `tournament`'s configured scoring. The single source of
  truth for this mapping — reused by `add_bye_records/3` here and by any
  display code (e.g. `PairingsEngineWeb.PairingsLive`) that needs to show a
  byes-table row's point value without duplicating the rule.
  """
  def bye_points(type, tournament) do
    case type do
      "requested-half" -> tournament.points_draw
      # SWAR 3-2-1's `SW321_PreBye` club option ("Add presence points for
      # bye games", manual §5.16) — when `presence_on_allocated_bye` is set,
      # a pairing-allocated bye pays `presence_value` ON TOP of `bye_value`
      # (SWAR pays SW321_Bye + SW321_Pre), not `bye_value` alone. The flag
      # defaults false and `presence_value` is nil outside SWAR 3-2-1
      # imports, so everyone else keeps scoring `bye_value` exactly as
      # before. This is also the scoring rule for a real `Pairing` row with
      # `result: "bye"` — `pairing_records/3` below routes through here.
      "pairing-allocated" -> tournament.bye_value + allocated_bye_presence_bonus(tournament)
      # SWAR 3-2-1 "presence points" (SW321_Pre) — distinct from an
      # ordinary configured loss even though SWAR's own bitmask files
      # LOST_BYE as a "loss". `presence_value` is nil for every
      # tournament that isn't a 3-2-1 SWAR import, so this falls back to
      # plain points_loss unchanged for everyone else.
      "requested-zero" -> tournament.presence_value || tournament.points_loss
      # SWAR `AbsValue` (manual §4.2 field 92) — the points paid for a plain
      # absence, distinct from `presence_value`'s 3-2-1-specific "presence
      # points". `abs_value` is nil for every tournament that isn't a SWAR
      # import, so this falls back to plain points_loss unchanged for
      # everyone else — same reasoning as `presence_value` above.
      "absent" -> tournament.abs_value || tournament.points_loss
      _ -> tournament.points_loss
    end
  end

  # The `presence_on_allocated_bye` add-on for a pairing-allocated bye —
  # see `bye_points/2` above. Nil-safe on both fields: `presence_value` can
  # be nil (every non-3-2-1 tournament) and the flag can be nil/false on any
  # struct/map that predates the field.
  defp allocated_bye_presence_bonus(tournament) do
    if Map.get(tournament, :presence_on_allocated_bye) == true and
         is_number(tournament.presence_value) do
      tournament.presence_value
    else
      0.0
    end
  end

  defp add_bye_records(games_by_player, byes, tournament) do
    Enum.reduce(byes, games_by_player, fn bye, acc ->
      points = bye_points(bye.type, tournament)

      record = %{
        round: bye.round,
        player_id: bye.player_id,
        opponent_id: nil,
        colour: nil,
        points: points,
        played: false,
        voluntary: bye.type in ["requested-half", "requested-zero", "absent"],
        # The `byes`-table row's own type ("requested-half" /
        # "requested-zero" / "absent") — carried through so display code
        # (PairingsEngine.PlayerCard.result_label/2) can label the bye by
        # KIND instead of guessing it back from the point value, which lies
        # under custom scoring (e.g. a presence-valued zero bye worth
        # exactly points_draw).
        bye_type: bye.type
      }

      Map.update(acc, bye.player_id, [record], &(&1 ++ [record]))
    end)
  end

  # Expands one stored pairing into records for both players.
  defp pairing_records(%Pairing{result: ""}, _round, _t), do: []

  defp pairing_records(pairing, round_number, t) do
    w = pairing.white_player_id
    b = pairing.black_player_id

    # `played` marks a game contested over the board (FIDE Art. 16 unplayed
    # rules apply otherwise). A forfeit — win or loss, single or double — is
    # always unplayed for BOTH sides, even for the side awarded the point.
    # Plain "0-0" is a played game where both players lose (e.g. both
    # defaulted after making moves); "0-0FF" is the double-forfeit, unplayed.
    # "+--"/"--+" are the legacy forfeit notation kept for
    # historical/SWAR-imported data.
    {wp, bp, played, forfeit} =
      case pairing.result do
        "1-0" -> {t.points_win, t.points_loss, true, false}
        "1/2-1/2" -> {t.points_draw, t.points_draw, true, false}
        "0-1" -> {t.points_loss, t.points_win, true, false}
        "1-0FF" -> {t.points_win, t.points_loss, false, true}
        "0-1FF" -> {t.points_loss, t.points_win, false, true}
        "0-0FF" -> {t.points_loss, t.points_loss, false, true}
        "0-0" -> {t.points_loss, t.points_loss, true, false}
        "+--" -> {t.points_win, t.points_loss, false, true}
        "--+" -> {t.points_loss, t.points_win, false, true}
        # A pairing-allocated bye scores via bye_points/2 — the single
        # source of truth, including the `presence_on_allocated_bye`
        # (SW321_PreBye) add-on. See that function's doc.
        "bye" -> {bye_points("pairing-allocated", t), 0.0, false, false}
        _ -> {0.0, 0.0, false, false}
      end

    white_record = %{
      round: round_number,
      player_id: w,
      opponent_id: if(pairing.result == "bye", do: nil, else: b),
      colour: :w,
      points: wp,
      played: played,
      voluntary: not played and not forfeit,
      # Same key `add_bye_records/3` carries for `byes`-table rows — lets
      # PlayerCard label the row as a pairing-allocated bye by KIND rather
      # than by point-value heuristics. nil for a real game.
      bye_type: if(pairing.result == "bye", do: "pairing-allocated", else: nil)
    }

    if b == nil or pairing.result == "bye" do
      [white_record]
    else
      [
        white_record,
        %{
          round: round_number,
          player_id: b,
          opponent_id: w,
          colour: :b,
          points: bp,
          played: played,
          voluntary: false,
          bye_type: nil
        }
      ]
    end
  end

  defp total_points(games), do: games |> Enum.map(& &1.points) |> Enum.sum() |> round_f(1)

  ## ---------- tiebreak computation ----------

  defp compute_tiebreaks(entries, tournament, tiebreak_codes) do
    by_id = Map.new(entries, &{&1.player.id, &1})

    entries =
      Enum.map(entries, fn entry ->
        values =
          for code <- tiebreak_codes, code != "DE", into: %{} do
            {code, tiebreak(code, entry, by_id, tournament)}
          end

        Map.put(entry, :tiebreaks, values)
      end)

    if "DE" in tiebreak_codes do
      add_direct_encounter(entries, tournament)
    else
      entries
    end
  end

  # Article 8.1: sum of the (adjusted) scores of the opponents; own unplayed
  # rounds contribute a capped dummy score (Article 16.4).
  defp tiebreak("BH", entry, by_id, t),
    do: buchholz_contributions(entry, by_id, t) |> Enum.sum() |> round_f(2)

  # Article 14.1.1: cut the least significant value(s).
  defp tiebreak("BHC1", entry, by_id, t), do: cut(buchholz_contributions(entry, by_id, t), 1, 0)
  defp tiebreak("BHC2", entry, by_id, t), do: cut(buchholz_contributions(entry, by_id, t), 2, 0)
  defp tiebreak("MBH", entry, by_id, t), do: cut(buchholz_contributions(entry, by_id, t), 1, 1)

  # Article 9.1: sum of opponents' (adjusted) scores × points scored against them.
  defp tiebreak("SB", entry, by_id, t) do
    entry.games
    |> Enum.map(fn g ->
      case opponent(g, by_id) do
        nil -> dummy_score(entry, g, t) * g.points
        opp -> adjusted_score(opp, by_id, t) * g.points
      end
    end)
    |> Enum.sum()
    |> round_f(2)
  end

  # Article 7.1: rounds worth as many points as a win, with or without playing.
  defp tiebreak("WIN", entry, _by_id, t) do
    Enum.count(entry.games, &(&1.points >= t.points_win)) / 1
  end

  # Article 7.2: games won over the board.
  defp tiebreak("WON", entry, _by_id, t) do
    Enum.count(entry.games, &(&1.played and &1.points >= t.points_win)) / 1
  end

  # Games played with the black pieces.
  defp tiebreak("BPG", entry, _by_id, _t) do
    Enum.count(entry.games, &(&1.played and &1.colour == :b)) / 1
  end

  # Article 7.5: sum of the running score after each round.
  defp tiebreak("PS", entry, _by_id, _t) do
    entry.games
    |> Enum.sort_by(& &1.round)
    |> Enum.map_reduce(0.0, fn g, acc -> {acc + g.points, acc + g.points} end)
    |> elem(0)
    |> Enum.sum()
    |> round_f(1)
  end

  # Article 9.2: points against opponents with >= 50% of the maximum score.
  defp tiebreak("KS", entry, by_id, t) do
    max_score = rounds_played_count(by_id) * t.points_win

    entry.games
    |> Enum.filter(fn g ->
      opp = opponent(g, by_id)
      opp != nil and opp.points >= max_score / 2
    end)
    |> Enum.map(& &1.points)
    |> Enum.sum()
    |> round_f(1)
  end

  # Article 10.1: average rating of opponents played over the board.
  defp tiebreak("ARO", entry, by_id, _t), do: aro(entry, by_id, 0)
  defp tiebreak("AROC1", entry, by_id, _t), do: aro(entry, by_id, 1)

  defp tiebreak(_unknown, _entry, _by_id, _t), do: 0.0

  defp aro(entry, by_id, cut_lowest) do
    ratings =
      entry.games
      |> Enum.filter(& &1.played)
      |> Enum.map(fn g -> opponent(g, by_id) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&PairingsEngine.Tournaments.Player.rating(&1.player))
      |> Enum.sort()
      |> Enum.drop(cut_lowest)

    case ratings do
      [] -> 0.0
      list -> Float.round(Enum.sum(list) / length(list) + 1.0e-9) / 1
    end
  end

  defp buchholz_contributions(entry, by_id, t) do
    Enum.map(entry.games, fn g ->
      case opponent(g, by_id) do
        nil -> dummy_score(entry, g, t)
        opp -> adjusted_score(opp, by_id, t)
      end
    end)
  end

  # Article 16.3: for tiebreak purposes an opponent's trailing voluntarily
  # unplayed rounds count as draws; other rounds count as the points awarded.
  # A withdrawn/forfeited opponent's missing trailing rounds (no game record
  # at all, because `active_players/1` stops generating any record for them)
  # are treated the same as a real "not played and voluntary" record — that's
  # the fix; everything else here is unchanged.
  defp adjusted_score(opp_entry, by_id, t) do
    games = Enum.sort_by(opp_entry.games, & &1.round)
    total_known_rounds = rounds_played_count(by_id)

    trailing_voluntary =
      games
      |> Enum.reverse()
      |> Enum.take_while(&(not &1.played and &1.voluntary))
      |> length()

    {head, tail} = Enum.split(games, length(games) - trailing_voluntary)

    last_round =
      games
      |> List.last()
      |> case do
        nil -> 0
        g -> g.round
      end

    missing_tail = max(total_known_rounds - last_round, 0)

    Enum.sum(Enum.map(head, & &1.points)) + (length(tail) + missing_tail) * t.points_draw
  end

  # Article 16.4: an unplayed round contributes the score of a dummy opponent —
  # the participant's score before the round, the complementary result, then
  # draws for every later round — capped at draw points × total rounds.
  defp dummy_score(entry, game, t) do
    before =
      entry.games
      |> Enum.filter(&(&1.round < game.round))
      |> Enum.map(& &1.points)
      |> Enum.sum()

    complement = max(t.points_win - game.points, t.points_loss)
    remaining = t.rounds_count - game.round

    dummy = before + complement + remaining * t.points_draw
    dummy |> min(t.points_draw * t.rounds_count) |> round_f(2)
  end

  defp cut(contributions, n_lowest, n_highest) do
    contributions
    |> Enum.sort()
    |> Enum.drop(n_lowest)
    |> Enum.reverse()
    |> Enum.drop(n_highest)
    |> Enum.sum()
    |> round_f(2)
  end

  # Float.round that also accepts integers (sums of integer points).
  defp round_f(value, precision), do: Float.round(value / 1, precision)

  defp opponent(%{opponent_id: nil}, _by_id), do: nil
  defp opponent(%{opponent_id: id}, by_id), do: Map.get(by_id, id)

  defp rounds_played_count(by_id) do
    by_id
    |> Map.values()
    |> Enum.map(&length(&1.games))
    |> Enum.max(fn -> 0 end)
  end

  # Article 6: direct encounter within groups tied on points. Only decisive
  # when every pair in the tied group has met (Swiss partial ties otherwise
  # stay tied here and fall through to the next tiebreak).
  defp add_direct_encounter(entries, tournament) do
    entries
    |> Enum.group_by(&rank_score(&1, tournament))
    |> Enum.flat_map(fn {_points, group} ->
      ids = MapSet.new(group, & &1.player.id)

      all_met? =
        length(group) > 1 and
          Enum.all?(group, fn e ->
            met = MapSet.new(e.games |> Enum.filter(& &1.played) |> Enum.map(& &1.opponent_id))
            MapSet.subset?(MapSet.delete(ids, e.player.id), met)
          end)

      Enum.map(group, fn e ->
        value =
          if all_met? do
            e.games
            |> Enum.filter(&(&1.played and &1.opponent_id in ids))
            |> Enum.map(& &1.points)
            |> Enum.sum()
            |> round_f(1)
          else
            0.0
          end

        put_in(e.tiebreaks["DE"], value)
      end)
    end)
  end
end
