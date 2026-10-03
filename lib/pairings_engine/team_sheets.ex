defmodule PairingsEngine.TeamSheets do
  @moduledoc """
  The data behind the team tables an arbiter pins up or hands out: the team
  cross table, the match result sheets, the rosters and the board prizes.
  `PairingsEngineWeb.TeamSheetsLive` shows them and
  `PairingsEngineWeb.TeamPrintController` prints them; both read from here so
  the screen and the paper cannot disagree.

  Nothing in this module scores anything. Every number is read from
  `PairingsEngine.TeamStandings` (matches, match and game points, board
  statistics) or from the stored boards, exactly as the Standings page shows
  it. See `docs/team-tournaments.md`.
  """

  alias PairingsEngine.{Results, TeamStandings, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  ## ---------- team numbers ----------

  @doc """
  `%{team_id => number}`: a team's frozen pairing number (TPN) once the
  schedule exists, its place in the draw order before that.
  """
  def team_numbers(teams) do
    teams
    |> Enum.with_index(1)
    |> Map.new(fn {team, i} -> {team.id, team.pairing_number || i} end)
  end

  ## ---------- cross table ----------

  @doc """
  The team cross table, in the shape the system calls for.

  A team **round robin** is a grid: `%{kind: :round_robin, teams: [row], ...}`
  with one row per team in team-number order, and `row.cells` a map from the
  opponent's team id to that pair's meetings (one in a single round robin,
  one per cycle in a double). A **Swiss** is a list: `%{kind: :swiss, rows:
  [row], rounds: n}` with one row per team in standings order and `row.rounds`
  the team's cell for each round, 1..n (nil for a round it was not paired in).

  Both carry `rank`, `mp` and `gp` from `TeamStandings.standings/1`. A cell is
  `%{round, opponent_id, opponent_number, colour, gp, opp_gp, mp, bye?,
  started?, complete?, mp_total}`: `colour` is the colour of the team's board
  1 (`:white` or `:black`, the team's colour in the match - C.04.6 Art.
  1.6.1), `gp`/`opp_gp` are nil until a board has a result, `mp` until the
  match is scored, and `mp_total` is the team's match points through that
  round.
  """
  def cross_table(%Tournament{} = t) do
    teams = Tournaments.list_teams(t.id)
    numbers = team_numbers(teams)
    matches = TeamStandings.matches(t)
    standings = Map.new(TeamStandings.standings(t), &{&1.team.id, &1})
    cells = cells_by_team(matches, numbers)
    rounds = matches |> Enum.map(& &1.round) |> Enum.max(fn -> 0 end)

    if Tournament.team_round_robin?(t) do
      rows =
        for team <- teams do
          entry = Map.get(standings, team.id)

          %{
            team: team,
            number: Map.fetch!(numbers, team.id),
            rank: entry && entry.rank,
            mp: entry && entry.mp,
            gp: entry && entry.gp,
            cells:
              cells
              |> Map.get(team.id, [])
              |> Enum.reject(& &1.bye?)
              |> Enum.group_by(& &1.opponent_id)
          }
        end

      %{kind: :round_robin, teams: rows, rounds: rounds}
    else
      rows =
        standings
        |> Map.values()
        |> Enum.sort_by(& &1.rank)
        |> Enum.map(fn entry ->
          by_round = cells |> Map.get(entry.team.id, []) |> Map.new(&{&1.round, &1})

          %{
            team: entry.team,
            number: Map.fetch!(numbers, entry.team.id),
            rank: entry.rank,
            mp: entry.mp,
            gp: entry.gp,
            rounds: for(r <- 1..max(rounds, 1)//1, do: Map.get(by_round, r))
          }
        end)

      %{kind: :swiss, rows: rows, rounds: rounds}
    end
  end

  # `%{team_id => [cell]}` in round order, with the running match points.
  defp cells_by_team(matches, numbers) do
    matches
    |> Enum.flat_map(&sides(&1, numbers))
    |> Enum.group_by(& &1.team_id)
    |> Map.new(fn {team_id, cells} ->
      cells = Enum.sort_by(cells, & &1.round)

      {with_totals, _} =
        Enum.map_reduce(cells, 0, fn cell, total ->
          total = total + (cell.mp || 0)
          {Map.put(cell, :mp_total, total), total}
        end)

      {team_id, with_totals}
    end)
  end

  defp sides(%{bye?: true} = m, _numbers) do
    [
      %{
        team_id: m.team_a_id,
        round: m.round,
        opponent_id: nil,
        opponent_number: nil,
        colour: nil,
        bye?: true,
        started?: false,
        complete?: true,
        gp: nil,
        opp_gp: nil,
        mp: m.mp_a
      }
    ]
  end

  defp sides(m, numbers) do
    started? = Enum.any?(m.boards, &(&1.pairing.result != ""))
    shared = %{round: m.round, bye?: false, started?: started?, complete?: m.complete?}

    [
      Map.merge(shared, %{
        team_id: m.team_a_id,
        opponent_id: m.team_b_id,
        opponent_number: Map.get(numbers, m.team_b_id),
        colour: :white,
        gp: if(started?, do: m.gp_a),
        opp_gp: if(started?, do: m.gp_b),
        mp: m.mp_a
      }),
      Map.merge(shared, %{
        team_id: m.team_b_id,
        opponent_id: m.team_a_id,
        opponent_number: Map.get(numbers, m.team_a_id),
        colour: :black,
        gp: if(started?, do: m.gp_b),
        opp_gp: if(started?, do: m.gp_a),
        mp: m.mp_b
      })
    ]
  end

  ## ---------- rosters ----------

  @doc """
  Every team with its roster in board order, for the board-order list:
  `[%{team, number, players: [%{board: k, player: %Player{}}]}]`, teams in
  team-number order. A player who is not active is still listed (the arbiter
  needs to see who was withdrawn), with their `board` kept.
  """
  def rosters(%Tournament{} = t) do
    teams = Tournaments.list_teams(t.id)
    numbers = team_numbers(teams)

    players =
      t.id
      |> Tournaments.list_players()
      |> Enum.filter(& &1.team_id)
      |> Enum.group_by(& &1.team_id)

    for team <- teams do
      roster = players |> Map.get(team.id, []) |> Tournaments.sort_roster()

      %{
        team: team,
        number: Map.fetch!(numbers, team.id),
        players: roster |> Enum.with_index(1) |> Enum.map(fn {p, k} -> %{board: k, player: p} end)
      }
    end
  end

  ## ---------- board prizes ----------

  @doc """
  Board statistics grouped by board number, each board's players ranked for a
  board prize: percentage first, then points, then performance, then name.
  `[%{board: k, rows: [%{rank: n, stat: board_stat}]}]`, boards ascending;
  `board_stat` is one entry of `TeamStandings.board_stats/2`. Players tied on
  all three share a rank.

  Options: `:min_games` (default 1) leaves out players who sat at fewer
  boards - prizes usually ask for a minimum.
  """
  def board_prizes(%Tournament{} = t, opts \\ []) do
    min_games = Keyword.get(opts, :min_games, 1)

    t
    |> TeamStandings.board_stats()
    |> Enum.filter(&(&1.games >= min_games))
    |> Enum.group_by(& &1.main_board)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {board, stats} ->
      %{board: board, rows: stats |> Enum.sort_by(&prize_key/1) |> ranked()}
    end)
  end

  defp prize_key(s),
    do: {-(s.percentage || -1.0), -s.points, -(s.performance || -1), s.player.name}

  defp ranked(stats) do
    {rows, _} =
      stats
      |> Enum.with_index(1)
      |> Enum.map_reduce({nil, 0}, fn {s, i}, {last_key, last_rank} ->
        key = {s.percentage, s.points, s.performance}
        rank = if key == last_key, do: last_rank, else: i
        {%{rank: rank, stat: s}, {key, rank}}
      end)

    rows
  end

  ## ---------- match sheets ----------

  @doc """
  The matches of round `number` laid out for a result sheet, or `:error` when
  the round is not paired or has no team matches. Options: `:match_id` keeps
  only that match (`:error` if the round has no such match). Byes are left
  out - there is nothing to sign.

      {:ok, %{round: n, date: iso | nil, sheets: [sheet]}}

  A sheet is `%{match, number, team_a, team_b, rows: [row]}`; a row is
  `%{board: k, round_board: n, a_colour: :white | :black, a_player, b_player,
  a_rating, b_rating, a_points, b_points, result: "" | "1-0" ..., forfeit?,
  postponed?}` with the players as `%Player{}` or nil for an empty seat.
  Points are nil until the board has a result.
  """
  def match_sheets(%Tournament{} = t, number, opts \\ []) do
    round = Tournaments.get_round(t.id, number)

    matches =
      if round do
        t
        |> TeamStandings.matches(through_round: number)
        |> Enum.filter(&(&1.round == number and not &1.bye?))
        |> filter_match(Keyword.get(opts, :match_id))
      else
        []
      end

    if matches == [] do
      :error
    else
      teams = t.id |> Tournaments.list_teams() |> Map.new(&{&1.id, &1})
      # `TeamStandings.matches/2` carries the boards without their players.
      pairings = Map.new(round.pairings, &{&1.id, &1})

      {:ok,
       %{
         round: number,
         date: round_date(t, number),
         sheets: Enum.map(matches, &sheet(&1, teams, pairings))
       }}
    end
  end

  defp filter_match(matches, nil), do: matches
  defp filter_match(matches, id), do: Enum.filter(matches, &(&1.match_id == id))

  defp round_date(t, number) do
    case Enum.at(t.round_dates || [], number - 1) do
      date when date in [nil, ""] -> nil
      date -> date
    end
  end

  defp sheet(m, teams, pairings) do
    %{
      match: m,
      number: m.number,
      team_a: Map.get(teams, m.team_a_id),
      team_b: Map.get(teams, m.team_b_id),
      rows: Enum.map(m.boards, &sheet_row(&1, pairings))
    }
  end

  defp sheet_row(b, pairings) do
    p = Map.fetch!(pairings, b.pairing.id)
    a_white? = b.a_player_id == p.white_player_id

    {a_player, b_player} =
      if a_white?, do: {p.white_player, p.black_player}, else: {p.black_player, p.white_player}

    %{
      board: b.board,
      round_board: p.board,
      a_colour: if(a_white?, do: :white, else: :black),
      a_player: a_player,
      b_player: b_player,
      a_rating: a_player && PairingsEngine.Tournaments.Player.rating(a_player),
      b_rating: b_player && PairingsEngine.Tournaments.Player.rating(b_player),
      a_points: b.a_points,
      b_points: b.b_points,
      result: p.result,
      forfeit?: Results.forfeit?(p.result),
      postponed?: Results.postponed?(p.result)
    }
  end

  ## ---------- text ----------

  @doc """
  A score as chess people write it: `2½`, `½`, `0`, `3`. A figure that is
  not a whole or a half (a league that pays 0.25) falls back to decimals.
  Nil is the empty string.
  """
  def points_text(nil), do: ""

  def points_text(v) when is_integer(v), do: Integer.to_string(v)

  def points_text(v) when is_float(v) do
    whole = trunc(v)
    frac = Float.round(v - whole, 2)

    cond do
      frac == 0.0 -> Integer.to_string(whole)
      frac == 0.5 and whole == 0 -> "½"
      frac == 0.5 -> "#{whole}½"
      true -> v |> :erlang.float_to_binary(decimals: 2) |> String.trim_trailing("0")
    end
  end
end
