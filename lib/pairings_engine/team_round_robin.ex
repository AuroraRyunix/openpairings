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

  ## Colours and line-ups

  The team the Berger table names first (its "White" number) is `team_a`,
  with White on board 1 and every odd board. How a match is seated - line-ups,
  reserves, forfeits, colours down the boards - is shared with team Swiss and
  lives in `PairingsEngine.TeamRounds`.

  Because round robin pairs its whole schedule in one click, every round's
  line-up reflects the roster as it stands at that click. A change afterwards
  (a player who drops out mid-event) is handled on the Pairings page like any
  other round: vacate the seat, fill it, or record the forfeit.
  """

  alias PairingsEngine.{RoundRobin, TeamRounds, Tournaments}
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.{Player, Round, Tournament}

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
    teams = TeamRounds.numbered_teams(tournament.id)

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
             {:ok, round} <-
               TeamRounds.create_round(tournament, teams, order(entries), next_number) do
          Tournaments.broadcast_tournament_change(tournament.id, :rounds)
          {:ok, round}
        end
    end
  end

  # Matches are numbered by their lower team number, byes last - the order
  # the round's match list and board numbers have always come out in.
  defp order(entries) do
    played =
      entries
      |> Enum.filter(&match?({:pairing, _, _}, &1))
      |> Enum.sort_by(fn {:pairing, w, b} -> min(w, b) end)

    played ++ Enum.filter(entries, &match?({:bye, _}, &1))
  end

  ## ---------- pure parts, shared with team Swiss ----------

  @doc "See `PairingsEngine.TeamRounds.lineup/3`."
  @spec lineup([Player.t()], pos_integer(), pos_integer()) :: [Player.t()]
  defdelegate lineup(roster, round_number, boards), to: TeamRounds

  @doc "See `PairingsEngine.TeamRounds.match_boards/3`."
  defdelegate match_boards(lineup_a, lineup_b, boards), to: TeamRounds

  @doc "Whether the first-named team has White on board `k` of a match."
  defdelegate team_a_white?(k), to: TeamRounds

  ## ---------- numbering ----------

  defp ensure_team_numbers(%Tournament{} = tournament) do
    unless Tournaments.teams_frozen?(tournament.id) do
      tournament.id
      |> Tournaments.list_teams()
      |> Enum.with_index(1)
      |> Enum.each(fn {team, n} ->
        team |> Ecto.Changeset.change(pairing_number: n) |> PairingsEngine.Repo.update!()
      end)
    end

    :ok
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
end
