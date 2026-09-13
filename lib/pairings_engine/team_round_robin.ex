defmodule PairingsEngine.TeamRoundRobin do
  @moduledoc """
  Round robin for teams: the Berger table (FIDE Handbook C.05 Annex 1) run
  over TEAMS, each scheduled pairing played as a match of `team_boards`
  individual games, board against board in board order.

  `PairingsEngine.RoundRobin` dispatches here for a tournament where
  `Tournament.team_round_robin?/1` holds. The schedule itself is not
  reimplemented: `RoundRobin.schedule/3` and `RoundRobin.match_schedule/2` are
  pure functions of `(count, cycles, round)` and are called with the team
  count, so a team event gets the same Berger tables, the same odd-count bye
  and the same second-cycle colour reversal an individual one does. See
  `docs/team-tournaments.md`.

  ## Pairing numbers

  Teams are numbered 1..N from the Teams page's seeding order the first time
  a round is paired, and frozen (`teams.pairing_number`) - C.04.6 Art. 1.1
  leaves the order to the competition's rules or the Chief Arbiter, and the
  Teams page is where the arbiter sets it. A team created afterwards is never
  scheduled, for the same reason a late player is not in an individual round
  robin: every other team's opponents are already fixed.

  Players on a team are given individual pairing numbers too - team by team
  in team-number order, board order within a team - because the TRF report
  identifies every game by them. A reserve added later is numbered when a
  round that includes them is paired.

  ## Colours in a match

  **The team the Berger table names first (its "White" number) is `team_a`,
  and `team_a` has White on board 1 and on every odd board, Black on every
  even board.** Colours alternate down the boards so each team has as many
  Whites as Blacks over an even-sized match.

  Where that comes from: C.04.6 Art. 1.6.1 (read from the local FIDE text)
  defines a team's colour in a match as the colour of its board-1 player, so
  the board-1 colour is the one the schedule must decide, and here it follows
  the Berger table exactly. That the colours then alternate board by board,
  the first team taking the odd boards, is the convention of FIDE team
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
  created at all - there is no game and nobody to score. Unequal rosters need
  nothing special: the shorter team simply runs out of players first.

  Because round robin pairs its whole schedule in one click, every round's
  line-up reflects the roster as it stands at that click. A change afterwards
  (a player who drops out mid-event) is handled on the Pairings page like any
  other round: vacate the seat, fill it, or record the forfeit.
  """

  import Ecto.Query

  alias PairingsEngine.{Repo, RoundRobin, Tournaments}
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.{Match, Pairing, Player, Round, Team, Tournament}

  @doc "Pairs the next round of the team Berger schedule. Same contract as `RoundRobin.pair_next_round/1`."
  @spec pair_next_round(Tournament.t()) :: {:ok, Round.t()} | {:error, term()}
  def pair_next_round(%Tournament{} = tournament) do
    with {:ok, tournament, teams} <- prepare(tournament) do
      do_pair_next_round(tournament, teams)
    end
  end

  @doc """
  Pairs every remaining round in one call - `RoundRobin.pair_all_rounds/1`'s
  team counterpart, which it delegates to after its own writability gate.
  """
  @spec pair_all_rounds(Tournament.t()) :: {:ok, pos_integer()} | {:error, term()}
  def pair_all_rounds(%Tournament{} = tournament) do
    with {:ok, tournament, teams} <- prepare(tournament) do
      pair_remaining(tournament, teams)
    end
  end

  defp pair_remaining(tournament, teams) do
    case tournament |> do_pair_next_round(teams) |> RoundRobin.after_step() do
      :continue ->
        pair_remaining(tournament, teams)

      :schedule_complete ->
        Tournaments.refresh_status!(tournament.id)
        {:ok, Engine.paired_rounds_count(tournament.id)}

      {:error, _reason} = error ->
        error
    end
  end

  # Freeze the team numbers once, then read the frozen teams and correct
  # `rounds_count` to what their Berger table needs - the same three steps
  # `RoundRobin` takes over players, for the same reasons.
  defp prepare(tournament) do
    ensure_team_numbers(tournament)
    teams = frozen_teams(tournament.id)

    case ensure_correct_rounds_count(tournament, length(teams)) do
      {:error, _} = error -> error
      corrected -> {:ok, corrected, teams}
    end
  end

  defp do_pair_next_round(tournament, teams) do
    next_number = Engine.paired_rounds_count(tournament.id) + 1

    cond do
      length(teams) < 2 ->
        {:error, "At least two teams are needed"}

      next_number > tournament.rounds_count ->
        {:error, {:all_rounds_paired, tournament.rounds_count}}

      true ->
        schedule =
          if tournament.rr_match_format,
            do: RoundRobin.match_schedule(length(teams), next_number),
            else: RoundRobin.schedule(length(teams), tournament.rr_cycles, next_number)

        with {:ok, entries} <- schedule,
             {:ok, round} <- create_round(tournament, teams, entries, next_number) do
          Tournaments.broadcast_tournament_change(tournament.id, :rounds)
          {:ok, round}
        end
    end
  end

  ## ---------- pure parts ----------

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

  defp available?(%Player{} = p, round_number) do
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

  ## ---------- numbering ----------

  defp ensure_team_numbers(%Tournament{} = tournament) do
    unless Tournaments.teams_frozen?(tournament.id) do
      tournament.id
      |> Tournaments.list_teams()
      |> Enum.with_index(1)
      |> Enum.each(fn {team, n} ->
        team |> Ecto.Changeset.change(pairing_number: n) |> Repo.update!()
      end)
    end

    :ok
  end

  defp frozen_teams(tournament_id) do
    Repo.all(
      from t in Team,
        where: t.tournament_id == ^tournament_id and not is_nil(t.pairing_number),
        order_by: t.pairing_number
    )
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

  defp ensure_correct_rounds_count(tournament, team_count) when team_count >= 2 do
    correct =
      if tournament.rr_match_format,
        do: RoundRobin.match_total_rounds(team_count),
        else: RoundRobin.total_rounds(team_count, tournament.rr_cycles)

    if tournament.rounds_count == correct do
      tournament
    else
      case Tournaments.update_tournament(tournament, %{rounds_count: correct}) do
        {:ok, updated} ->
          updated

        {:error, %Ecto.Changeset{}} ->
          {:error,
           "A round robin with #{team_count} teams needs #{correct} rounds, " <>
             "which is above the #{Tournament.max_rounds()}-round maximum this app supports."}
      end
    end
  end

  defp ensure_correct_rounds_count(tournament, _team_count), do: tournament

  ## ---------- writing a round ----------

  defp create_round(tournament, teams, entries, number) do
    by_number = Map.new(teams, &{&1.pairing_number, &1})
    boards = tournament.team_boards

    rosters =
      Map.new(teams, fn team -> {team.id, Tournaments.team_roster(tournament.id, team.id)} end)

    lineups =
      Map.new(teams, fn team ->
        {team.id, lineup(Map.fetch!(rosters, team.id), number, boards)}
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

      played =
        entries
        |> Enum.filter(&match?({:pairing, _, _}, &1))
        |> Enum.sort_by(fn {:pairing, w, b} -> min(w, b) end)

      played
      |> Enum.with_index(1)
      |> Enum.each(fn {{:pairing, w, b}, match_no} ->
        team_a = Map.fetch!(by_number, w)
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
end
