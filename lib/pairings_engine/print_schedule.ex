defmodule PairingsEngine.PrintSchedule do
  @moduledoc """
  Every round of a tournament as one list, for the printed schedule and the
  filled-in player cards (`PairingsEngineWeb.SchedulePrintController`).

  A round already paired is read as it is stored. A round robin's rounds not
  paired yet are worked out the way pairing them will work them out -
  nothing is re-derived here:

    * individual: `RoundRobin.schedule_field/1` (the frozen field, or the
      numbering round 1 would hand out), `RoundRobin.planned_matches/3` and
      `RoundRobin.board_layout/2` - the very functions `RoundRobin` writes a
      round from - and `PairingDisplay.compute_labels/1` for the board
      labels, as `Tournaments.freeze_round_display_boards!/1` freezes them;
    * teams: `TeamRoundRobin.schedule_field/1`,
      `TeamRoundRobin.planned_entries/4` and `TeamRounds.planned_matches/4`,
      which `TeamRounds.create_round/4` seats a round from.

  So what is printed for round 7 is what "pair round 7" writes, as long as
  nothing it reads changes in between. Two things can still move it, and the
  printout says so (`:certainty`):

    * `:until_round_one` - round 1 is not paired. The table is fixed by the
      first pairing: an entry, a withdrawal or new starting numbers before
      then renumbers it.
    * `:table` - the field is frozen. A round not paired yet changes only if
      the arbiter swaps rounds, pairs one by hand, or changes the cycles or
      categories. A team round's line-ups are the rosters as they stand now:
      an absence or a reserve changes who sits down, never who plays whom.

  Swiss and Keizer have no future to print: their paired rounds are listed
  and the rest stay empty (`:projected?` false, no rows).
  """

  import Ecto.Query

  alias PairingsEngine.{
    PairingDisplay,
    Repo,
    Results,
    RoundRobin,
    TeamRoundRobin,
    TeamRounds,
    TeamStandings,
    Tournaments
  }

  alias PairingsEngine.Tournaments.{Pairing, Round, Tournament}

  @type round_entry :: %{
          number: pos_integer(),
          date: String.t() | nil,
          paired?: boolean(),
          projected?: boolean(),
          rows: [%{pairing: Pairing.t(), board: String.t()}],
          byes: [%{player: map(), type: String.t()}]
        }

  @doc "Whether the tournament plays a fixed schedule worth printing whole."
  def round_robin?(%Tournament{pairing_system: "round_robin"}), do: true
  def round_robin?(_tournament), do: false

  @doc """
  Every round of an individual tournament: `{:ok, %{rounds: [round_entry],
  certainty: :final | :table | :until_round_one | :swiss, first_unpaired:
  n | nil}}`, or `{:error, reason}` when a round robin cannot be scheduled
  yet (fewer than two players).
  """
  def individual(%Tournament{} = t) do
    paired = paired_rounds(t)
    byes = byes_by_round(t)

    if round_robin?(t) do
      field = RoundRobin.schedule_field(t)
      total = max(RoundRobin.scheduled_rounds(t, field), map_size(paired))

      if total == 0 do
        {:error, :too_few_players}
      else
        rounds =
          for n <- 1..total do
            case Map.get(paired, n) do
              %Round{} = round -> paired_entry(t, round, Map.get(byes, n, []))
              nil -> planned_entry(t, field, n)
            end
          end

        {:ok,
         %{
           rounds: rounds,
           certainty: certainty(t, rounds),
           first_unpaired: first_unpaired(rounds)
         }}
      end
    else
      total = max(t.rounds_count || 0, map_size(paired))

      rounds =
        for n <- 1..total//1 do
          case Map.get(paired, n) do
            %Round{} = round -> paired_entry(t, round, Map.get(byes, n, []))
            nil -> empty_entry(t, n)
          end
        end

      {:ok, %{rounds: rounds, certainty: :swiss, first_unpaired: first_unpaired(rounds)}}
    end
  end

  defp certainty(t, rounds) do
    cond do
      Enum.all?(rounds, & &1.paired?) -> :final
      RoundRobin.schedule_frozen?(t) -> :table
      true -> :until_round_one
    end
  end

  defp first_unpaired(rounds) do
    Enum.find_value(rounds, fn r -> if r.paired?, do: nil, else: r.number end)
  end

  @doc "Round `n`'s date from Settings → Dates, nil when none is set."
  def round_date(%Tournament{round_dates: dates}, n) do
    case Enum.at(dates || [], n - 1) do
      date when is_binary(date) and date != "" -> date
      _ -> nil
    end
  end

  defp paired_rounds(t) do
    from(r in Round.without_explanation(),
      where: r.tournament_id == ^t.id,
      order_by: r.number,
      preload: [pairings: [:white_player, :black_player]]
    )
    |> Repo.all()
    |> Map.new(&{&1.number, &1})
  end

  defp byes_by_round(t) do
    players = t.id |> Tournaments.list_players() |> Map.new(&{&1.id, &1})

    t.id
    |> Tournaments.list_byes_from_round(1)
    |> Enum.flat_map(fn bye ->
      case Map.get(players, bye.player_id) do
        nil -> []
        player -> [{bye.round, %{player: player, type: bye.type}}]
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp paired_entry(t, round, byes) do
    %{
      number: round.number,
      date: round_date(t, round.number),
      paired?: true,
      projected?: false,
      rows: round.pairings |> Enum.reject(& &1.hidden) |> PairingDisplay.with_display_boards(),
      byes: Enum.sort_by(byes, & &1.player.pairing_number)
    }
  end

  defp empty_entry(t, n) do
    %{number: n, date: round_date(t, n), paired?: false, projected?: false, rows: [], byes: []}
  end

  # A round robin's round not paired yet, as pairing it would write it. The
  # boards are in-memory `Pairing` structs carrying the labels the round
  # will freeze, so the printout reads them like any paired round's.
  defp planned_entry(t, field, n) do
    case RoundRobin.planned_matches(t, field, n) do
      {:ok, matches} ->
        layout = RoundRobin.board_layout(t, matches)

        pairings =
          Enum.map(layout.boards, fn {board, white, black, _result} ->
            # The forfeit an absent player is written with is decided on the
            # day the round is paired, from who is absent then: a result,
            # and not the schedule's to promise.
            %Pairing{
              id: -board,
              board: board,
              result: if(black, do: "", else: "bye"),
              white_player: white,
              white_player_id: white.id,
              black_player: black,
              black_player_id: black && black.id
            }
          end)

        labels = PairingDisplay.compute_labels(pairings)

        pairings =
          Enum.map(pairings, fn p ->
            %{display_board: label, display_special: special} = Map.fetch!(labels, p.id)
            %{p | display_board: label, display_special: special}
          end)

        %{
          number: n,
          date: round_date(t, n),
          paired?: false,
          projected?: true,
          rows: PairingDisplay.with_display_boards(pairings),
          byes:
            layout.byes
            |> Enum.map(&%{player: &1, type: "requested-zero"})
            |> Enum.sort_by(& &1.player.pairing_number)
        }

      {:error, _reason} ->
        empty_entry(t, n)
    end
  end

  ## ---------- one player's rounds ----------

  @doc """
  One row per round of `schedule` (`individual/1`) for `player`: `%{round:,
  date:, board:, colour: :w | :b | nil, opponent:, pairing:, bye: type |
  nil, projected?:}`. A round the player is not in has nil throughout.
  """
  def player_rows(%{rounds: rounds}, player) do
    Enum.map(rounds, fn round ->
      base = %{
        round: round.number,
        date: round.date,
        board: nil,
        colour: nil,
        opponent: nil,
        pairing: nil,
        bye: nil,
        projected?: round.projected?
      }

      seat =
        Enum.find_value(round.rows, fn %{pairing: p, board: board} ->
          cond do
            p.white_player_id == player.id ->
              %{board: board, colour: :w, opponent: p.black_player, pairing: p}

            p.black_player_id == player.id ->
              %{board: board, colour: :b, opponent: p.white_player, pairing: p}

            true ->
              nil
          end
        end)

      bye = Enum.find(round.byes, &(&1.player.id == player.id))

      cond do
        seat -> Map.merge(base, seat)
        bye -> %{base | bye: bye.type}
        true -> base
      end
    end)
  end

  ## ---------- teams ----------

  @doc """
  Every round of a team round robin: `{:ok, %{rounds: [team_round],
  certainty:, first_unpaired:}}` or `{:error, reason}`. A team round is
  `%{number:, date:, paired?:, projected?:, matches: [match]}`, a match
  `%{number:, team_a:, team_b: team | nil, double_forfeit:, gp_a:, gp_b:,
  mp_a:, mp_b:, postponed_boards:, boards: [%{k:, white:, black:,
  pairing:}]}` - `team_a` holds White on board 1, `pairing` the stored board
  (nil for a round not paired, whose boards are the line-ups as the rosters
  stand now).
  """
  def team(%Tournament{} = t) do
    with {:ok, teams, size, total} <- TeamRoundRobin.schedule_field(t) do
      paired = paired_rounds(t)
      total = max(total, map_size(paired))
      scored = t |> TeamStandings.matches() |> Map.new(&{&1.match_id, &1})
      all_teams = t.id |> Tournaments.list_teams() |> Map.new(&{&1.id, &1})

      rounds =
        for n <- 1..total do
          case Map.get(paired, n) do
            %Round{} = round -> paired_team_round(t, round, all_teams, scored)
            nil -> planned_team_round(t, teams, size, n)
          end
        end

      {:ok,
       %{
         rounds: rounds,
         certainty: team_certainty(t, rounds),
         first_unpaired: first_unpaired(rounds)
       }}
    end
  end

  defp team_certainty(t, rounds) do
    cond do
      Enum.all?(rounds, & &1.paired?) -> :final
      Tournaments.teams_frozen?(t.id) and map_size(paired_rounds(t)) > 0 -> :table
      true -> :until_round_one
    end
  end

  defp paired_team_round(t, round, all_teams, scored) do
    pairings = Map.new(round.pairings, &{&1.id, &1})

    matches =
      from(m in PairingsEngine.Tournaments.Match,
        where: m.round_id == ^round.id,
        order_by: m.board
      )
      |> Repo.all()
      |> Enum.map(fn m ->
        s = Map.get(scored, m.id, %{})

        boards =
          pairings
          |> Map.values()
          |> Enum.filter(&(&1.match_id == m.id))
          |> Enum.sort_by(& &1.board)
          |> Enum.with_index(1)
          |> Enum.map(fn {p, i} ->
            k = board_in_match(s, p, i)
            %{k: k, white: p.white_player, black: p.black_player, pairing: p}
          end)

        %{
          number: m.board,
          team_a: Map.get(all_teams, m.team_a_id),
          team_b: m.team_b_id && Map.get(all_teams, m.team_b_id),
          double_forfeit: m.double_forfeit,
          gp_a: Map.get(s, :gp_a),
          gp_b: Map.get(s, :gp_b),
          mp_a: Map.get(s, :mp_a),
          mp_b: Map.get(s, :mp_b),
          postponed_boards: Map.get(s, :postponed_boards, 0),
          boards: boards
        }
      end)

    %{
      number: round.number,
      date: round_date(t, round.number),
      paired?: true,
      projected?: false,
      matches: matches
    }
  end

  # The board within the match TeamStandings scored it as; the order of the
  # match's own boards when that is not to be had.
  defp board_in_match(%{boards: boards}, pairing, fallback) do
    Enum.find_value(boards, fallback, &(&1.pairing.id == pairing.id && &1.board))
  end

  defp board_in_match(_scored, _pairing, fallback), do: fallback

  defp planned_team_round(t, teams, size, n) do
    matches =
      case TeamRoundRobin.planned_entries(t, teams, size, n) do
        {:ok, entries} ->
          t
          |> TeamRounds.planned_matches(teams, entries, n)
          |> Enum.map(fn m ->
            %{
              number: m.number,
              team_a: m.team_a,
              team_b: m.team_b,
              double_forfeit: m.double_forfeit,
              gp_a: nil,
              gp_b: nil,
              mp_a: nil,
              mp_b: nil,
              postponed_boards: 0,
              boards:
                Enum.map(m.boards, fn {k, white, black, _result} ->
                  %{k: k, white: white, black: black, pairing: nil}
                end)
            }
          end)

        {:error, _} ->
          []
      end

    %{number: n, date: round_date(t, n), paired?: false, projected?: true, matches: matches}
  end

  @doc """
  One row per round for `team`: `%{round:, date:, match:, home?:,
  opponent:, projected?:}` - `home?` true when the team is the match's team
  A (White on board 1); `match` and `opponent` nil when the team does not
  play (its bye).
  """
  def team_rows(%{rounds: rounds}, team) do
    Enum.map(rounds, fn round ->
      match =
        Enum.find(round.matches, fn m ->
          (m.team_a && m.team_a.id == team.id) or (m.team_b && m.team_b.id == team.id)
        end)

      home? = match != nil and match.team_a.id == team.id

      %{
        round: round.number,
        date: round.date,
        match: match,
        home?: home?,
        opponent: match && if(home?, do: match.team_b, else: match.team_a),
        projected?: round.projected?
      }
    end)
  end

  @doc """
  One row per round for `player` of a team round robin: `%{round:, date:,
  team_row:, seat: %{k:, colour:, opponent:, pairing:} | nil}` - the team's
  match that round (`team_rows/2`) and where the player sat in it, nil when
  they did not (or, for a round not paired, would not as the roster stands).
  """
  def team_player_rows(schedule, team, player) do
    schedule
    |> team_rows(team)
    |> Enum.map(fn row ->
      seat =
        row.match &&
          Enum.find_value(row.match.boards, fn b ->
            cond do
              b.white && b.white.id == player.id ->
                %{k: b.k, colour: :w, opponent: b.black, pairing: b.pairing}

              b.black && b.black.id == player.id ->
                %{k: b.k, colour: :b, opponent: b.white, pairing: b.pairing}

              true ->
                nil
            end
          end)

      Map.put(row, :seat, seat)
    end)
  end

  @doc "Whether a stored result is a postponed game still to be played."
  def postponed?(%Pairing{result: result}), do: Results.postponed?(result)
  def postponed?(_), do: false
end
