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

  ## A plugin's table

  A plugin can fix the team numbers and the size of the Berger table
  (`PairingsEngine.Plugins.team_schedule/1`) - a league whose regulations
  give every series a table of twelve, say, numbers handed out by the
  league. A number without a team is a vacancy: its opponent has the bye
  that round. Every pairing is still a Berger pairing; but when the numbers
  are not simply 1..N, or the table is larger than N needs, the rounds are
  not the ones C.05 Annex 1 gives N teams, and the first round paired that
  way takes the tournament out of FIDE mode exactly as a soft rule does
  (`fide_compliance_lost_round`, see `PairingsEngine.Compliance`).

  Because round robin pairs its whole schedule in one click, every round's
  line-up reflects the roster as it stands at that click. A change afterwards
  (a player who drops out mid-event) is handled on the Pairings page like any
  other round: vacate the seat, fill it, or record the forfeit.
  """

  import Ecto.Query

  alias PairingsEngine.{Plugins, Repo, RoundRobin, TeamRounds, Tournaments}
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.{Player, Round, Team, Tournament}

  @doc "Pairs the next round of the team Berger schedule. Same contract as `RoundRobin.pair_next_round/1`."
  @spec pair_next_round(Tournament.t()) :: {:ok, Round.t()} | {:error, term()}
  def pair_next_round(%Tournament{} = tournament) do
    tournament
    |> prepare()
    |> case do
      {:ok, tournament, teams, size} -> do_pair_next_round(tournament, teams, size)
      {:error, _} = error -> error
    end
    |> release_numbers_on_refusal(tournament)
  end

  @doc """
  Pairs every remaining round in one call - `RoundRobin.pair_all_rounds/1`'s
  team counterpart, which it delegates to after its own writability gate.
  """
  @spec pair_all_rounds(Tournament.t()) :: {:ok, pos_integer()} | {:error, term()}
  def pair_all_rounds(%Tournament{} = tournament) do
    tournament
    |> prepare()
    |> case do
      {:ok, tournament, teams, size} -> pair_remaining(tournament, teams, size)
      {:error, _} = error -> error
    end
    |> release_numbers_on_refusal(tournament)
  end

  # `prepare/1` numbers the teams before anything can refuse (too few
  # teams, a schedule past the round limit). A refusal with no round on the
  # board gives the numbers back, as unpairing the last round does - a draw
  # that never happened must not freeze the Teams page.
  defp release_numbers_on_refusal({:error, _} = error, tournament) do
    Tournaments.release_team_numbers_if_unpaired(tournament.id)
    error
  end

  defp release_numbers_on_refusal(result, _tournament), do: result

  defp pair_remaining(tournament, teams, size) do
    case tournament |> do_pair_next_round(teams, size) |> RoundRobin.after_step() do
      :continue ->
        pair_remaining(tournament, teams, size)

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
    # Before the first draw, teams nobody ordered by hand are seeded by
    # rating (`Tournaments.auto_seed_teams/1`); a no-op once numbered.
    plan = Plugins.team_schedule(tournament)
    Tournaments.auto_seed_teams(tournament)

    with :ok <- ensure_team_numbers(tournament, plan) do
      teams = TeamRounds.numbered_teams(tournament.id)
      size = table_size(teams, plan)

      if is_nil(size) do
        {:error,
         "The team numbers have gaps, which only a plugin's schedule can pair, " <>
           "and no plugin gives this tournament one."}
      else
        case ensure_correct_rounds_count(tournament, size) do
          {:error, _} = error -> error
          corrected -> {:ok, corrected, teams, size}
        end
      end
    end
  end

  # The Berger table's size: the plugin's, or the team count - which is
  # only right when the numbers run 1..N without a gap.
  defp table_size(teams, %{size: size}) when is_integer(size), do: max(size, length(teams))

  defp table_size(teams, _no_plan) do
    if Enum.map(teams, & &1.pairing_number) == Enum.to_list(1..length(teams)//1),
      do: length(teams)
  end

  defp do_pair_next_round(tournament, teams, size) do
    next_number = Engine.paired_rounds_count(tournament.id) + 1

    cond do
      length(teams) < 2 ->
        {:error, "At least two teams are needed"}

      next_number > tournament.rounds_count ->
        {:error, {:all_rounds_paired, tournament.rounds_count}}

      true ->
        schedule =
          if tournament.rr_match_format,
            do: RoundRobin.match_schedule(size, next_number),
            else: RoundRobin.schedule(size, tournament.rr_cycles, next_number)

        with {:ok, entries} <- schedule,
             entries = fill_vacancies(entries, teams),
             {:ok, round} <-
               TeamRounds.create_round(tournament, teams, order(entries), next_number) do
          record_table_departure(tournament, teams, size, next_number)
          Tournaments.broadcast_tournament_change(tournament.id, :rounds)
          {:ok, round}
        end
    end
  end

  # A pairing against a number no team holds is a bye for the other team; a
  # pairing of two vacancies, or the odd table's dummy against one, is
  # nothing. With no vacancy this returns `entries` unchanged.
  defp fill_vacancies(entries, teams) do
    held = MapSet.new(teams, & &1.pairing_number)

    Enum.flat_map(entries, fn
      {:pairing, w, b} ->
        case {MapSet.member?(held, w), MapSet.member?(held, b)} do
          {true, true} -> [{:pairing, w, b}]
          {true, false} -> [{:bye, w}]
          {false, true} -> [{:bye, b}]
          {false, false} -> []
        end

      {:bye, n} ->
        if MapSet.member?(held, n), do: [{:bye, n}], else: []
    end)
  end

  # The rounds a plugin's table gives are C.05 Annex 1's for N teams only
  # when the teams hold 1..N and the table is the one N needs (N, or N + 1
  # with the dummy on the last number). Otherwise the first round paired
  # from it is where the tournament stopped matching the FIDE rules -
  # recorded the way `Pairing` records a soft rule that moved a board.
  defp record_table_departure(tournament, teams, size, round_number) do
    n = length(teams)
    plain = Enum.map(teams, & &1.pairing_number) == Enum.to_list(1..n//1)
    plain_size = if rem(n, 2) == 0, do: n, else: n + 1

    if is_nil(tournament.fide_compliance_lost_round) and
         not (plain and size in [n, plain_size]) do
      Repo.update_all(
        from(t in Tournament,
          where: t.id == ^tournament.id and is_nil(t.fide_compliance_lost_round)
        ),
        set: [fide_compliance_lost_round: round_number]
      )
    end

    :ok
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

  defp ensure_team_numbers(%Tournament{} = tournament, plan) do
    cond do
      Tournaments.teams_frozen?(tournament.id) ->
        :ok

      is_map(plan) ->
        teams = Tournaments.list_teams(tournament.id)
        numbers = plan.numbers

        if Enum.all?(teams, &Map.has_key?(numbers, &1.id)) do
          Enum.each(teams, fn %Team{} = team ->
            team
            |> Ecto.Changeset.change(pairing_number: Map.fetch!(numbers, team.id))
            |> Repo.update!()
          end)
        else
          {:error, "A plugin sets this tournament's team numbers, and not every team has one."}
        end

      true ->
        tournament.id
        |> Tournaments.list_teams()
        |> Enum.with_index(1)
        |> Enum.each(fn {team, n} ->
          team |> Ecto.Changeset.change(pairing_number: n) |> Repo.update!()
        end)
    end
    |> case do
      {:error, _} = error -> error
      _ -> :ok
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
end
