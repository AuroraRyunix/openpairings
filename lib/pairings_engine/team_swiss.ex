defmodule PairingsEngine.TeamSwiss do
  @moduledoc """
  Swiss for teams: FIDE C.04.6, the Swiss Team Pairing System (effective
  1 February 2026), paired by `Ainalrami.TeamPairing` team against team, each
  pairing then played as a match of `team_boards` individual games exactly
  as a team round robin seats one (`PairingsEngine.TeamRounds`).

  `PairingsEngine.Pairing.pair_next_round/1` dispatches here for a tournament
  where `Tournament.team_swiss?/1` holds. See `docs/team-tournaments.md`.

  ## Old team Swiss events stay player by player

  Before this module existed a Swiss (teams) was paired player by player on
  the individual Swiss path. Such an event is not converted mid-way: C.04.6
  pairs from a team history those rounds do not have. `team_pairing_mode`
  tells the two apart - "players" for an event already paired player by
  player (the migration set it on every team Swiss with a round), "teams"
  once this module has paired a round, nil while nothing is paired (and so
  the next pairing is by teams). `settle_mode/1` fills in a nil the database
  can already answer, for data that arrived without the flag.

  ## What the engine is told, per round

  Built from the stored matches of every earlier round
  (`PairingsEngine.TeamStandings.matches/2`), per team:

    * `match_points` / `game_points` - including the pairing-allocated bye's
      draw (C.04.6 Art. 1.4), as `TeamStandings` scores it;
    * `opponents` - the teams it has PLAYED. A match in which no game was
      played is not a meeting (C.04.2 Art. 3.5: "two paired participants,
      who did not play their game or match, may be paired together in a
      future round");
    * `colours` - its board-1 colour in each match actually played (C.04.6
      Art. 1.6.1): White as team A, Black as team B. Byes and unplayed
      matches add nothing;
    * `had_pab?` - an earlier bye;
    * `won_by_forfeit?` - `won_match_by_forfeit?/1`, open question 6;
    * `floated_last_round?` - `floated?/3`: paired in the previous round
      against a team on a different score (Art. 1.5).

  A team is in the round's field when at least one of its players can sit at
  a board that round (`TeamRounds.lineup/3`). A team that cannot field
  anyone sits the round out: not paired, no match written. If it has played
  (or had a bye) before, it is passed as `:absent`, so it keeps its place in
  Art. 4.3.1's arrival numbering.

  Options: match points primary with game points for colours (Art. 1.2.2),
  Type A colour preferences (Art. 1.7) - the FIDE defaults, and the only
  ones offered - `round`/`expected_rounds` from the tournament, and the
  initial colour drawn by lot before round 1 (Art. 4.1,
  `Tournaments.ensure_initial_colour/2`).

  ## Team numbers

  Teams are numbered in the Teams page's seeding order when round 1 is
  paired, as in a team round robin. A team added later is numbered after the
  highest number issued when it is first paired, and nobody is renumbered
  (C.04.6 Art. 1.1.3 allows changes only under General Handling 2.4/2.5).

  ## Match order

  The round's matches, and so its board numbers, follow C.04.2 Art. 3.6's
  recommended order: the higher score of the pair's first team, then the
  higher sum of both scores, then the smaller number of the first team.
  """

  import Ecto.Query

  alias Ainalrami.TeamPairing
  alias PairingsEngine.{Repo, TeamRounds, TeamStandings, Tournaments}
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.{Match, Round, Team, Tournament}

  @doc """
  Fills in `team_pairing_mode` when it is nil and the database already
  decides it: rounds with matches were paired by teams, rounds without any
  were paired player by player. Nothing paired leaves it nil. Returns the
  tournament, updated when it changed.
  """
  def settle_mode(%Tournament{type: "team-swiss", team_pairing_mode: nil} = t) do
    round_ids = Repo.all(from r in Round, where: r.tournament_id == ^t.id, select: r.id)

    cond do
      round_ids == [] ->
        t

      Repo.exists?(from m in Match, where: m.round_id in ^round_ids) ->
        store_mode(t, "teams")

      true ->
        store_mode(t, "players")
    end
  end

  def settle_mode(%Tournament{} = t), do: t

  defp store_mode(t, mode),
    do: t |> Ecto.Changeset.change(team_pairing_mode: mode) |> Repo.update!()

  @doc "Pairs the next round. Same contract as `PairingsEngine.TeamRoundRobin.pair_next_round/1`."
  @spec pair_next_round(Tournament.t()) :: {:ok, Round.t()} | {:error, term()}
  def pair_next_round(%Tournament{} = tournament) do
    paired = Engine.paired_rounds_count(tournament.id)
    next = paired + 1

    cond do
      next > tournament.rounds_count ->
        {:error, {:all_rounds_paired, tournament.rounds_count}}

      not Engine.round_complete?(tournament.id, paired) ->
        {:error, "Round #{paired} still has missing results"}

      true ->
        ensure_team_numbers(tournament)
        teams = TeamRounds.numbered_teams(tournament.id)
        {field, _sitting_out} = split_field(tournament, teams, next)

        if length(field) < 2 do
          {:error, "At least two teams with a player available for round #{next} are needed"}
        else
          tournament =
            if next == 1, do: Tournaments.ensure_initial_colour(tournament), else: tournament

          pair_round(tournament, teams, field, next)
        end
    end
  end

  defp pair_round(tournament, teams, field, number) do
    %{teams: engine_teams, absent: absent} = engine_input(tournament, teams, field, number)

    opts = [
      score_mode: :match_points,
      type: :a,
      round: number,
      expected_rounds: tournament.rounds_count,
      initial_colour: initial_colour(tournament),
      absent: absent
    ]

    case TeamPairing.pair_round(engine_teams, opts) do
      {:ok, result} ->
        entries = entries(result, Map.new(engine_teams, &{&1.tpn, &1}))

        with {:ok, round} <- TeamRounds.create_round(tournament, teams, entries, number) do
          if tournament.team_pairing_mode != "teams" do
            store_mode(tournament, "teams")
          end

          Tournaments.broadcast_tournament_change(tournament.id, :rounds)
          {:ok, round}
        end

      {:error, reason} ->
        {:error, refusal(reason)}
    end
  end

  defp initial_colour(tournament) do
    case Tournament.effective_initial_colour(tournament) do
      "black" -> :black
      _ -> :white
    end
  end

  # C.04.2 Art. 3.6 for the order of the pairs; the bye last.
  defp entries(result, by_tpn) do
    played =
      result.pairs
      |> order_pairs(by_tpn)
      |> Enum.map(&{:pairing, &1.white, &1.black})

    played ++ if(result.bye, do: [{:bye, result.bye}], else: [])
  end

  @doc """
  Pairs `%{white: tpn, black: tpn, first_team: tpn}` in C.04.2 Art. 3.6's
  recommended order: the higher match-point score of the pair's first team,
  then the higher sum of both scores, then the smaller number of the first
  team. `by_tpn` maps each number to its `%Ainalrami.TeamPairing.Team{}`.
  Shared with the TRF import, which rebuilds a team Swiss's match numbers the
  way the pairing wrote them.
  """
  def order_pairs(pairs, by_tpn) do
    score = fn tpn -> by_tpn |> Map.fetch!(tpn) |> Map.fetch!(:match_points) end

    Enum.sort_by(pairs, fn p ->
      {-score.(p.first_team), -(score.(p.white) + score.(p.black)), p.first_team}
    end)
  end

  defp refusal(:no_legal_bye),
    do:
      "No team can take the bye this round without breaking the pairing rules: every team that could has already had one or won a match by forfeit, or the rest could not then be paired (C.04.6 3.3.3 leaves this to the Chief Arbiter)."

  defp refusal(:no_legal_pairing),
    do:
      "The teams cannot all be paired this round without a repeat meeting (C.04.6 3.3.3 leaves this to the Chief Arbiter)."

  defp refusal(:budget_exhausted),
    do: "The team pairing search gave up before finding a pairing. Nothing was paired."

  defp refusal(other), do: "The team pairing failed: #{inspect(other)}"

  ## ---------- the field ----------

  @doc """
  Splits the numbered `teams` into those that can field at least one player
  in round `number` and those that cannot.
  """
  def split_field(%Tournament{} = tournament, teams, number) do
    boards = max(tournament.team_boards || 1, 1)

    Enum.split_with(teams, fn team ->
      tournament.id
      |> Tournaments.team_roster(team.id)
      |> TeamRounds.lineup(number, boards)
      |> Kernel.!=([])
    end)
  end

  defp ensure_team_numbers(tournament) do
    teams = Tournaments.list_teams(tournament.id)
    missing = Enum.filter(teams, &is_nil(&1.pairing_number))

    if missing != [] do
      start =
        (teams
         |> Enum.map(& &1.pairing_number)
         |> Enum.reject(&is_nil/1)
         |> Enum.max(fn -> 0 end)) + 1

      missing
      |> Enum.with_index(start)
      |> Enum.each(fn {team, n} ->
        team |> Ecto.Changeset.change(pairing_number: n) |> Repo.update!()
      end)
    end

    :ok
  end

  ## ---------- what the engine is told ----------

  @doc """
  The engine's view of round `number`: `%{teams: [%Ainalrami.TeamPairing.Team{}],
  absent: [tpn]}` - the structs for the teams in `field`, built from every
  match before round `number`, and the numbers of the teams that have
  arrived but are not in `field`. Public so the history reading can be
  tested on its own.
  """
  def engine_input(%Tournament{} = tournament, teams, field, number) do
    matches = TeamStandings.matches(tournament, through_round: number - 1)
    tpn = Map.new(teams, &{&1.id, &1.pairing_number})

    records = Map.new(teams, fn team -> {team.id, records_for(team.id, matches)} end)
    field_ids = MapSet.new(field, & &1.id)

    engine_teams =
      for team <- field do
        team_struct(team, Map.fetch!(records, team.id), records, tpn, number)
      end

    absent =
      for team <- teams,
          not MapSet.member?(field_ids, team.id),
          Map.fetch!(records, team.id) != [],
          do: team.pairing_number

    %{teams: engine_teams, absent: Enum.sort(absent)}
  end

  defp team_struct(%Team{} = team, records, all_records, tpn, number) do
    played = Enum.filter(records, & &1.played?)

    %TeamPairing.Team{
      tpn: team.pairing_number,
      match_points: records |> Enum.map(&(&1.mp || 0.0)) |> Enum.sum() |> round1(),
      game_points: records |> Enum.map(& &1.gp) |> Enum.sum() |> round1(),
      opponents: Enum.map(played, &Map.fetch!(tpn, &1.opponent_id)),
      colours: Enum.map(played, & &1.colour),
      had_pab?: Enum.any?(records, & &1.bye?),
      won_by_forfeit?: Enum.any?(records, &won_match_by_forfeit?/1),
      floated_last_round?: floated?(records, all_records, number - 1)
    }
  end

  # One team's matches, from its own side, oldest first.
  defp records_for(team_id, matches) do
    matches
    |> Enum.flat_map(fn m ->
      cond do
        m.team_a_id == team_id -> [record(m, :a)]
        m.team_b_id == team_id -> [record(m, :b)]
        true -> []
      end
    end)
    |> Enum.sort_by(& &1.round)
  end

  defp record(m, side) do
    {opp, mp, gp, opp_gp, colour} =
      case side do
        :a -> {m.team_b_id, m.mp_a, m.gp_a, m.gp_b, :white}
        :b -> {m.team_a_id, m.mp_b, m.gp_b, m.gp_a, :black}
      end

    team_id = if side == :a, do: m.team_a_id, else: m.team_b_id

    %{
      round: m.round,
      opponent_id: opp,
      bye?: m.bye?,
      forfeit_decision: forfeit_decision(Map.get(m, :forfeited_to), team_id),
      played?: not m.bye? and TeamStandings.match_played?(m),
      mp: mp,
      gp: gp,
      opp_gp: opp_gp,
      colour: colour
    }
  end

  @doc """
  OPEN QUESTION 6 - what C.04.6 [C2] (Art. 2.1.2) means by a team that "won a
  match by forfeit". The reading lives here and nowhere else.

  A match is won by forfeit when NO GAME of it was played and this team
  scored more game points: in practice the opponent did not turn up as a
  team, so every board it should have filled was forfeited. A match with at
  least one game played is a played match, and does not bar the team from
  the pairing-allocated bye, however many other boards were forfeited.

  The research note of 2026-09-13 (Ainalrami's
  docs/conformance-c0406-teams.md, "Research findings") puts this at high
  confidence: the 2024 edition's [C2] said "without playing"; Double-Swiss
  C.04.5, which shares the 2026 wording word for word, says a match "ends by
  forfeit only if at least one player forfeits both games" and treats any
  single forfeit inside a match as played; TRF-2026's record 330 is "one or
  both teams didn't show up", a team showing up "if at least one player is
  present"; the 2026 Olympiad regulations define an unplayed match as one
  where "all games were scored as defaults". Both teams defaulting some
  boards with none played is still an unplayed match, won by the team with
  more game points.

  A match the arbiter FORFEITED BY DECISION (`PairingsEngine.TeamMatches.
  forfeit_match/3`, `forfeit_decision` here) is won by forfeit by the team
  it was awarded to, whether or not games were played before the decision,
  and never by the other team. The research note gives that part medium
  confidence: Swiss-Manager keeps a match-level forfeit flag the arbiter
  sets, TRF-2026's record 330 records forfeits at match level, and the
  model it proposes bars the bye on that recorded status. Not an SPP ruling.
  """
  def won_match_by_forfeit?(%{bye?: true}), do: false
  def won_match_by_forfeit?(%{forfeit_decision: :won}), do: true
  def won_match_by_forfeit?(%{forfeit_decision: :lost}), do: false
  def won_match_by_forfeit?(%{played?: true}), do: false
  def won_match_by_forfeit?(%{gp: gp, opp_gp: opp_gp}), do: gp > opp_gp

  defp forfeit_decision(nil, _team_id), do: nil
  defp forfeit_decision(team_id, team_id), do: :won
  defp forfeit_decision(_winner, _team_id), do: :lost

  # C.04.6 Art. 1.5: "a team that plays against an opponent with a different
  # score". Read on the PAIRING: a team paired in round `previous` against a
  # team on a different match-point score before that round floated, whether
  # the match was then played or forfeited - the pairing is what floated it,
  # and [C7]/[C10] exist to spread pairings, not results. A bye has no
  # opponent and is not a float.
  defp floated?(_records, _all, previous) when previous < 1, do: false

  defp floated?(records, all_records, previous) do
    case Enum.find(records, &(&1.round == previous and not &1.bye?)) do
      nil ->
        false

      match ->
        score_before(records, previous) !=
          score_before(Map.get(all_records, match.opponent_id, []), previous)
    end
  end

  defp score_before(records, round) do
    records
    |> Enum.filter(&(&1.round < round))
    |> Enum.map(&(&1.mp || 0.0))
    |> Enum.sum()
    |> round1()
  end

  defp round1(v), do: Float.round(v / 1, 1)
end
