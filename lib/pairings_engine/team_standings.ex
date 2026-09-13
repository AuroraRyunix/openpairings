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
  primary score being the default". The codes this module calculates, each
  with that reading:

    * `MP`, `GP` - the scores themselves (Art. 11.1). `GP` as a tie-break
      after MP is also what Art. 13.1 (MPvGP) describes.
    * `DE` - Direct encounter (Art. 6) on match points: among teams still tied
      on MP and on every tie-break listed before DE, if they have all met,
      the match points each scored against the others. Two meetings between
      the same teams count as their average (Art. 6.1.2). Otherwise 0 for
      the whole group, and the next tie-break decides, as in individual
      standings.
    * `BH` - Buchholz (Art. 8.1) on match points: the sum of each opponent's
      final match points, once per match played against them.
    * `SB` - Sonneborn-Berger (Art. 9.1) on the primary score: each
      opponent's final match points multiplied by the match points scored
      against them. This is Art. 13.2.1's EMMSB.
    * `EMGSB` - Art. 13.2.2: each opponent's final match points multiplied by
      the GAME points scored against them - the Olympiad-style team
      Sonneborn-Berger.
    * `BB` - board points weighted by board: on a match of B boards, a point
      on board k is worth B + 1 - k, so board 1 weighs most. Higher is
      better. For teams level on game points this ranks exactly as C.07 Art.
      12.1's Board Count (lower is better), since the two add up to
      (B + 1) x GP.

  A match against no opponent (the bye of an odd-sized round robin) scores
  nothing and contributes nothing: every team has exactly one per cycle, and
  C.07 Art. 16's unplayed-round rules are for Swiss events only (Art. 15.3).
  Team Swiss will need them; see `docs/teams-phase-2-plan.md`.

  When every configured tie-break is exhausted the teams stay in pairing
  number order. C.07 Art. 4.2 prescribes drawing of lots there, which is the
  arbiter's to hold, not the software's.
  """

  import Ecto.Query

  alias PairingsEngine.{PlayerStats, Repo, Results, Standings, Tournaments}
  alias PairingsEngine.Tournaments.{Match, Player, Round, Tournament}

  @supported ~w(MP GP DE BH SB EMGSB BB)

  @doc "The tie-break codes team standings can calculate."
  def supported_codes, do: @supported

  @doc "The configured tie-breaks team standings will apply, in order."
  def effective_tiebreaks(%Tournament{} = t),
    do: Enum.filter(t.tiebreaks || [], &(&1 in @supported))

  @doc """
  The configured tie-breaks that are left out, each with `:not_calculable` -
  the same shape `Standings.dropped_tiebreaks_with_reasons/2` gives, so a
  page can explain them the same way.
  """
  def dropped_tiebreaks_with_reasons(%Tournament{} = t) do
    for code <- t.tiebreaks || [], code not in @supported, do: {code, :not_calculable}
  end

  ## ---------- matches ----------

  @doc """
  Every match of the tournament through `opts[:through_round]` (all rounds
  when absent), scored:

      %{round: n, match_id: id, number: match_no, team_a_id: id, team_b_id: id | nil,
        bye?: bool, complete?: bool, gp_a: float, gp_b: float,
        mp_a: float | nil, mp_b: float | nil,
        boards: [%{board: k, pairing: %Pairing{}, a_player_id: id | nil,
                   b_player_id: id | nil, a_points: float | nil, b_points: float | nil}]}

  `mp_a`/`mp_b` are nil until the match is complete; a board's points are nil
  until it has a result.
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

  defp score_match(%Match{team_b_id: nil} = m, round, _t, _boards) do
    %{
      round: round.number,
      match_id: m.id,
      number: m.board,
      team_a_id: m.team_a_id,
      team_b_id: nil,
      bye?: true,
      complete?: true,
      gp_a: 0.0,
      gp_b: 0.0,
      mp_a: nil,
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

    complete? = Enum.all?(board_rows, &(&1.pairing.result != ""))
    gp_a = board_rows |> Enum.map(&(&1.a_points || 0.0)) |> Enum.sum() |> round1()
    gp_b = board_rows |> Enum.map(&(&1.b_points || 0.0)) |> Enum.sum() |> round1()
    {mp_a, mp_b} = if complete?, do: match_points(t, gp_a, gp_b), else: {nil, nil}

    %{
      round: round.number,
      match_id: m.id,
      number: m.board,
      team_a_id: m.team_a_id,
      team_b_id: m.team_b_id,
      bye?: false,
      complete?: complete?,
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
        done = Enum.filter(records, &(&1.complete? and not &1.bye?))

        %{
          team: team,
          records: records,
          mp: done |> Enum.map(& &1.mp) |> Enum.sum() |> round1(),
          gp: records |> Enum.map(& &1.gp) |> Enum.sum() |> round1(),
          played: length(done),
          won: Enum.count(done, &(&1.gp > &1.opp_gp)),
          drawn: Enum.count(done, &(&1.gp == &1.opp_gp)),
          lost: Enum.count(done, &(&1.gp < &1.opp_gp))
        }
      end)

    by_id = Map.new(entries, &{&1.team.id, &1})

    entries =
      Enum.map(entries, fn e ->
        {values, working} =
          Enum.reduce(codes, {%{}, %{}}, fn
            "DE", acc ->
              acc

            code, {values, working} ->
              {value, parts} = tiebreak(code, e, by_id, t)
              working = if parts, do: Map.put(working, code, parts), else: working
              {Map.put(values, code, value), working}
          end)

        Map.merge(e, %{tiebreaks: values, working: working})
      end)

    entries = if "DE" in codes, do: add_direct_encounter(entries, codes), else: entries

    entries
    |> Enum.sort_by(fn e ->
      {[-e.mp | Enum.map(codes, &(-Map.get(e.tiebreaks, &1, 0.0)))],
       sort_number(e.team.pairing_number), sort_number(e.team.seed), e.team.name, e.team.id}
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
      complete?: m.complete?,
      mp: mp,
      gp: gp,
      opp_gp: opp_gp,
      board_points: Map.new(m.boards, &{&1.board, Map.get(&1, pts)})
    }
  end

  defp played_records(entry), do: Enum.filter(entry.records, &(&1.complete? and not &1.bye?))

  defp tiebreak("MP", e, _by_id, _t), do: {e.mp, nil}
  defp tiebreak("GP", e, _by_id, _t), do: {e.gp, nil}

  defp tiebreak("BH", e, by_id, _t) do
    parts =
      for r <- played_records(e) do
        %{round: r.round, opponent_id: r.opponent_id, value: opp_mp(by_id, r), kind: :played}
      end

    {sum_parts(parts), parts}
  end

  defp tiebreak("SB", e, by_id, _t) do
    parts =
      for r <- played_records(e) do
        %{
          round: r.round,
          opponent_id: r.opponent_id,
          value: round2(opp_mp(by_id, r) * r.mp),
          kind: :played
        }
      end

    {sum_parts(parts), parts}
  end

  defp tiebreak("EMGSB", e, by_id, _t) do
    parts =
      for r <- played_records(e) do
        %{
          round: r.round,
          opponent_id: r.opponent_id,
          value: round2(opp_mp(by_id, r) * r.gp),
          kind: :played
        }
      end

    {sum_parts(parts), parts}
  end

  defp tiebreak("BB", e, _by_id, t) do
    boards = max(t.team_boards || 1, 1)

    value =
      e.records
      |> Enum.flat_map(&Map.to_list(&1.board_points))
      |> Enum.map(fn {k, points} -> (boards + 1 - k) * (points || 0.0) end)
      |> Enum.sum()

    {round2(value), nil}
  end

  defp opp_mp(by_id, record) do
    case Map.get(by_id, record.opponent_id) do
      nil -> 0.0
      opp -> opp.mp
    end
  end

  defp sum_parts(parts), do: parts |> Enum.map(& &1.value) |> Enum.sum() |> round2()

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
