defmodule PairingsEngine.TeamStandings do
  @moduledoc """
  Team standings, team tie-breaks and individual board statistics for a team
  tournament. See `docs/team-tournaments.md`.

  Everything here is derived from the round's `matches` rows and the board
  `pairings` that carry their id; nothing is stored. Individual tournaments
  never reach this module, and `PairingsEngine.Standings` is untouched by it.

  ## Scores (C.07 Art. 11.1, read from the local FIDE text)

    * **Game points (GP)** - Art. 11.1.2, "the sum of the individual points
      that each player of the team scores". A board's points are exactly what
      the individual standings pay for it (`Standings.pairing_award/3`), so a
      forfeit win counts for its team and the two views cannot disagree.
    * **Match points (MP)** - Art. 11.1.1, points for a team win, draw and
      loss, decided by comparing the two teams' game points in the match.
      `tournament.team_match_points_win/draw/loss`, 2/1/0 by default.

  A match earns match points only once every board in it has a result; game
  points count each board as soon as its result is in. So a half-reported
  match moves GP, and moves MP when it is finished.

  Match points are the primary score (C.04.6 Art. 1.2.2's default, and the
  one every FIDE team event ranks on): the table is sorted by MP, then by the
  configured tie-breaks in order.

  ## Tie-breaks

  C.07 Art. 13 (local text) lets every individual tie-break of Articles 6-10
  be applied to teams "using teams MP or GP as the reference score - the
  primary score being the default". BH, SB, EMGSB and the order within a
  tied group come from `Ainalrami.Tiebreaks` - the code `ainalrami -c`
  checks standings with, compared game by game with FIDE's TieBreakServer
  on generated team events. The codes, each with its reading:

    * `MP`, `GP` - the scores themselves (Art. 11.1). `GP` as a tie-break
      after MP is also what Art. 13.1 (MPvGP) describes.
    * `DE` - Direct encounter (Art. 6) on match points, all of it: 6.2's
      reapplication to a subset, 6.3's Swiss rule, 6.1.2's average of two
      meetings. The number shown is the match points each team scored
      against the others of its group when all of them met, 0.0 otherwise;
      the order is Ainalrami's.
    * `BH` - Buchholz (Art. 8.1) on match points. Not used in a round robin
      (Art. 8): dropped, with the reason.
    * `SB` - Sonneborn-Berger (Art. 9.1) on match points: Art. 13.2.1's
      EMMSB.
    * `EMGSB` - Art. 13.2.2: each opponent's match points times the GAME
      points scored against them - the Olympiad-style team Sonneborn-Berger.
    * `BB` - board points weighted by board: on a match of B boards, a point
      on board k is worth B + 1 - k, so board 1 weighs most. Higher is
      better. The order uses Art. 12.1's Board Count, which ranks the same
      for teams level on game points (the two add up to (B + 1) x GP) and,
      as 12.1 says, does not apply to teams that are not.

  The tie-breaks count the rounds every match of which is finished; the
  match points the table ranks by first count every finished match.

  A match against no opponent in a round robin (the bye of an odd-sized
  field) scores nothing and is no round for a tie-break: every team has
  exactly one per cycle, and C.07 Art. 16's unplayed-round rules are for
  Swiss events only (Art. 15.3).

  ## Team Swiss

  In a team Swiss (`Tournament.team_swiss?/1`) the pairing-allocated bye
  scores a drawn match (C.04.6 Art. 1.4), and BH, SB and EMGSB apply C.07
  Art. 16 to every unplayed round - the bye, a match with no game played, a
  round the team was not paired in.

  When every configured tie-break is exhausted the teams stay in pairing
  number order. C.07 Art. 4.2 prescribes drawing of lots there, which is the
  arbiter's to hold, not the software's.
  """

  import Ecto.Query

  alias PairingsEngine.{PlayerStats, Repo, Results, Standings, Tournaments}
  alias PairingsEngine.Tournaments.{Match, Player, Round, Tournament}

  @supported ~w(MP GP DE BH SB EMGSB BB)

  # Each code in Ainalrami's (C.07) spelling. BB ranks as Board Count; see
  # the tie-breaks section below.
  @c07 %{
    "MP" => "MPTS",
    "GP" => "GPTS",
    "DE" => "DE",
    "BH" => "BH:MP",
    "SB" => "SB:MP",
    "EMGSB" => "EMGSB",
    "BB" => "BC"
  }

  @with_working ~w(BH SB EMGSB)
  @buchholz ~w(BH)

  @doc "The tie-break codes team standings can calculate."
  def supported_codes, do: @supported

  @doc "The configured tie-breaks team standings will apply, in order."
  def effective_tiebreaks(%Tournament{} = t) do
    dropped = t |> dropped_tiebreaks_with_reasons() |> Enum.map(&elem(&1, 0))
    Enum.reject(t.tiebreaks || [], &(&1 in dropped))
  end

  @doc """
  The configured tie-breaks that are left out, each with `:not_calculable` -
  the same shape `Standings.dropped_tiebreaks_with_reasons/2` gives, so a
  page can explain them the same way.
  """
  def dropped_tiebreaks_with_reasons(%Tournament{} = t) do
    for code <- t.tiebreaks || [],
        reason = drop_reason(code, t),
        reason != nil,
        do: {code, reason}
  end

  defp drop_reason(code, _t) when code not in @supported, do: :not_calculable

  # C.07 Article 8: "Buchholz ... must not be used in round-robins".
  defp drop_reason(code, t) when code in @buchholz do
    if Tournament.team_round_robin?(t), do: :round_robin
  end

  defp drop_reason(_code, _t), do: nil

  ## ---------- matches ----------

  @doc """
  Every match of the tournament through `opts[:through_round]` (all rounds
  when absent), scored:

      %{round: n, match_id: id, number: match_no, team_a_id: id, team_b_id: id | nil,
        bye?: bool, scored?: bool, complete?: bool, postponed_boards: n,
        gp_a: float, gp_b: float, mp_a: float | nil, mp_b: float | nil,
        boards: [%{board: k, pairing: %Pairing{}, a_player_id: id | nil,
                   b_player_id: id | nil, a_points: float | nil, b_points: float | nil}]}

  `scored?` is every board carrying a result, a postponed game (`"*"`)
  included, and `mp_a`/`mp_b` are nil until it is; a board's points are nil
  until it has a result. `complete?` is the same with no postponed board
  left: a match with a game still to be played is not complete, but its
  postponed boards count as the draws they stand for, so the match scores -
  provisionally - and the next round is paired with that score, the same
  way the individual standings pair with it (VCL4THP Q167).
  """
  def matches(%Tournament{} = t, opts \\ []) do
    through = Keyword.get(opts, :through_round)
    boards = max(t.team_boards || 1, 1)

    rounds_query =
      from r in Round,
        where: r.tournament_id == ^t.id,
        order_by: r.number,
        preload: [pairings: []]

    rounds_query =
      if through, do: from(r in rounds_query, where: r.number <= ^through), else: rounds_query

    rounds = Repo.all(rounds_query)
    round_ids = Enum.map(rounds, & &1.id)

    matches_by_round =
      from(m in Match, where: m.round_id in ^round_ids, order_by: m.board)
      |> Repo.all()
      |> Enum.group_by(& &1.round_id)

    for round <- rounds, m <- Map.get(matches_by_round, round.id, []) do
      score_match(m, round, t, boards)
    end
  end

  defp score_match(%Match{team_b_id: nil} = m, round, t, boards) do
    # A team Swiss's pairing-allocated bye pays "as many match points and
    # game points as are rewarded for a draw" (C.04.6 Art. 1.4): the draw's
    # match points, and a draw on every board. A round robin's bye pays
    # nothing - every team has one per cycle.
    {mp, gp} =
      if Tournament.team_swiss?(t),
        do: {t.team_match_points_draw, round1(boards * t.points_draw)},
        else: {nil, 0.0}

    %{
      round: round.number,
      match_id: m.id,
      number: m.board,
      team_a_id: m.team_a_id,
      team_b_id: nil,
      bye?: true,
      forfeited_to: nil,
      played_before_decision?: false,
      scored?: true,
      complete?: true,
      postponed_boards: 0,
      gp_a: gp,
      gp_b: 0.0,
      mp_a: mp,
      mp_b: nil,
      boards: []
    }
  end

  defp score_match(%Match{} = m, round, t, boards) do
    board_rows =
      round.pairings
      |> Enum.filter(&(&1.match_id == m.id))
      |> Enum.sort_by(& &1.board)
      |> Enum.map(fn p ->
        k = rem(p.board - 1, boards) + 1

        {a_id, b_id} =
          if PairingsEngine.TeamRoundRobin.team_a_white?(k),
            do: {p.white_player_id, p.black_player_id},
            else: {p.black_player_id, p.white_player_id}

        {a_points, b_points} = board_points(p, round.number, t, a_id, b_id)

        %{
          board: k,
          pairing: p,
          a_player_id: a_id,
          b_player_id: b_id,
          a_points: a_points,
          b_points: b_points
        }
      end)

    scored? = Enum.all?(board_rows, &(&1.pairing.result != ""))
    postponed_boards = Enum.count(board_rows, &Results.postponed?(&1.pairing.result))
    gp_a = board_rows |> Enum.map(&(&1.a_points || 0.0)) |> Enum.sum() |> round1()
    gp_b = board_rows |> Enum.map(&(&1.b_points || 0.0)) |> Enum.sum() |> round1()
    {mp_a, mp_b} = if scored?, do: match_points(t, gp_a, gp_b), else: {nil, nil}

    %{
      round: round.number,
      match_id: m.id,
      number: m.board,
      team_a_id: m.team_a_id,
      team_b_id: m.team_b_id,
      bye?: false,
      # A decision to forfeit the match (`PairingsEngine.TeamMatches`): the
      # team it was awarded to, and whether games had been played first.
      forfeited_to: m.forfeited_to_team_id,
      played_before_decision?: PairingsEngine.TeamMatches.played_before_decision?(m),
      scored?: scored?,
      complete?: scored? and postponed_boards == 0,
      postponed_boards: postponed_boards,
      gp_a: gp_a,
      gp_b: gp_b,
      mp_a: mp_a,
      mp_b: mp_b,
      boards: board_rows
    }
  end

  # What the board paid each side, from the same function individual
  # standings add up. An empty seat scores nil for its side (nobody sat
  # there); the opposite player's forfeit win is in the award.
  defp board_points(%{result: ""}, _round, _t, _a, _b), do: {nil, nil}

  defp board_points(pairing, round_number, t, a_id, b_id) do
    award = Standings.pairing_award(pairing, round_number, t)
    {side_points(award, a_id), side_points(award, b_id)}
  end

  defp side_points(_award, nil), do: 0.0
  defp side_points(award, id), do: Map.get(award, id, 0.0)

  @doc """
  Match points for a finished match with game points `gp_a` against `gp_b`:
  the win value to the side with more game points, the loss value to the
  other, the draw value to both when level. C.07 Art. 11.1.1.
  """
  def match_points(%Tournament{} = t, gp_a, gp_b) do
    cond do
      gp_a > gp_b -> {t.team_match_points_win, t.team_match_points_loss}
      gp_a < gp_b -> {t.team_match_points_loss, t.team_match_points_win}
      true -> {t.team_match_points_draw, t.team_match_points_draw}
    end
  end

  ## ---------- standings ----------

  @doc """
  Team standings, ranked:

      [%{team: %Team{}, rank: n, mp: float, gp: float, played: n, won: n,
         drawn: n, lost: n, records: [record], tiebreaks: %{code => float},
         working: %{code => [part]}}]

  A `record` is one match from this team's side: `%{round, opponent_id,
  bye?, complete?, mp, gp, opp_gp, board_points: %{k => float}}`. `working`
  carries, for BH, SB and EMGSB, the parts the number was added up from, in
  `PairingsEngine.TiebreakWorking`'s shape (`round`, `opponent_id` - a team
  id here - `value`, `kind`).

  Accepts `through_round: n`, like `Standings.standings/2`.
  """
  def standings(%Tournament{} = t, opts \\ []) do
    teams = Tournaments.list_teams(t.id)
    matches = matches(t, opts)
    codes = effective_tiebreaks(t)

    entries =
      Enum.map(teams, fn team ->
        records = records_for(team.id, matches)
        # Scored matches, postponed boards counting as the draws they stand
        # for until they are played - the same provisional score the next
        # round is paired with. `complete?` is what says it is final.
        done = Enum.filter(records, &(&1.scored? and not &1.bye?))

        %{
          team: team,
          records: records,
          # Every finished match's match points, and a team Swiss bye's
          # (a round robin's bye carries none).
          mp:
            records
            |> Enum.filter(&(&1.scored? and &1.mp != nil))
            |> Enum.map(& &1.mp)
            |> Enum.sum()
            |> round1(),
          gp: records |> Enum.map(& &1.gp) |> Enum.sum() |> round1(),
          played: length(done),
          won: Enum.count(done, &(&1.gp > &1.opp_gp)),
          drawn: Enum.count(done, &(&1.gp == &1.opp_gp)),
          lost: Enum.count(done, &(&1.gp < &1.opp_gp))
        }
      end)

    event = ainalrami_event(entries, matches, t)

    values =
      for code <- codes, Map.has_key?(@c07, code), code not in ~w(DE BB), into: %{} do
        {code, ainalrami_values(event, @c07[code])}
      end

    working =
      for code <- codes, code in @with_working, into: %{} do
        {code, ainalrami_working(event, @c07[code])}
      end

    entries =
      Enum.map(entries, fn e ->
        id = e.team.id

        tiebreaks =
          for code <- codes, code != "DE", into: %{} do
            value =
              case code do
                "MP" -> e.mp
                "GP" -> e.gp
                "BB" -> board_weighted(e, t)
                _ -> as_float(get_in(values, [code, id]))
              end

            {code, value}
          end

        parts =
          for {code, by_id} <- working, by_id != nil, into: %{} do
            {code, Map.get(by_id, id, [])}
          end

        Map.merge(e, %{tiebreaks: tiebreaks, working: parts})
      end)

    entries = if "DE" in codes, do: add_direct_encounter(entries, codes), else: entries
    places = c07_places(event, codes)

    # Match points first - they count every finished match, a round still
    # being played included - then C.07's order, which Ainalrami gives over
    # the rounds that are complete. Once the round is over the two agree.
    entries
    |> Enum.sort_by(fn e ->
      {-e.mp, Map.get(places, e.team.id, 0), sort_number(e.team.pairing_number),
       sort_number(e.team.seed), e.team.name, e.team.id}
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {e, rank} -> Map.put(e, :rank, rank) end)
  end

  defp sort_number(nil), do: {1, 0}
  defp sort_number(n), do: {0, n}

  defp records_for(team_id, matches) do
    matches
    |> Enum.flat_map(fn m ->
      cond do
        m.team_a_id == team_id -> [record(m, :a)]
        m.team_b_id == team_id -> [record(m, :b)]
        true -> []
      end
    end)
  end

  defp record(m, side) do
    {opp, mp, gp, opp_gp, pts} =
      case side do
        :a -> {m.team_b_id, m.mp_a, m.gp_a, m.gp_b, :a_points}
        :b -> {m.team_a_id, m.mp_b, m.gp_b, m.gp_a, :b_points}
      end

    %{
      round: m.round,
      match_id: m.match_id,
      opponent_id: opp,
      bye?: m.bye?,
      played?: not m.bye? and match_played?(m),
      scored?: m.scored?,
      complete?: m.complete?,
      mp: mp,
      gp: gp,
      opp_gp: opp_gp,
      board_points: Map.new(m.boards, &{&1.board, Map.get(&1, pts)})
    }
  end

  defp played_records(entry), do: Enum.filter(entry.records, &(&1.scored? and not &1.bye?))

  @doc """
  Whether a scored match (`matches/2`) was PLAYED: at least one of its games
  was contested over the board. A match whose every board was a forfeit or
  an empty seat was not (C.04.2 Art. 3.5, C.07 Art. 15.1).

  A match forfeited by decision after a game was played still was: its
  boards now read as forfeits, but the teams sat down and played
  (`PairingsEngine.TeamMatches`).
  """
  def match_played?(%{played_before_decision?: true}), do: true

  def match_played?(%{boards: boards}) do
    Enum.any?(boards, fn b -> b.pairing.result != "" and Results.played?(b.pairing.result) end)
  end

  ## ---------- tie-breaks: Ainalrami's ----------
  #
  # BH, SB and EMGSB - Article 16 included - and the order within a tied
  # group come from `Ainalrami.Tiebreaks` (C.07, effective 1 March 2026),
  # the same code `ainalrami -c` checks standings with and the individual
  # standings use (`PairingsEngine.Standings`). It was checked against
  # FIDE's TieBreakServer on generated team events game by game
  # (Ainalrami's `tools/team_tiebreak_compare.exs`).
  #
  # MP, GP and BB are this module's own: MP and GP are the scores the table
  # shows, and BB is not a C.07 code. For the order BB is Board Count
  # (Article 12.1): for teams level on game points the two rank alike (they
  # add up to (B + 1) x GP); for teams that are not, 12.1 says Board Count
  # does not apply, and the next tie-break decides.

  defp board_weighted(e, t) do
    boards = max(t.team_boards || 1, 1)

    e.records
    |> Enum.flat_map(&Map.to_list(&1.board_points))
    |> Enum.map(fn {k, points} -> (boards + 1 - k) * (points || 0.0) end)
    |> Enum.sum()
    |> round2()
  end

  # The event Ainalrami ranks: every team, each round that is complete for
  # the whole field. A round still being played has no place in a
  # tie-break yet - its opponents' scores are not final.
  defp ainalrami_event(entries, matches, t) do
    alias Ainalrami.Tiebreaks.Team, as: C07Team

    boards = max(t.team_boards || 1, 1)
    rounds = complete_rounds(matches)

    teams =
      for e <- entries do
        by_round = Map.new(e.records, &{&1.round, &1})

        %C07Team.Entry{
          id: e.team.id,
          tpn: e.team.pairing_number || e.team.id,
          rounds: Map.new(1..rounds//1, &{&1, c07_match(Map.get(by_round, &1), t, boards)})
        }
      end

    C07Team.new(teams, rounds,
      boards: boards,
      match_points: %{
        win: t.team_match_points_win,
        draw: t.team_match_points_draw,
        loss: t.team_match_points_loss
      },
      game_points: %{win: t.points_win, draw: t.points_draw, loss: t.points_loss},
      predetermined?: Tournament.team_round_robin?(t),
      total_rounds: t.rounds_count
    )
  end

  defp complete_rounds(matches) do
    by_round = Enum.group_by(matches, & &1.round)

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find(fn r ->
      case Map.get(by_round, r) do
        nil -> true
        ms -> not Enum.all?(ms, & &1.scored?)
      end
    end)
    |> Kernel.-(1)
  end

  # One team's round in Ainalrami's terms. Not paired at all - sat out,
  # withdrawn, entered late - is a zero-point bye. The bye of a team Swiss
  # pays what `score_match/4` gave it (a drawn match, C.04.6 Art. 1.4), and
  # its boards count as won for Article 12 ("the same as those assigned to a
  # standard win"). The free round of a team round robin is no round at all
  # for a tie-break: the pairings were fixed in advance.
  defp c07_match(nil, _t, _boards), do: %Ainalrami.Tiebreaks.Team.Match{kind: :zero_bye}

  defp c07_match(%{bye?: true} = r, t, boards) do
    if Tournament.team_swiss?(t) do
      %Ainalrami.Tiebreaks.Team.Match{
        kind: :pab,
        mp: (r.mp || 0.0) * 1.0,
        gp: r.gp * 1.0,
        boards: Map.new(1..boards, &{&1, t.points_win * 1.0})
      }
    else
      %Ainalrami.Tiebreaks.Team.Match{kind: :zero_bye}
    end
  end

  defp c07_match(r, _t, _boards) do
    kind =
      cond do
        r.played? -> :played
        r.gp > r.opp_gp -> :forfeit_win
        true -> :forfeit_loss
      end

    %Ainalrami.Tiebreaks.Team.Match{
      kind: kind,
      opponent: r.opponent_id,
      mp: (r.mp || 0.0) * 1.0,
      gp: r.gp * 1.0,
      boards: Map.new(r.board_points, fn {k, v} -> {k, (v || 0.0) * 1.0} end)
    }
  end

  # One code at a time: a code Ainalrami refuses for this event (Buchholz
  # in a round robin, C.07 Article 8) costs only its own column.
  defp ainalrami_values(event, c07) do
    case Ainalrami.Tiebreaks.compute(event, [c07]) do
      {:ok, %{^c07 => %{} = map}} -> map
      _ -> %{}
    end
  end

  defp ainalrami_working(event, c07) do
    case Ainalrami.Tiebreaks.working(event, [c07]) do
      {:ok, %{^c07 => by_id}} ->
        Map.new(by_id, fn {id, parts} ->
          {id, Enum.map(parts, &part(&1, event.teams[id].rounds[&1.round]))}
        end)

      _ ->
        nil
    end
  end

  # `PairingsEngine.TiebreakWorking`'s part shape, with a team id for the
  # opponent. Article 16's dummy rounds (Ainalrami's `:virtual` parts) are
  # named by what the round was - the bye, a forfeit against the scheduled
  # opponent, or a round the team was not paired in - which is how the
  # Standings page and the published working label them. An excluded part
  # shows zero, what it counts for.
  defp part(%{kind: :virtual} = p, match) do
    {kind, opponent} =
      case match.kind do
        :pab -> {:pab, nil}
        kind when kind in [:forfeit_win, :forfeit_loss] -> {kind, match.opponent}
        _ -> {:bye, nil}
      end

    %{round: p.round, opponent_id: opponent, value: round2(p.value), kind: kind}
  end

  defp part(%{round: round, opponent: opponent, value: value, kind: kind}, _match) do
    %{
      round: round,
      opponent_id: opponent,
      value: if(kind == :excluded, do: 0.0, else: round2(value)),
      kind: kind
    }
  end

  # `%{team_id => place}` under C.07 for the configured codes, from the
  # complete rounds; empty before the first round is over.
  defp c07_places(%{rounds: 0}, _codes), do: %{}

  defp c07_places(event, codes) do
    ranking =
      codes
      |> Enum.filter(&Map.has_key?(@c07, &1))
      |> Enum.reject(&(event.predetermined? and &1 in @buchholz))
      |> Enum.map(&@c07[&1])

    case Ainalrami.Tiebreaks.rank(event, ["MPTS" | ranking]) do
      {:ok, rows} -> Map.new(rows, &{&1.id, &1.rank})
      {:error, _} -> %{}
    end
  end

  defp as_float(nil), do: 0.0
  defp as_float(v), do: v * 1.0

  # C.07 Art. 6 over the teams tied on MP and on every tie-break listed ahead
  # of DE - Art. 4.2 applies each tie-break "for each subgroup of participants
  # still tied", so an encounter with a team the earlier breaks already
  # separated does not belong in the sum.
  defp add_direct_encounter(entries, codes) do
    before_de = Enum.take_while(codes, &(&1 != "DE"))

    entries
    |> Enum.group_by(fn e -> {e.mp, Enum.map(before_de, &Map.get(e.tiebreaks, &1))} end)
    |> Enum.flat_map(fn {_key, group} ->
      ids = MapSet.new(group, & &1.team.id)

      all_met? =
        length(group) > 1 and
          Enum.all?(group, fn e ->
            met = e |> played_records() |> MapSet.new(& &1.opponent_id)
            MapSet.subset?(MapSet.delete(ids, e.team.id), met)
          end)

      Enum.map(group, fn e ->
        value =
          if all_met? do
            e
            |> played_records()
            |> Enum.filter(&(&1.opponent_id in ids))
            |> Enum.group_by(& &1.opponent_id, & &1.mp)
            # Art. 6.1.2: two meetings with the same team count as their average.
            |> Enum.map(fn {_opp, mps} -> Enum.sum(mps) / length(mps) end)
            |> Enum.sum()
            |> round2()
          else
            0.0
          end

        put_in(e.tiebreaks["DE"], value)
      end)
    end)
  end

  ## ---------- individual board statistics ----------

  @doc """
  Each player's record on the boards they sat at, for board prizes:

      [%{player: %Player{}, team_id: id, boards: [k], main_board: k, games: n,
         played: n, points: float, percentage: float | nil, performance: integer | nil}]

  `games` counts every board the player was seated at with a result,
  forfeits included, and `points` is what those boards paid - the same
  points their team's game points were added up from. `performance` is
  `PlayerStats.performance/3` over the games actually played against a rated
  opponent, the figure the Players grid shows. `main_board` is the board
  they played most often, the lower one on a tie; board prizes are usually
  awarded per board number, so the page groups by it.
  """
  def board_stats(%Tournament{} = t, opts \\ []) do
    players = t.id |> Tournaments.list_players() |> Map.new(&{&1.id, &1})

    t
    |> matches(opts)
    |> Enum.flat_map(fn m ->
      Enum.flat_map(m.boards, fn b ->
        board_entries(b, m, players)
      end)
    end)
    |> Enum.group_by(& &1.player_id)
    |> Enum.flat_map(fn {player_id, rows} ->
      case Map.get(players, player_id) do
        nil -> []
        player -> [summarise(player, rows, players, t)]
      end
    end)
    |> Enum.sort_by(&{&1.main_board, -&1.points, &1.player.name})
  end

  defp board_entries(%{pairing: %{result: ""}}, _m, _players), do: []

  defp board_entries(b, m, _players) do
    {_w, _b, played?, _forfeit} = Results.classify(b.pairing.result)

    [
      side_entry(b.a_player_id, b.b_player_id, b.a_points, b, m.team_a_id, played?),
      side_entry(b.b_player_id, b.a_player_id, b.b_points, b, m.team_b_id, played?)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp side_entry(nil, _opp, _points, _b, _team, _played?), do: nil

  defp side_entry(player_id, opp_id, points, b, team_id, played?) do
    white? = b.pairing.white_player_id == player_id
    {w_outcome, b_outcome, _, _} = Results.classify(b.pairing.result)

    %{
      player_id: player_id,
      opponent_id: opp_id,
      team_id: team_id,
      board: b.board,
      points: points || 0.0,
      played?: played? and opp_id != nil,
      outcome: if(white?, do: w_outcome, else: b_outcome)
    }
  end

  defp summarise(player, rows, players, t) do
    rated_played =
      rows
      |> Enum.filter(& &1.played?)
      |> Enum.flat_map(fn r ->
        case Map.get(players, r.opponent_id) do
          nil -> []
          opp -> if Player.rating(opp) > 0, do: [{Player.rating(opp), r.outcome}], else: []
        end
      end)

    wins = Enum.count(rated_played, &(elem(&1, 1) == :win))
    losses = Enum.count(rated_played, &(elem(&1, 1) == :loss))
    points = rows |> Enum.map(& &1.points) |> Enum.sum() |> round1()
    games = length(rows)

    main_board =
      rows
      |> Enum.frequencies_by(& &1.board)
      |> Enum.sort_by(fn {board, count} -> {-count, board} end)
      |> hd()
      |> elem(0)

    %{
      player: player,
      team_id: rows |> List.last() |> Map.get(:team_id),
      boards: rows |> Enum.map(& &1.board) |> Enum.uniq() |> Enum.sort(),
      main_board: main_board,
      games: games,
      played: Enum.count(rows, & &1.played?),
      points: points,
      percentage:
        if(games > 0 and t.points_win > 0,
          do: Float.round(points / (games * t.points_win) * 100, 1)
        ),
      performance: PlayerStats.performance(Enum.map(rated_played, &elem(&1, 0)), wins, losses)
    }
  end

  defp round1(v), do: Float.round(v / 1, 1)
  defp round2(v), do: Float.round(v / 1, 2)
end
