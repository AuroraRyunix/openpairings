defmodule PairingsEngine.TeamRounds do
  @moduledoc """
  Writing a team round - shared by `PairingsEngine.TeamRoundRobin` (Berger
  tables over teams) and `PairingsEngine.TeamSwiss` (C.04.6). Whichever
  system decided WHO plays whom, a match is seated the same way: board by
  board from the rosters, reserves moving up, forfeits for an empty seat,
  colours alternating down the boards. See `docs/team-tournaments.md`.

  ## Colours in a match

  **`team_a` has White on board 1 and on every odd board, Black on every even
  board.** C.04.6 Art. 1.6.1 (read from the local FIDE text) defines a
  team's colour in a match as the colour of its board-1 player, so the
  board-1 colour is the one the pairing system decides - a Berger table's
  "White" number, or the team Article 4 of C.04.6 gives White - and that team
  is written as `team_a`. That the colours then alternate board by board, the
  first team taking the odd boards, is the convention of FIDE team
  competitions such as the Olympiad regulations - recalled from memory, not
  read from a local copy; `docs/team-tournaments.md` says so too.

  ## Line-ups

  Each match is filled from the teams' rosters in board order
  (`Tournaments.team_roster/2`), skipping anyone who cannot play that round:
  withdrawn, marked absent or forfeited for the whole event, absent for that
  round (`absent_rounds`), or not yet started. The next player moves up, which
  is how a reserve comes in. The first `team_boards` of those play.

  A board one team cannot fill is a forfeit win for the other side's player
  (`1-0FF` / `0-1FF` by colour). A board neither team can fill is not
  created at all - there is no game and nobody to score.
  """

  import Ecto.Query

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.{Match, Pairing, Player, Round, Team, Tournament}

  @doc """
  The players who play for a team in `round_number`, in board order: the
  roster (already in board order) minus anyone unavailable that round, cut to
  `boards`. Pure.
  """
  @spec lineup([Player.t()], pos_integer(), pos_integer()) :: [Player.t()]
  def lineup(roster, round_number, boards) do
    roster
    |> Enum.filter(&available?(&1, round_number))
    |> Enum.take(boards)
  end

  @doc "Whether a rostered player can sit at a board in `round_number`."
  def available?(%Player{} = p, round_number) do
    p.status == "active" and not p.absent and not p.forfeit and
      not Engine.absent_for_round?(p, round_number) and
      not Engine.not_yet_started?(p, round_number)
  end

  @doc """
  The boards of one match, as `{board_in_match, white, black, result}` with
  `white`/`black` a player or nil. `team_a` has White on odd boards (see the
  moduledoc). A seat only one team fills is a forfeit win for the player who
  is there; a board neither team fills is left out. Pure.
  """
  @spec match_boards([Player.t()], [Player.t()], pos_integer()) ::
          [{pos_integer(), Player.t() | nil, Player.t() | nil, String.t()}]
  def match_boards(lineup_a, lineup_b, boards) do
    Enum.flat_map(1..boards, fn k ->
      a = Enum.at(lineup_a, k - 1)
      b = Enum.at(lineup_b, k - 1)

      if a == nil and b == nil do
        []
      else
        {white, black} = if team_a_white?(k), do: {a, b}, else: {b, a}
        [{k, white, black, seat_result(white, black)}]
      end
    end)
  end

  @doc "Whether the first-named team has White on board `k` of a match."
  def team_a_white?(k) when is_integer(k) and k > 0, do: rem(k, 2) == 1

  defp seat_result(nil, _black), do: "0-1FF"
  defp seat_result(_white, nil), do: "1-0FF"
  defp seat_result(_white, _black), do: ""

  @doc """
  Teams holding a pairing number, in pairing-number order.
  """
  def numbered_teams(tournament_id) do
    Repo.all(
      from t in Team,
        where: t.tournament_id == ^tournament_id and not is_nil(t.pairing_number),
        order_by: t.pairing_number
    )
  end

  @doc """
  Writes round `number`: one `Match` per entry, in the order given, with its
  boards.

  `entries` are `{:pairing, team_a_number, team_b_number}` - team A holding
  White on board 1 - and `{:bye, team_number}`, a match with no opponent and
  no boards. Byes are written after every pairing whatever their position in
  the list. `teams` are the numbered teams the entries refer to.

  Runs in one transaction; returns `{:ok, round}`.
  """
  def create_round(%Tournament{} = tournament, teams, entries, number) do
    by_number = Map.new(teams, &{&1.pairing_number, &1})
    boards = tournament.team_boards

    lineups =
      Map.new(teams, fn team ->
        {team.id, lineup(Tournaments.team_roster(tournament.id, team.id), number, boards)}
      end)

    Repo.transaction(fn ->
      # Numbered in team-number order across the whole field, so the numbers
      # read team by team on the TRF report.
      numbered =
        teams
        |> Enum.flat_map(&Map.fetch!(lineups, &1.id))
        |> then(&ensure_player_numbers(tournament, &1))
        |> Map.new(&{&1.id, &1})

      lineups =
        Map.new(lineups, fn {id, ps} -> {id, Enum.map(ps, &Map.fetch!(numbered, &1.id))} end)

      round =
        Repo.insert!(%Round{
          tournament_id: tournament.id,
          number: number,
          status: "playing",
          published_at: Tournaments.compute_published_at(tournament, number)
        })

      played = Enum.filter(entries, &match?({:pairing, _, _}, &1))

      played
      |> Enum.with_index(1)
      |> Enum.each(fn {{:pairing, a, b}, match_no} ->
        team_a = Map.fetch!(by_number, a)
        team_b = Map.fetch!(by_number, b)

        match =
          Repo.insert!(%Match{
            round_id: round.id,
            board: match_no,
            team_a_id: team_a.id,
            team_b_id: team_b.id
          })

        Map.fetch!(lineups, team_a.id)
        |> match_boards(Map.fetch!(lineups, team_b.id), boards)
        |> Enum.each(fn {k, white, black, result} ->
          Repo.insert!(%Pairing{
            round_id: round.id,
            match_id: match.id,
            board: (match_no - 1) * boards + k,
            white_player_id: white && white.id,
            black_player_id: black && black.id,
            result: result
          })
        end)
      end)

      entries
      |> Enum.filter(&match?({:bye, _}, &1))
      |> Enum.with_index(length(played) + 1)
      |> Enum.each(fn {{:bye, n}, match_no} ->
        Repo.insert!(%Match{
          round_id: round.id,
          board: match_no,
          team_a_id: Map.fetch!(by_number, n).id,
          team_b_id: nil
        })
      end)

      Tournaments.freeze_round_display_boards!(round.id)
      round
    end)
  end

  # Individual pairing numbers for everyone about to sit at a board, team by
  # team then board by board, continuing after the highest number issued.
  defp ensure_player_numbers(tournament, players_in_order) do
    missing = Enum.filter(players_in_order, &is_nil(&1.pairing_number))

    if missing == [] do
      players_in_order
    else
      start =
        (Repo.one(
           from p in Player,
             where: p.tournament_id == ^tournament.id and not is_nil(p.pairing_number),
             select: max(p.pairing_number)
         ) || 0) + 1

      numbered =
        missing
        |> Enum.with_index(start)
        |> Map.new(fn {p, n} ->
          {p.id, p |> Ecto.Changeset.change(pairing_number: n) |> Repo.update!()}
        end)

      Enum.map(players_in_order, &Map.get(numbered, &1.id, &1))
    end
  end
end
