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
  require Logger

  alias Ainalrami.TeamPairing
  alias PairingsEngine.{Repo, TeamRounds, TeamStandings, Tournaments}
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.{Match, Round, Team, Tournament}

  # The engine module actually called - overridable in tests
  # (`Application.put_env(:pairings_engine, :team_pairing_module, Stub)`) so
  # every refusal (`:budget_exhausted`, `:no_legal_pairing`, `:no_legal_bye`)
  # and a crash can be forced without a 300-500 team event. Same idiom as
  # `PairingsEngine.Fide.Sync.list_url/0` and friends.
  defp team_pairing_module,
    do: Application.get_env(:pairings_engine, :team_pairing_module, Ainalrami.TeamPairing)

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
      absent: absent,
      # The engine's reasons for the rationale page. Changes no pairing:
      # Ainalrami returns the same round with or without it.
      explain: true
    ]

    case team_pairing_module().pair_round(engine_teams, opts) do
      {:ok, result} ->
        entries = entries(result, Map.new(engine_teams, &{&1.tpn, &1}))

        with {:ok, round} <- TeamRounds.create_round(tournament, teams, entries, number) do
          if tournament.team_pairing_mode != "teams" do
            store_mode(tournament, "teams")
          end

          # What the engine reported, kept as the round's account for the
          # rationale page (`PairingsEngine.TeamRoundExplanation`).
          round =
            round
            |> Ecto.Changeset.change(
              explanation: explanation(result, engine_teams, teams, absent, opts)
            )
            |> Repo.update!()

          Tournaments.broadcast_tournament_change(tournament.id, :rounds)
          {:ok, round}
        end

      # `:budget_exhausted`, `:no_legal_pairing`, `:no_legal_bye`, and any
      # `{:invalid_option, ...}` - a REFUSAL, not a crash: nothing was
      # written above (`TeamRounds.create_round/4` never ran), so the round
      # stays unpaired and the tournament unchanged. The atom (with the
      # round number, for the message) travels up to
      # `PairingsEngineWeb.SettingsSupport.error_text/1`, which is where the
      # English/Dutch wording lives - never rendered here.
      {:error, reason} ->
        {:error, {:team_pairing, reason, number}}
    end
  rescue
    # The engine ran IN THIS BEAM - no subprocess, no timeout of its own.
    # An unhandled raise here would otherwise take the whole LiveView down
    # instead of leaving the round unpaired with a message. Nothing above
    # this point writes to the database (`TeamRounds.create_round/4` is
    # only reached from the `{:ok, result}` branch), so a crash here always
    # leaves the tournament exactly as it was.
    #
    # Logged WITHOUT player or team data - only the exception's type, the
    # tournament id and the round number - same discipline as
    # `PairingsEngine.Federations.BEL.Sync.crashed/4`.
    e ->
      Logger.error(
        "Team pairing crashed for tournament #{tournament.id} round #{number}: " <>
          "#{inspect(e.__struct__)}\n" <>
          Exception.format_stacktrace(Enum.take(__STACKTRACE__, 5))
      )

      {:error, {:team_pairing, :pairing_crashed, number}}
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

  ## ---------- the round's account ----------

  @doc """
  The account of a paired round, as stored on `rounds.explanation`: what
  `Ainalrami.TeamPairing.pair_round/2` returned with `explain: true`, plus
  what the engine was told, in JSON-safe form with string keys. Teams are
  named by their pairing numbers, with `"team_ids"` to resolve them.
  `"version"` 2; version 1 accounts (rounds paired before the engine reported
  its reasons) have no `"selection"` or rules and an older `"bye"`, and
  `PairingsEngine.TeamRoundExplanation` reads both.

    * `"teams"` - each team's state going into the round: match and game
      points, colours, colour preference (Art. 1.7, Type A), bye, forfeit
      win and float flags, opponents.
    * `"bye"` - the pairing-allocated bye (Art. 3.4), as the engine
      reported it: the teams [C2] barred and which clause, the teams it
      tried first and found would leave the rest unpairable (3.4.1), and
      the tie-break (3.4.2-3.4.4) that put the bye ahead of the next team.
    * `"brackets"` - per bracket (Art. 3.5/3.6): its score, residents,
      upfloaters, pairs, the [C8]/[C9]/[C10] values of the pairing chosen,
      how many candidates 3.6 examined, whether the search was exhaustive,
      and `"selection"`: the upfloater sets considered with their
      [C4]-[C7] values, the sets rejected for having no legal pairing, the
      chosen set, the runner-up and the criterion that decided.
    * `"pairs"` - colours as allocated (Art. 4): White, Black, the first
      team and the 4.2 clause that named it, the 4.3 clause that gave the
      colours, and the score difference.

  The recorded lists are bounded by the engine (ten entries each, the rest
  counted in the `*_omitted` fields); see `Ainalrami.TeamPairing.Explanation`.
  """
  def explanation(result, engine_teams, teams, absent, opts) do
    round = Keyword.get(opts, :round)
    expected = Keyword.get(opts, :expected_rounds)
    last_round? = not is_nil(round) and not is_nil(expected) and round >= expected
    last_two? = not is_nil(round) and not is_nil(expected) and round >= expected - 1
    reasons = Map.get(result, :explanation)
    selections = if reasons, do: Enum.map(reasons.brackets, & &1.selection), else: []
    rules = if reasons, do: Map.new(reasons.pairs, &{{&1.white, &1.black}, &1}), else: %{}

    %{
      "kind" => "team_swiss",
      # 1 when the engine reported no reasons (an Ainalrami without
      # `explain: true`): the page then shows what it has, with the note.
      "version" => if(reasons, do: 2, else: 1),
      "round" => round,
      "last_round" => last_round?,
      "last_two_rounds" => last_two?,
      "team_ids" => Map.new(teams, &{Integer.to_string(&1.pairing_number), &1.id}),
      "absent" => absent,
      "teams" =>
        engine_teams
        |> Enum.sort_by(& &1.tpn)
        |> Enum.map(fn team ->
          %{
            "tpn" => team.tpn,
            "match_points" => team.match_points,
            "game_points" => team.game_points,
            "colours" => Enum.map(team.colours, &Atom.to_string/1),
            "preference" => preference_json(TeamPairing.Team.preference(team, :a, last_round?)),
            "had_bye" => team.had_pab?,
            "won_by_forfeit" => team.won_by_forfeit?,
            "floated_last_round" => team.floated_last_round?,
            "opponents" => team.opponents
          }
        end),
      "bye" => result.bye && bye_json(reasons && reasons.bye, result.bye),
      "brackets" =>
        result.brackets
        |> Enum.with_index()
        |> Enum.map(fn {b, i} ->
          {c8, c9, c10} = b.criteria

          %{
            "score" => b.score,
            "residents" => b.residents,
            "upfloaters" => b.upfloaters,
            "pairs" => Enum.map(b.pairs, fn {x, y} -> [x, y] end),
            "c8" => c8,
            "c9" => c9,
            "c10" => c10,
            "candidates" => b.candidates,
            "exhaustive" => b.exhaustive?,
            "selection" => selection_json(Enum.at(selections, i))
          }
        end),
      "pairs" =>
        Enum.map(result.pairs, fn p ->
          rule = Map.get(rules, {p.white, p.black}, %{})

          %{
            "white" => p.white,
            "black" => p.black,
            "first_team" => p.first_team,
            "first_team_rule" => Map.get(rule, :first_team_rule),
            "colour_rule" => Map.get(rule, :colour_rule),
            "score_difference" => p.score_difference
          }
        end)
    }
  end

  defp preference_json(:none), do: nil
  defp preference_json({colour, strength}), do: "#{colour} #{strength}"

  # The engine's own account of the bye, in JSON. Nothing here is worked out
  # by OpenPairings: which teams were passed over for 3.4.1, and why the bye
  # ranks ahead of the next team, are what Ainalrami's 3.4 walk recorded.
  defp bye_json(nil, tpn), do: %{"tpn" => tpn}

  defp bye_json(bye, _tpn) do
    %{
      "tpn" => bye.tpn,
      "match_points" => bye.score,
      "matches_played" => bye.matches_played,
      "ineligible" =>
        Enum.map(bye.ineligible, fn i ->
          %{"tpn" => i.tpn, "reasons" => Enum.map(i.reasons, &reason_json/1)}
        end),
      "ineligible_omitted" => bye.ineligible_omitted,
      "passed_over" => Enum.map(bye.passed_over, &bye_team_json/1),
      "passed_over_omitted" => bye.passed_over_omitted,
      "next" => bye.next && bye_team_json(bye.next),
      "decided_by" => bye.decided_by
    }
  end

  defp bye_team_json(t),
    do: %{"tpn" => t.tpn, "match_points" => t.score, "matches_played" => t.matches_played}

  defp reason_json(:had_pab), do: "had_bye"
  defp reason_json(:won_by_forfeit), do: "won_by_forfeit"

  defp selection_json(nil), do: nil

  defp selection_json(s) do
    %{
      "c4" => s.c4,
      "sizes_without_legal_set" => s.sizes_without_legal_set,
      "chosen" => set_json(s.chosen),
      "runner_up" => s.runner_up && set_json(s.runner_up),
      "decided_by" => s.decided_by,
      "considered" => Enum.map(s.considered, &set_json/1),
      "considered_omitted" => s.considered_omitted,
      "rejected" =>
        Enum.map(s.rejected, fn r ->
          %{"upfloaters" => r.upfloaters, "c4" => r.c4, "c5" => r.c5, "failed" => r.failed}
        end),
      "rejected_omitted" => s.rejected_omitted
    }
  end

  defp set_json(set) do
    %{
      "upfloaters" => set.upfloaters,
      "c4" => set.c4,
      "c5" => set.c5,
      "c6" => set.c6,
      "c7" => set.c7
    }
  end

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
