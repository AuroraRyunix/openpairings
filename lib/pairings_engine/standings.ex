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
  `total` - which equals `points` unless the tournament opted in via
  `tournament.count_extra_points` (SWAR parity #12, default off; see
  `docs/extra-points.md`) - then the tournament's configured tiebreaks.
  FIDE tiebreaks (Buchholz, Sonneborn-Berger, etc.) always keep using
  opponents' game `points`, never `total`, regardless of the toggle -
  administrative bonus points never leak into another player's tiebreak
  inputs.

  Accepts `through_round: n` to compute standings using only rounds `<= n`
  (and byes recorded for those rounds) - i.e. "standings as they stood right
  after round n". This is exactly the same code path ordinary standings use
  once a tournament is mid-way through (they simply never see rounds beyond
  the latest paired one), so a past round number produces the same honest
  figures the tournament actually showed at the time. Omit the option (or
  pass a round `>=` the latest paired round) for the current/overall
  standings.
  """
  def standings(tournament, opts \\ []),
    do: build_standings(tournament, effective_tiebreaks(tournament), opts)

  # Rating-based tiebreaks, in C.07's sense. Only these two are implemented;
  # anything added later that averages or compares ratings belongs here.
  @rating_tiebreaks ~w(ARO AROC1)

  @doc """
  The tiebreaks that may actually be applied, which is not always the ones
  the arbiter configured.

  ## Why a tiebreak can be refused

  C.07 Article 10, on the rating-based tiebreaks:

  > These tie-breaks must be dropped from the tournament tie-break list when
  > unrated players are present, unless detailed rules on the handling of
  > unrated players are included in the tournament regulations or established
  > and published by the Chief Arbiter before the start of the tournament.

  Note what it does NOT do: it gives no rating to substitute for an unrated
  opponent. There is no floor, no "exclude them from the average" - the
  regulation's answer is that the tiebreak may not be used at all unless the
  arbiter published a rule in advance.

  ## What this replaces

  `Player.rating/1` returns `0` for an unrated player, correctly and
  deliberately for its other callers - it exists so `-Player.rating(p)` sort
  keys cannot crash. Averaged, that 0 is not a missing value, it is a
  2000-point-wide vote: a player who faced 2200s and one unrated scored
  around 1956 and dropped below anybody who happened to draw a full rated
  field. One unrated entrant was enough to start moving prizes.

  Dropping the code is what the regulation says and is also the honest
  implementation. Substituting a number would be inventing the rule FIDE
  declined to write.
  """
  def effective_tiebreaks(tournament),
    do: effective_tiebreaks(tournament, Tournaments.list_players(tournament.id))

  @doc """
  As above, for a caller that already holds the player list.

  The arity matters: deciding this needs to know whether an unrated player is
  present, which is a query. `build_standings/3` has the players in hand and
  must not re-ask once per sort comparison.
  """
  def effective_tiebreaks(tournament, players) do
    Enum.reject(tournament.tiebreaks || [], &(&1 in dropped_tiebreaks(tournament, players)))
  end

  @doc """
  The configured tiebreaks that C.07 Article 10 forbids using here, so a page
  can say which and why rather than silently showing one fewer column.
  """
  def dropped_tiebreaks(tournament),
    do: dropped_tiebreaks(tournament, Tournaments.list_players(tournament.id))

  def dropped_tiebreaks(tournament, players) do
    if unrated_present?(players) do
      Enum.filter(tournament.tiebreaks || [], &(&1 in @rating_tiebreaks))
    else
      []
    end
  end

  @doc """
  Whether the tournament has an unrated player in it.

  The tournament, not one player's opponents: Article 10 drops the tiebreak
  for the whole event, because a column that exists for some players and not
  others would not be a tiebreak at all.
  """
  def unrated_present?(players) when is_list(players),
    do: Enum.any?(players, &(PairingsEngine.Tournaments.Player.rating(&1) == 0))

  def unrated_present?(tournament),
    do: unrated_present?(Tournaments.list_players(tournament.id))

  @doc """
  Same as `standings/1`, but the `:tiebreaks` map on every entry is guaranteed
  to include BH, BHC1, SB, PS and DE, regardless of which codes the tournament
  is actually configured to use (the player grid displays these columns
  unconditionally). Ranking and ordering still follow the tournament's own
  configured tiebreaks, so `:rank` matches `standings/1` exactly.
  """
  def grid_standings(tournament) do
    codes = Enum.uniq(effective_tiebreaks(tournament) ++ ~w(BH BHC1 SB PS DE))
    build_standings(tournament, codes, [])
  end

  @doc """
  The score `tournament` actually ranks a standings entry on: `total`
  (points + extra_points) when it opted in to counting extra points,
  otherwise plain `points`.

  Public because it is the single source of truth for that rule, and
  anything that shows a player "their score" has to agree with the standings
  table or it will contradict it on screen - `PairingRationale` reads it for
  the pre-round scores behind its score brackets. Reading `entry.total`
  directly is almost always a bug: it silently counts extra points in
  tournaments that rank without them (the default, and what SWAR imports
  come in as).
  """
  def rank_score(e, tournament),
    do: if(tournament.count_extra_points, do: e.total, else: e.points)

  defp build_standings(tournament, tiebreak_codes, opts) do
    players = Tournaments.list_players(tournament.id)
    {games_by_player, completed_rounds} = games_by_player(tournament, players, opts)

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
          total: round_f(points + extra_points, 1),
          # Carried on the entry rather than threaded through `tiebreak/4`,
          # which has some twenty clauses. Both readers already hold an
          # entry: Article 16.3 reads the OPPONENT's, Article 9.2 its own.
          completed_rounds: completed_rounds
        }
      end)

    entries = compute_tiebreaks(entries, tournament, tiebreak_codes)

    # Hoisted, emphatically: `effective_tiebreaks/1` reads the player list to
    # decide whether an unrated entrant is present, and a sort key runs once
    # per comparison - inside the sort it would be O(n log n) database
    # queries to answer the same question every time.
    #
    # Not `tiebreak_codes` either: `grid_standings/1` adds display-only
    # columns to that list, and ranking must follow the tournament's own
    # configured order or the grid would rank differently from the table.
    ranking_codes = effective_tiebreaks(tournament, players)

    entries
    |> Enum.sort_by(fn e ->
      tb_values = Enum.map(ranking_codes, &Map.get(e.tiebreaks, &1, 0.0))
      # Ranking sorts by `total` (points + extra_points) only when the
      # tournament opted in to counting extra points; otherwise it's plain
      # game `points` - see the moduledoc/doc above and docs/extra-points.md.
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

  @doc """
  `%{player_id => points}` for every player in `tournament`, as their
  score stood immediately BEFORE round `round_number` was paired (i.e.
  `through_round: round_number - 1`). Used by the pairing sheet (live,
  public, projector, print) to show each player's incoming score next to
  their name on the board list, the same way a real printed pairing sheet
  always has - game `points` only, never `total`/extra points. Dispatches
  to `PairingsEngine.Keizer.standings/2` for a Keizer tournament (same
  `:points`/`:player` entry shape), `standings/2` otherwise.
  """
  def player_scores_before_round(tournament, round_number) do
    entries =
      if tournament.pairing_system == "keizer" do
        PairingsEngine.Keizer.standings(tournament, through_round: round_number - 1)
      else
        standings(tournament, through_round: round_number - 1)
      end

    Map.new(entries, &{&1.player.id, &1.points})
  end

  ## ---------- manual standings override (SWAR parity #23) ----------
  #
  # See docs/manual-standings.md for the full design write-up. Short
  # version: `tournament.manual_ranking` lets the arbiter hand-order the
  # displayed standings via `players.manual_rank`, managed exclusively by
  # `PairingsEngine.Tournaments.enable_manual_ranking/1`,
  # `reseed_manual_ranking/1` and `move_manual_rank/3`. This never touches
  # points or tiebreaks - `apply_manual_ranking/2` only ever rewrites
  # `:rank` on entries `standings/2` (or `grid_standings/1`) already
  # computed, purely for display. Not offered for Keizer tournaments - see
  # the doc - so callers never apply this to `PairingsEngine.Keizer.standings/1`
  # output.

  @doc """
  Reorders already-computed `entries` (from `standings/2` or
  `grid_standings/1`) by `tournament.manual_ranking`, reassigning `:rank`
  to match - display only, every other field (`:points`, `:tiebreaks`,
  `:total`, ...) is untouched. A no-op, returning `entries` unchanged, when
  `tournament.manual_ranking` is false.

  Ordering: players with a `manual_rank` (always a plain positive `1..N`
  value - never sign-encoded, see `manual_ranking_stale?/1` for where
  staleness actually lives) sort by it ascending; a player with no
  `manual_rank` yet (added after the mode was switched on, before anyone
  re-seeded - see `manual_ranking_incomplete?/1`) sorts after every ranked
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
  True if `tournament`'s manual order is stale - a pairing result or bye
  was entered/changed since it was last (re)seeded/confirmed, invalidating
  the hand-set order without discarding it. Reads the persisted
  `tournaments.manual_ranking_stale` column directly - see
  `PairingsEngine.Tournaments.invalidate_manual_ranking/1` for how it's
  set, and `reseed_manual_ranking/1` / `move_manual_rank/3` for how it's
  cleared.
  """
  def manual_ranking_stale?(%PairingsEngine.Tournaments.Tournament{} = tournament),
    do: tournament.manual_ranking_stale

  @doc """
  True if `entries` contains a player never placed in the manual order -
  added to the tournament after `manual_ranking` was switched on, before
  anyone re-seeded. Distinct from `manual_ranking_stale?/1` (a *result*
  invalidating the order) - this is the roster having grown underneath it.
  """
  def manual_ranking_incomplete?(entries) do
    Enum.any?(entries, &is_nil(&1.player.manual_rank))
  end

  ## ---------- game extraction ----------

  # One record per player per paired round:
  # %{round: n, opponent_id: id | nil, colour: :w | :b | nil, points: float,
  #   played: boolean (over the board), voluntary: boolean (for unplayed)}
  #
  # `opts[:through_round]`, when set, limits rounds (and byes) to `<= n` -
  # this is how round-scoped ("as of round n") standings are computed.
  defp games_by_player(tournament, players, opts) do
    through_round = Keyword.get(opts, :through_round)
    # `presence: false` scores result points ONLY, with no SWAR 3-2-1
    # presence point. Used by the import's reconciliation check, which
    # compares against a field SWAR stores WITHOUT presence in it -- see
    # `SwarImport.points_adjusted_warnings/3`.
    presence? = Keyword.get(opts, :presence, true)

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

    games =
      for round <- rounds,
          pairing <- round.pairings,
          record <- pairing_records(pairing, round.number, tournament, presence?),
          MapSet.member?(player_ids, record.player_id),
          reduce: %{} do
        acc -> Map.update(acc, record.player_id, [record], &(&1 ++ [record]))
      end

    {add_bye_records(games, byes, tournament), completed_rounds(rounds, byes)}
  end

  # The highest round whose results are ALL in. Article 16.3 asks how many
  # trailing rounds an opponent missed, and Article 9.2 asks what the maximum
  # score so far is; both are questions about rounds that have finished, and
  # a round with one board still unreported has not.
  #
  # This exists because the two used `rounds_played_count/1` - the largest
  # number of game RECORDS any player holds - and compared it against a round
  # NUMBER. Those are different quantities, and an unreported pairing
  # produces no record at all (`pairing_records/4`'s first clause), so the
  # count moved the moment ONE board reported: every player without a record
  # for that round suddenly looked like they had missed a round, and their
  # opponents' Buchholz gained a phantom draw. Koya's 50% threshold jumped a
  # full win at the same instant. Both from a single result being typed in.
  #
  # A round nothing happened in has not been played and does not count -
  # otherwise creating round 6 in advance would immediately award everyone a
  # missing-round draw for it. "Something happened" means a pairing OR a bye:
  # a round can legitimately hold only byes, and a player sitting one out is
  # still participating in that round.
  defp completed_rounds(rounds, byes) do
    bye_rounds = MapSet.new(byes, & &1.round)

    rounds
    |> Enum.filter(fn r ->
      (r.pairings != [] or MapSet.member?(bye_rounds, r.number)) and
        Enum.all?(r.pairings, &(&1.result != ""))
    end)
    |> Enum.map(& &1.number)
    |> Enum.max(fn -> 0 end)
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
  truth for this mapping - reused by `add_bye_records/3` here and by any
  display code (e.g. `PairingsEngineWeb.PairingsLive`) that needs to show a
  byes-table row's point value without duplicating the rule.

  `round` and `cumulative_absences` only matter for `"absent"` - SWAR's own
  "Pt ABSENT" option can cap a plain absence's `abs_value` two ways on top
  of the value itself (manual §4.2, `GetSpecialAbsValue`/`AbsentIsLoss` in
  SWAR's own `Utils.cpp`): pay it only through round `abs_jusque`
  (inclusive), and/or only for the first `abs_nbfois` absences, cumulative
  across the tournament (this round included) - either cap exceeded scores
  `points_loss` instead, same as an unset `abs_value`. Both arguments
  default to `nil`, under which neither cap can ever be exceeded, so a
  caller that doesn't have round/count context on hand (or a tournament
  that predates these fields, where they're `nil` too) gets exactly the old
  flat `abs_value` behavior. Prefer `bye_points_for_row/2` over calling this
  directly with a real byes-table row - it works out `round` and
  `cumulative_absences` for you.
  """
  def bye_points(type, tournament, round \\ nil, cumulative_absences \\ nil) do
    case type do
      "requested-half" -> tournament.points_draw
      # SWAR 3-2-1's `SW321_PreBye` club option ("Add presence points for
      # bye games", manual §5.16) - when `presence_on_allocated_bye` is set,
      # a pairing-allocated bye pays `presence_value` ON TOP of `bye_value`
      # (SWAR pays SW321_Bye + SW321_Pre), not `bye_value` alone. The flag
      # defaults false and `presence_value` is nil outside SWAR 3-2-1
      # imports, so everyone else keeps scoring `bye_value` exactly as
      # before. This is also the scoring rule for a real `Pairing` row with
      # `result: "bye"` - `pairing_records/3` below routes through here.
      "pairing-allocated" -> tournament.bye_value + allocated_bye_presence_bonus(tournament)
      # SWAR 3-2-1 "presence points" (SW321_Pre) - distinct from an
      # ordinary configured loss even though SWAR's own bitmask files
      # LOST_BYE as a "loss". `presence_value` is nil for every
      # tournament that isn't a 3-2-1 SWAR import, so this falls back to
      # plain points_loss unchanged for everyone else.
      "requested-zero" -> tournament.presence_value || tournament.points_loss
      "absent" -> absent_points(tournament, round, cumulative_absences)
      _ -> tournament.points_loss
    end
  end

  # SWAR `AbsValue` (manual §4.2 field 92) - the points paid for a plain
  # absence, distinct from `presence_value`'s 3-2-1-specific "presence
  # points". `abs_value` is nil for every tournament that isn't a SWAR
  # import, so this falls back to plain points_loss unchanged for everyone
  # else - same reasoning as `presence_value` in `bye_points/4` above. On
  # top of that, SWAR's own "Pt ABSENT" option can cap WHICH absences get
  # paid `abs_value` at all - see `bye_points/4`'s doc for the two caps.
  defp absent_points(tournament, round, cumulative_absences) do
    cond do
      is_nil(tournament.abs_value) -> tournament.points_loss
      round_capped?(tournament, round) -> tournament.points_loss
      count_capped?(tournament, cumulative_absences) -> tournament.points_loss
      true -> tournament.abs_value
    end
  end

  defp round_capped?(%{abs_jusque: cap}, round) when is_integer(cap) and is_integer(round),
    do: round > cap

  defp round_capped?(_tournament, _round), do: false

  defp count_capped?(%{abs_nbfois: cap}, count) when is_integer(cap) and is_integer(count),
    do: count > cap

  defp count_capped?(_tournament, _count), do: false

  @doc """
  Same mapping as `bye_points/4`, but takes the byes-table row itself
  (anything with `:type`, `:round`, `:player_id`) instead of a bare type -
  works out `round` and the cumulative "absent" count SWAR's `AbsNbFois`
  cap needs, so display code (`PairingsEngineWeb.PairingsLive`,
  `LiveRoundLive`, `PublicPairingsLive`, `PrintController`) that only has
  one row on hand at a time gets the same round/count-aware answer
  `add_bye_records/3` computes for real standings, without a second
  implementation of the caps to keep in sync.
  """
  def bye_points_for_row(%{type: "absent"} = bye, tournament) do
    bye_points("absent", tournament, bye.round, absent_count(tournament, bye))
  end

  def bye_points_for_row(bye, tournament), do: bye_points(bye.type, tournament)

  # The cumulative count is a DB round-trip, and this function is called once
  # per rendered row inside four render loops (the pool panel, the live round
  # view, the public pairings page and the print controller), so a round with
  # a dozen absences fired a dozen COUNT queries to answer a question that is
  # usually already decided.
  #
  # It is decided because only ONE of `absent_points/3`'s branches ever looks
  # at the count: `count_capped?/2`, and only when `abs_nbfois` is an
  # integer. `abs_nbfois` is nil for every tournament that is not a SWAR
  # import with "Pt ABSENT" limited by occurrence - so for essentially every
  # tournament this asked the database for a number it was about to throw
  # away. The two branches ahead of it (`abs_value` unset, or the round cap
  # already exceeded) return `points_loss` without reading it either.
  #
  # `nil` is what `count_capped?/2`'s fallback clause already means by "no
  # count on hand, so the cap cannot be exceeded", and it is the documented
  # default of `bye_points/4`'s own argument - so skipping the query returns
  # exactly the number the query would have produced, in every branch that
  # skips it. The branch order below mirrors `absent_points/3` deliberately:
  # `abs_nbfois` is only READ where that function reads it, so a caller
  # passing a map without the field is no worse off than before.
  #
  # The remaining case - a tournament that genuinely caps by occurrence -
  # still costs one query per row. Batching it the way `add_bye_records/3`
  # does needs every one of a player's rows in hand at once, and this
  # function is handed exactly one; teaching the four call sites to pass the
  # whole list is the fix for that case, and it is a change to their files,
  # not this one.
  defp absent_count(tournament, bye) do
    cond do
      is_nil(tournament.abs_value) -> nil
      round_capped?(tournament, bye.round) -> nil
      not is_integer(tournament.abs_nbfois) -> nil
      true -> absent_count_through_round(tournament, bye)
    end
  end

  # How many "absent" byes `bye.player_id` has racked up in `tournament`
  # through `bye.round` (inclusive) - the count SWAR's own `GetNbAbsence`
  # counts up to and including the round being scored (§ manual 4.2,
  # `AbsentIsLoss`).
  defp absent_count_through_round(tournament, bye) do
    Repo.one(
      from b in "byes",
        where:
          b.tournament_id == ^tournament.id and b.player_id == ^bye.player_id and
            b.type == "absent" and b.round <= ^bye.round,
        select: count(b.id)
    )
  end

  # The `presence_on_allocated_bye` add-on for a pairing-allocated bye -
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
    byes
    # Grouped and round-sorted per player so the running "absent" count
    # `bye_points/4`'s `abs_nbfois` cap needs can be tracked in memory in
    # one pass, instead of the DB round-trip per row `bye_points_for_row/2`
    # does for a single one-off display lookup - cheap here since every
    # row for a player is already in hand.
    |> Enum.group_by(& &1.player_id)
    |> Enum.reduce(games_by_player, fn {player_id, player_byes}, acc ->
      {records, _final_count} =
        player_byes
        |> Enum.sort_by(& &1.round)
        |> Enum.map_reduce(0, fn bye, absent_count ->
          absent_count = if bye.type == "absent", do: absent_count + 1, else: absent_count
          points = bye_points(bye.type, tournament, bye.round, absent_count)

          record = %{
            round: bye.round,
            player_id: bye.player_id,
            opponent_id: nil,
            colour: nil,
            points: points,
            played: false,
            # "absent" counts as voluntary unless the tournament has opted
            # OUT (Tournament.absent_counts_as_vur, on by default). An
            # absence and a requested bye are one event under two names, so
            # they get one answer here. See that field's doc.
            voluntary:
              bye.type in ["requested-half", "requested-zero"] or
                (bye.type == "absent" and tournament.absent_counts_as_vur),
            # The `byes`-table row's own type ("requested-half" /
            # "requested-zero" / "absent") - carried through so display code
            # (PairingsEngine.PlayerCard.result_label/2) can label the bye by
            # KIND instead of guessing it back from the point value, which
            # lies under custom scoring (e.g. a presence-valued zero bye
            # worth exactly points_draw).
            bye_type: bye.type
          }

          {record, absent_count}
        end)

      Map.update(acc, player_id, records, &(&1 ++ records))
    end)
  end

  # Expands one stored pairing into records for both players.
  defp pairing_records(%Pairing{result: ""}, _round, _t, _presence?), do: []

  defp pairing_records(pairing, round_number, t, presence?) do
    w = pairing.white_player_id
    b = pairing.black_player_id

    # `played` marks a game contested over the board (FIDE Art. 16 unplayed
    # rules apply otherwise). A forfeit - win or loss, single or double - is
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
        "1/2-0" -> {t.points_draw, t.points_loss, true, false}
        "0-1/2" -> {t.points_loss, t.points_draw, true, false}
        "1-0FF" -> {t.points_win, t.points_loss, false, true}
        "0-1FF" -> {t.points_loss, t.points_win, false, true}
        "0-0FF" -> {t.points_loss, t.points_loss, false, true}
        "0-0" -> {t.points_loss, t.points_loss, true, false}
        # Unrated (TRF W/D/L) scores identically to its rated twin and is
        # `played` for every FIDE Art. 16 purpose - the game happened. What
        # makes it unrated is the rating report, not the standings.
        "1-0U" -> {t.points_win, t.points_loss, true, false}
        "0-1U" -> {t.points_loss, t.points_win, true, false}
        "1/2-1/2U" -> {t.points_draw, t.points_draw, true, false}
        "+--" -> {t.points_win, t.points_loss, false, true}
        "--+" -> {t.points_loss, t.points_win, false, true}
        # A pairing-allocated bye scores via bye_points/2 - the single
        # source of truth, including the `presence_on_allocated_bye`
        # (SW321_PreBye) add-on. See that function's doc.
        "bye" -> {bye_points("pairing-allocated", t), 0.0, false, false}
        _ -> {0.0, 0.0, false, false}
      end

    {w_earned?, b_earned?} = presence_earned(pairing.result)
    w_present? = presence? and w_earned?
    b_present? = presence? and b_earned?

    white_record = %{
      round: round_number,
      player_id: w,
      opponent_id: if(pairing.result == "bye", do: nil, else: b),
      colour: :w,
      points: wp + presence_points(t, w_present?),
      played: played,
      # A pairing-allocated bye (odd player count) is never voluntary - the
      # player didn't choose it, so per Art. 16.2.1/16.3 it must always be
      # evaluated at its awarded value for opponents' tiebreak purposes,
      # never downgraded to a draw when trailing. The `byes`-table path
      # (`add_bye_records/3` above) already excludes "pairing-allocated"
      # from its own `voluntary` set for the same reason - this mirrors it
      # for the JaVaFo-assigned `Pairing.result == "bye"` shape.
      voluntary: not played and not forfeit and pairing.result != "bye",
      # Same key `add_bye_records/3` carries for `byes`-table rows - lets
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
          points: bp + presence_points(t, b_present?),
          played: played,
          voluntary: false,
          bye_type: nil
        }
      ]
    end
  end

  # SWAR's 3-2-1 "presence point": a separate per-round accumulator
  # (`GetPresentPtsUntilRound`, Classement.cpp:137) that is added to the
  # result points, not folded into them -
  # `Pts = Joueur.Points + Joueur.ExtraPts + Joueur.SpecialPts`
  # (Classement.cpp:1425), and `Points + SpecialPts` again in the TRF it
  # sends to JaVaFo (EnvoiJAVAFO.cpp:250).
  #
  # This is the "1" in 3-2-1. The Belgian club scheme is Win 2 / Draw 1 /
  # Loss 0 with a presence point on top, which totals 3 / 2 / 1 - so
  # scoring the result value alone turns a 3-2-1 tournament into a 2-1-0
  # one. It is not a uniform shift either: presence is per round ATTENDED,
  # so a player who misses rounds falls behind by one point per absence,
  # and relative order changes, not just the totals.
  #
  # `presence_value` is nil for every tournament that is not a SWAR 3-2-1
  # import, which is what keeps this inert everywhere else.
  # Kept next to `pairing_records/4`'s own case so the two are edited
  # together. Any code here must appear there with `played: true`, and
  # `standings_test.exs` asserts exactly that.
  @played_results ~w(1-0 1/2-1/2 0-1 1/2-0 0-1/2 0-0 1-0U 0-1U 1/2-1/2U)

  @doc """
  Whether a result string means the game was actually PLAYED.

  The nine codes `pairing_records/4` marks `played: true` - every contested
  game including the VCL.13 asymmetric ones and the unrated W/D/L twins, and
  not the forfeits, which occupy a pairing slot but are unplayed under FIDE
  Art. 16.

  Public because `SwarExport` had grown a four-code private copy of it
  (`~w(1-0 1/2-1/2 0-1 0-0)`) that never learned the other five, so a player
  whose games were all unrated or asymmetric exported with `NbParties = 0`
  alongside nonzero points and populated round records - a file that
  contradicts itself. Same precedent as `Trf.playing_codes/0`: the list kept
  being copied, so it stopped being private.
  """
  def played_result?(result), do: result in @played_results

  @doc """
  SWAR 3-2-1 presence points for one game, keyed by its **TRF code**.

  `presence_earned/1` answers the same question from a result STRING
  ("1-0", "0-1FF"); the TRF side of the app only ever has the per-player
  code. Both are here so the two readings of "was this player present"
  cannot drift - which they already had: `Pairing.player_points/2`, the
  number written into TRF columns 81-84 and the number the engine brackets
  by, had no presence term at all, so a 3-2-1 club event was scored one way
  in the crosstable and handed to the engine another.

  Presence is earned by playing, so it follows `Trf.playing_codes/0` with
  one exception: `-` is a forfeit LOSS, and the player who forfeits is the
  one who was not there. Its mirror `+` does earn it, matching
  `presence_earned/1`'s `{true, false}` for "1-0FF".

  Returns 0.0 for every tournament that is not a 3-2-1 import, because
  `presence_value` is nil for them.
  """
  def presence_points_for_code(tournament, code) do
    if code in presence_earning_codes() do
      presence_points(tournament, true)
    else
      0.0
    end
  end

  @doc "TRF codes whose player was present - see `presence_points_for_code/2`."
  def presence_earning_codes, do: Ainalrami.Trf.playing_codes() -- ["-"]

  defp presence_points(_tournament, false), do: 0.0

  defp presence_points(tournament, true) do
    case Map.get(tournament, :presence_value) do
      value when is_number(value) -> value
      _ -> 0.0
    end
  end

  # Which side of a result earned the presence point, from SWAR's own
  # condition: `RESULTATS_NORMAUX | RESULTATS_WIN | RESULTATS_SPECIAUX`.
  #
  # A contested game pays both players - including "0-0", which is
  # ZERO_ZERO and lands in SPECIAUX. A forfeit pays only the WINNER, since
  # `RESULTATS_WIN` is `WIN | WIN_BYE | WIN_FF` while LOST_FF and DRAW_FF
  # are in none of the three sets: the player who did not turn up does not
  # collect a point for turning up. A double forfeit (ZERO_ZEROFF) pays
  # neither.
  #
  # Byes are deliberately NOT handled here - they score through
  # `bye_points/2`, and their 3-2-1 treatment has open questions this pass
  # did not settle (see docs/swar-import.md).
  defp presence_earned(result)
       when result in [
              "1-0",
              "1/2-1/2",
              "0-1",
              "1/2-0",
              "0-1/2",
              "0-0",
              "1-0U",
              "0-1U",
              "1/2-1/2U"
            ],
       do: {true, true}

  defp presence_earned(result) when result in ["1-0FF", "+--"], do: {true, false}
  defp presence_earned(result) when result in ["0-1FF", "--+"], do: {false, true}
  defp presence_earned(_result), do: {false, false}

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
  defp tiebreak("BH", entry, by_id, t) do
    entry
    |> buchholz_contributions(by_id, t)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sum()
    |> round_f(2)
  end

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
        opp -> adjusted_score(opp, t) * g.points
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
  #
  # One term per ROUND OF THE EVENT, not per stored record. A player who
  # withdrew or was forfeited out mid-event has no record for the rounds
  # after they left - `Pairing.absent_players/1` requires
  # `status == "active" and forfeit == false`, so no `byes` row is written -
  # while `build_standings/3` still ranks them. Folding over `entry.games`
  # alone therefore stopped the series early and understated their PS by
  # (rounds since they left) x (their frozen score).
  #
  # C.07 in force 1 March 2026 settles what those rounds are worth: Art.
  # 16.1.1 says "any round after a participant withdraws is a
  # zero-point-bye", so the rounds exist for them and add nothing - which is
  # exactly "carry the running total forward", since a zero-point round
  # leaves the total where it was.
  defp tiebreak("PS", entry, by_id, _t) do
    horizon = round_horizon(by_id)
    by_round = Map.new(entry.games, &{&1.round, &1.points})

    if horizon == 0 do
      0.0
    else
      1..horizon
      |> Enum.map_reduce(0.0, fn round, running ->
        running = running + Map.get(by_round, round, 0.0)
        {running, running}
      end)
      |> elem(0)
      |> Enum.sum()
      |> round_f(1)
    end
  end

  # Article 9.2: points against opponents with >= 50% of the maximum score.
  defp tiebreak("KS", entry, by_id, t) do
    max_score = entry.completed_rounds * t.points_win

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

  # Each contribution tagged with whether it is a voluntary-unplayed-round
  # (VUR) contribution - Art. 16.5.1's Cut-1 Exception needs to know this to
  # cut it in preference to an ordinary contribution. Only the participant's
  # OWN bye rounds (no opponent - `dummy_score`) can ever be a VUR
  # contribution; a round with a real scheduled opponent always uses that
  # opponent's adjusted score regardless of whether the round was forfeited,
  # so it's never tagged. `g.voluntary` (see `pairing_records/3` and
  # `add_bye_records/3`) already excludes pairing-allocated byes and
  # forfeits, matching Art. 16.1's own VUR concept.
  defp buchholz_contributions(entry, by_id, t) do
    Enum.map(entry.games, fn g ->
      case opponent(g, by_id) do
        nil -> {dummy_score(entry, g, t), g.voluntary}
        opp -> {adjusted_score(opp, t), false}
      end
    end)
  end

  # Article 16.3: for tiebreak purposes an opponent's trailing voluntarily
  # unplayed rounds count as draws; other rounds count as the points awarded.
  # A withdrawn/forfeited opponent's missing trailing rounds (no game record
  # at all, because `active_players/1` stops generating any record for them)
  # are treated the same as a real "not played and voluntary" record - that's
  # the fix; everything else here is unchanged.
  defp adjusted_score(opp_entry, t) do
    games = Enum.sort_by(opp_entry.games, & &1.round)

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

    missing_tail = max(opp_entry.completed_rounds - last_round, 0)

    Enum.sum(Enum.map(head, & &1.points)) + (length(tail) + missing_tail) * t.points_draw
  end

  # Article 16.4: an unplayed round contributes the score of a dummy
  # opponent, whose score for this purpose IS the participant's own actual
  # score - not a projection reconstructed from "points before this round,
  # plus a complementary result, plus draws for every round still left in
  # the schedule". That reconstruction was this function's ENTIRE previous
  # body and does not appear anywhere in the regulation; confirmed wrong
  # against both the FIDE Handbook 07 text itself (Art. 16.4: "The dummy's
  # score for the tie-break calculation is the participant's own score")
  # and its own worked example (Tie-Break Exercises, Exercise 11: a
  # player's half-point bye contributes "a value equal to their score...
  # multiplied by the equivalent result of the round" - nothing else).
  #
  # Capped per 16.4.2 at a draw's worth of points × total rounds - this
  # part of the old formula was already right and is unchanged. 16.4.1's
  # forfeit-specific cap (against the scheduled opponent's adjusted score)
  # never applies at this call site: every round `dummy_score` is asked
  # about has no opponent at all (a real forfeit against a scheduled
  # opponent is a played=false `Pairing` row WITH an opponent_id, handled
  # by `adjusted_score/3` via `pairing_records/3` instead).
  defp dummy_score(entry, _game, t) do
    entry.points |> min(t.points_draw * t.rounds_count) |> round_f(2)
  end

  # Article 14.1.1/14.1.2/14.2: cut the least/most significant value(s).
  #
  # Article 16.5.1 "Cut-1 Exception": when a least-significant-value cut
  # applies, a contribution from one of the participant's own voluntary
  # unplayed rounds (VUR - tagged by `buchholz_contributions/3`) is cut in
  # preference to an ordinary contribution, reapplied once per additional
  # lowest-cut (so BHC2's second cut re-checks the remaining set). The
  # regulation's own proviso ("as long as such contribution is not lower
  # than the least significant value") always holds here: a VUR
  # contribution is a member of the same set the natural minimum is drawn
  # from, so its minimum can never be lower than the overall minimum.
  # Highest-value cuts (MBH's second drop) are untouched - 16.5.1 only
  # concerns the least significant value.
  defp cut(contributions, n_lowest, n_highest) do
    contributions
    |> drop_lowest_with_vur_priority(n_lowest)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort(:desc)
    |> Enum.drop(n_highest)
    |> Enum.sum()
    |> round_f(2)
  end

  defp drop_lowest_with_vur_priority([], _n), do: []
  defp drop_lowest_with_vur_priority(contributions, 0), do: contributions

  defp drop_lowest_with_vur_priority(contributions, n) do
    vur_contributions = Enum.filter(contributions, &elem(&1, 1))

    to_drop =
      case vur_contributions do
        [] -> Enum.min_by(contributions, &elem(&1, 0))
        _ -> Enum.min_by(vur_contributions, &elem(&1, 0))
      end

    contributions
    |> List.delete(to_drop)
    |> drop_lowest_with_vur_priority(n - 1)
  end

  # Float.round that also accepts integers (sums of integer points).
  defp round_f(value, precision), do: Float.round(value / 1, precision)

  defp opponent(%{opponent_id: nil}, _by_id), do: nil
  defp opponent(%{opponent_id: id}, by_id), do: Map.get(by_id, id)

  # The highest round NUMBER anyone has a record for - not
  # `rounds_played_count/1`, which counts records and so gives a different
  # (smaller) answer for exactly the players this matters for.
  defp round_horizon(by_id) do
    by_id
    |> Map.values()
    |> Enum.flat_map(& &1.games)
    |> Enum.map(& &1.round)
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
