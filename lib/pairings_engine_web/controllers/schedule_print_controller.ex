defmodule PairingsEngineWeb.SchedulePrintController do
  @moduledoc """
  The whole schedule on paper, and the player cards filled in from it. Same
  shell as every other print document (`PrintController.print_page/6`); see
  `docs/printing.md`. The rounds come from `PairingsEngine.PrintSchedule`,
  which reads a paired round as stored and works out a round robin's
  unpaired rounds with the functions that will pair them.

    * `GET /t/:id/print/schedule` - every round of a round robin, paired or
      not: date, boards, both players with numbers and ratings, byes. A team
      round robin is sent to the team version.
    * `GET /t/:id/print/team-schedule` - every round of a team round robin:
      each match, and with `boards=1` (default) its board lines.
    * `GET /t/:id/print/team-cards` - one schedule per team: opponent, colour
      on board 1, match score and running match points per round.
      `?team=<id>` prints one team.
    * The player cards (`/print/cards`, `/print/card/:player_id`) are drawn
      here too (`cards_html/3`), for `PrintController`.

  Options, each `1`/`0`: `results` (default on - entered results; off is a
  blank schedule for the wall) and `postponed` (default on - a postponed
  game shows the date the players agreed instead of its `*`). The cards take
  `blank=1` for the old empty grid. `category=` filters as on every other
  document.

  A round printed before it is paired is marked as such, and the page says
  what can still change it (`PrintSchedule`'s `:certainty`).
  """

  use PairingsEngineWeb, :controller

  alias PairingsEngine.{PlayerCard, PrintSchedule, Standings, Tournaments}
  alias PairingsEngine.Tournaments.Tournament
  alias PairingsEngineWeb.PrintController, as: Print

  import PairingsEngineWeb.PrintController, only: [esc: 1, format_num: 1]

  @schedule_css """
  .sched-note { border: 1.5px solid #000; padding: 6px 10px; font-size: 12px; margin: 0 0 14px; }
  .sched-round { margin: 0 0 18px; break-inside: avoid; page-break-inside: avoid; }
  .sched-round h2 { font-size: 15px; margin: 0 0 4px; }
  .sched-round h2 .sched-date { font-weight: normal; color: #333; font-size: 13px; margin-left: 8px; }
  .sched-flag { font-weight: normal; font-style: italic; font-size: 11px; color: #555; margin-left: 8px; }
  .sched-match { font-size: 13px; margin: 10px 0 4px; }
  .sched-bye { font-size: 12px; margin: 4px 0 0; color: #333; }
  td.res { text-align: center; white-space: nowrap; }
  td.pn { width: 1%; color: #555; }
  .sched-postponed { font-style: italic; font-size: 11.5px; }
  .team-card { border: 1.5px solid #000; padding: 14px 16px; margin-bottom: 16px; page-break-inside: avoid; }
  .team-card h2 { font-size: 16px; margin: 0 0 8px; }
  @media print { .sched-round, .team-card { break-inside: avoid; } }
  """

  ## ---------- the whole schedule ----------

  @doc "`GET /t/:id/print/schedule` - see the moduledoc."
  def schedule(conn, %{"id" => id} = params) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)

    cond do
      Tournament.team_round_robin?(tournament) ->
        team_schedule(conn, params)

      not PrintSchedule.round_robin?(tournament) ->
        Print.print_error(
          conn,
          404,
          tournament,
          gettext("Only a round robin has a schedule to print.")
        )

      true ->
        case PrintSchedule.individual(tournament) do
          {:ok, schedule} ->
            opts = options(params)
            category = Print.print_category(tournament, params)

            body =
              Print.tournament_info_html(tournament) <>
                certainty_note(schedule) <>
                Enum.map_join(schedule.rounds, "", &round_html(&1, tournament, opts, category))

            Print.print_page(
              conn,
              tournament,
              tournament.name,
              subtitle(gettext("Schedule - all rounds"), category),
              body,
              @schedule_css
            )

          {:error, _} ->
            too_few(conn, tournament)
        end
    end
  end

  defp too_few(conn, tournament) do
    Print.print_error(
      conn,
      409,
      tournament,
      gettext("A schedule needs at least two players (or teams) to pair.")
    )
  end

  defp subtitle(text, nil), do: text
  defp subtitle(text, category), do: text <> " · " <> category

  # `results`/`postponed` default ON: a link without them (the Players
  # page's, a bookmark) prints everything there is.
  defp options(params) do
    %{
      results: flag(params["results"], true),
      postponed: flag(params["postponed"], true),
      boards: flag(params["boards"], true),
      blank: flag(params["blank"], false)
    }
  end

  defp flag(nil, default), do: default
  defp flag("", default), do: default
  defp flag(value, _default), do: value not in ["0", "false", "no", "off"]

  # What can still move the rounds printed ahead of their pairing - see
  # `PairingsEngine.PrintSchedule`'s moduledoc. A schedule fully paired has
  # nothing to warn about.
  defp certainty_note(%{certainty: :until_round_one}) do
    note(
      gettext(
        "Provisional. The schedule is fixed when round 1 is paired: until then a new entry, a withdrawal or new starting numbers change it."
      )
    )
  end

  defp certainty_note(%{certainty: :table, first_unpaired: n}) do
    note(
      gettext(
        "From round %{n} on, the rounds are not paired yet. They are printed exactly as pairing them will produce them, unless the arbiter swaps rounds, pairs one by hand or changes the schedule's settings.",
        n: n
      )
    )
  end

  defp certainty_note(_schedule), do: ""

  defp note(text), do: "<p class=\"sched-note\" id=\"sched-note\">#{esc(text)}</p>"

  defp round_heading(round) do
    date =
      if round.date,
        do: "<span class=\"sched-date\">#{esc(date_text(round.date))}</span>",
        else: ""

    flag =
      if round.projected?,
        do: "<span class=\"sched-flag\">#{esc(gettext("not paired yet"))}</span>",
        else: ""

    "<h2>#{esc(gettext("Round %{n}", n: round.number))}#{date}#{flag}</h2>"
  end

  defp round_html(round, tournament, opts, category) do
    rows =
      round.rows
      |> Enum.filter(fn %{pairing: p} ->
        Print.filter_pairings([p], tournament, category) != []
      end)
      |> Enum.map_join("", fn %{pairing: p, board: board} ->
        "<tr><td class=\"num\">#{esc(board)}</td>" <>
          player_cells(p.white_player, tournament) <>
          "<td class=\"res\">#{result_html(p, tournament, opts)}</td>" <>
          if(p.black_player,
            do: player_cells(p.black_player, tournament),
            else: "<td></td><td><strong>#{esc(gettext("- bye -"))}</strong></td><td></td>"
          ) <> "</tr>"
      end)

    byes =
      round.byes
      |> Enum.filter(
        &(category == nil or Print.in_print_category?(tournament, &1.player, category))
      )
      |> Enum.map_join(", ", &esc(&1.player.name))

    bye_line =
      if byes == "",
        do: "",
        else: "<p class=\"sched-bye\">#{esc(gettext("Bye"))}: #{byes}</p>"

    table =
      if rows == "" do
        ""
      else
        "<table><thead><tr><th class=\"num\">#{gettext("Board")}</th>" <>
          "<th class=\"num\">#{gettext("No.")}</th><th>#{gettext("White")}</th>" <>
          "<th class=\"num\">#{Print.rating_header(tournament)}</th>" <>
          "<th style=\"text-align:center\">#{gettext("Result")}</th>" <>
          "<th class=\"num\">#{gettext("No.")}</th><th>#{gettext("Black")}</th>" <>
          "<th class=\"num\">#{Print.rating_header(tournament)}</th></tr></thead>" <>
          "<tbody>#{rows}</tbody></table>"
      end

    if table == "" and bye_line == "" do
      ""
    else
      "<section class=\"sched-round\" id=\"sched-round-#{round.number}\">" <>
        round_heading(round) <> table <> bye_line <> "</section>"
    end
  end

  defp player_cells(player, tournament) do
    "<td class=\"num pn\">#{player.pairing_number || ""}</td>" <>
      "<td><strong>#{esc(Print.result_card_name(player))}</strong></td>" <>
      "<td class=\"num\">#{Print.blank_zero(Print.player_rating(player, tournament))}</td>"
  end

  # The result cell of a board. A postponed game still to be played shows
  # the date the players agreed (with `postponed`), else its `*`; a
  # postponed game since played says when, beside its result.
  defp result_html(%{id: id} = p, tournament, opts) when is_integer(id) and id > 0 do
    cond do
      opts.postponed and PrintSchedule.postponed?(p) ->
        "<span class=\"sched-postponed\">#{esc(postponed_text(p.agreed_date, tournament))}</span>"

      not opts.results ->
        ""

      opts.postponed and p.played_on != nil and p.result != "" ->
        esc(Print.display_result(p.result)) <>
          " <span class=\"sched-postponed\">#{esc(gettext("(played %{date})", date: PairingsEngineWeb.Postponed.date_text(p.played_on)))}</span>"

      true ->
        esc(Print.display_result(p.result))
    end
  end

  # A round not paired yet has no result to print, and its bye board says so
  # in the black column already.
  defp result_html(_planned, _tournament, _opts), do: ""

  @doc false
  def postponed_text(agreed_date, tournament) do
    venue =
      [tournament.venue, tournament.city]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(", ")

    case {agreed_date, venue} do
      {nil, ""} ->
        gettext("postponed, date still to be agreed")

      {nil, venue} ->
        gettext("postponed, date still to be agreed (%{venue})", venue: venue)

      {date, ""} ->
        gettext("postponed to %{date}", date: PairingsEngineWeb.Postponed.date_text(date))

      {date, venue} ->
        gettext("postponed to %{date} (%{venue})",
          date: PairingsEngineWeb.Postponed.date_text(date),
          venue: venue
        )
    end
  end

  @doc false
  def date_text(nil), do: ""

  def date_text(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> PairingsEngineWeb.Postponed.date_text(date)
      _ -> iso
    end
  end

  ## ---------- team round robin ----------

  @doc "`GET /t/:id/print/team-schedule` - see the moduledoc."
  def team_schedule(conn, %{"id" => id} = params) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)

    with true <- Tournament.team_round_robin?(tournament),
         {:ok, schedule} <- PrintSchedule.team(tournament) do
      opts = options(params)

      body =
        Print.tournament_info_html(tournament) <>
          team_certainty_note(schedule) <>
          Enum.map_join(schedule.rounds, "", &team_round_html(&1, tournament, opts))

      Print.print_page(
        conn,
        tournament,
        tournament.name,
        gettext("Schedule - all rounds"),
        body,
        @schedule_css
      )
    else
      false -> not_team_rr(conn, tournament)
      {:error, _} -> too_few(conn, tournament)
    end
  end

  defp not_team_rr(conn, tournament) do
    Print.print_error(
      conn,
      404,
      tournament,
      gettext("Only a team round robin has a team schedule to print.")
    )
  end

  defp team_certainty_note(%{certainty: :until_round_one}) do
    note(
      gettext(
        "Provisional. The schedule is fixed when round 1 is paired: until then a new team, a withdrawal or a new team order changes it. The line-ups are the rosters as they stand now."
      )
    )
  end

  defp team_certainty_note(%{certainty: :table, first_unpaired: n}) do
    note(
      gettext(
        "From round %{n} on, the rounds are not paired yet. Who plays whom is printed exactly as pairing will produce it, unless the arbiter swaps rounds or changes the schedule's settings; the line-ups are the rosters as they stand now and change with every absence or reserve.",
        n: n
      )
    )
  end

  defp team_certainty_note(_schedule), do: ""

  defp team_round_html(round, tournament, opts) do
    matches = Enum.map_join(round.matches, "", &team_match_html(&1, tournament, opts))

    "<section class=\"sched-round\" id=\"sched-round-#{round.number}\">" <>
      round_heading(round) <> matches <> "</section>"
  end

  defp team_match_html(%{team_b: nil} = m, _tournament, _opts) do
    "<p class=\"sched-bye\"><strong>#{esc(team_name(m.team_a))}</strong> - #{esc(gettext("does not play this round"))}</p>"
  end

  defp team_match_html(m, tournament, opts) do
    heading =
      "<p class=\"sched-match\"><strong>" <>
        esc(gettext("Match %{n}", n: m.number)) <>
        ": " <>
        esc(team_name(m.team_a)) <>
        " - " <> esc(team_name(m.team_b)) <> "</strong>" <> match_score_html(m, opts) <> "</p>"

    if opts.boards and m.boards != [] do
      rows =
        Enum.map_join(m.boards, "", fn b ->
          {a_player, b_player, a_colour} =
            if PairingsEngine.TeamRounds.team_a_white?(b.k),
              do: {b.white, b.black, gettext("White")},
              else: {b.black, b.white, gettext("Black")}

          "<tr><td class=\"num\">#{b.k}</td><td>#{esc(a_colour)}</td>" <>
            seat_cells(a_player, tournament) <>
            "<td class=\"res\">#{board_result_html(b.pairing, tournament, opts)}</td>" <>
            seat_cells(b_player, tournament) <> "</tr>"
        end)

      heading <>
        "<table><thead><tr><th class=\"num\">#{gettext("Board")}</th><th>#{gettext("Colour")}</th>" <>
        "<th>#{esc(team_name(m.team_a))}</th><th class=\"num\">#{Print.rating_header(tournament)}</th>" <>
        "<th style=\"text-align:center\">#{gettext("Result")}</th>" <>
        "<th>#{esc(team_name(m.team_b))}</th><th class=\"num\">#{Print.rating_header(tournament)}</th></tr></thead>" <>
        "<tbody>#{rows}</tbody></table>"
    else
      heading
    end
  end

  defp seat_cells(nil, _tournament), do: "<td>#{esc(gettext("- no player -"))}</td><td></td>"

  defp seat_cells(player, tournament) do
    "<td><strong>#{esc(player.name)}</strong></td>" <>
      "<td class=\"num\">#{Print.blank_zero(Print.player_rating(player, tournament))}</td>"
  end

  defp board_result_html(nil, _tournament, _opts), do: ""
  defp board_result_html(p, tournament, opts), do: result_html(p, tournament, opts)

  defp match_score_html(m, opts) do
    scored? = Enum.any?(m.boards, &(&1.pairing && &1.pairing.result != ""))

    if opts.results and scored? and m.gp_a != nil do
      pending =
        if m.postponed_boards > 0,
          do: ", " <> esc(PairingsEngineWeb.Postponed.boards_pending_text(m.postponed_boards)),
          else: ""

      " (#{format_num(m.gp_a)} - #{format_num(m.gp_b)}#{pending})"
    else
      ""
    end
  end

  defp team_name(nil), do: "-"
  defp team_name(team), do: team.name

  @doc "`GET /t/:id/print/team-cards` - see the moduledoc."
  def team_cards(conn, %{"id" => id} = params) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)

    with true <- Tournament.team_round_robin?(tournament),
         {:ok, schedule} <- PrintSchedule.team(tournament),
         {:ok, teams} <- wanted_teams(tournament, params["team"]) do
      opts = options(params)

      cards =
        Enum.map_join(teams, "", fn team ->
          rows = PrintSchedule.team_rows(schedule, team)
          team_card_html(team, rows, opts)
        end)

      Print.print_page(
        conn,
        tournament,
        tournament.name,
        gettext("Team schedules"),
        Print.tournament_info_html(tournament) <> team_certainty_note(schedule) <> cards,
        @schedule_css
      )
    else
      false -> not_team_rr(conn, tournament)
      {:error, :no_team} -> Print.print_error(conn, 404, tournament, gettext("Team not found"))
      {:error, _} -> too_few(conn, tournament)
    end
  end

  defp wanted_teams(tournament, nil), do: {:ok, Tournaments.list_teams(tournament.id)}

  defp wanted_teams(tournament, id) do
    case Enum.filter(Tournaments.list_teams(tournament.id), &(to_string(&1.id) == id)) do
      [team] -> {:ok, [team]}
      _ -> {:error, :no_team}
    end
  end

  defp team_card_html(team, rows, opts) do
    {body, _mp} =
      Enum.map_reduce(rows, 0.0, fn row, mp ->
        {score, mp_after} = team_score(row, mp, opts)

        opponent =
          cond do
            row.match == nil -> gettext("does not play this round")
            row.opponent == nil -> gettext("bye")
            true -> team_name(row.opponent)
          end

        colour =
          cond do
            row.opponent == nil -> ""
            row.home? -> gettext("White")
            true -> gettext("Black")
          end

        flag =
          if row.projected?,
            do: " <span class=\"sched-flag\">#{esc(gettext("not paired yet"))}</span>",
            else: ""

        html =
          "<tr><td class=\"num\">#{row.round}</td><td>#{esc(date_text(row.date))}</td>" <>
            "<td><strong>#{esc(opponent)}</strong>#{flag}</td><td>#{esc(colour)}</td>" <>
            "<td class=\"res\">#{score}</td>" <>
            "<td class=\"num\">#{if score == "", do: "", else: format_num(mp_after)}</td></tr>"

        {html, mp_after}
      end)

    "<div class=\"team-card\" id=\"team-card-#{team.id}\"><h2>#{esc(team.name)}</h2>" <>
      "<table><thead><tr><th class=\"num\">#{gettext("Rd")}</th><th>#{gettext("Date")}</th>" <>
      "<th>#{gettext("Opponent")}</th><th>#{gettext("Colour on board 1")}</th>" <>
      "<th style=\"text-align:center\">#{gettext("Match score")}</th>" <>
      "<th class=\"num\">#{gettext("MP")}</th></tr></thead><tbody>#{body}</tbody></table></div>"
  end

  # The match score from this team's side and its match points after the
  # round - only once the match scores (every board has a result, a
  # postponed game counting as the draw it stands for).
  defp team_score(%{match: %{team_b: b} = m} = row, mp, opts) when not is_nil(b) do
    if opts.results and m.mp_a != nil do
      {own, other, own_mp} =
        if row.home?, do: {m.gp_a, m.gp_b, m.mp_a}, else: {m.gp_b, m.gp_a, m.mp_b}

      pending =
        if m.postponed_boards > 0,
          do:
            " <span class=\"sched-postponed\">(#{esc(PairingsEngineWeb.Postponed.boards_pending_text(m.postponed_boards))})</span>",
          else: ""

      {"#{format_num(own)} - #{format_num(other)}#{pending}", mp + own_mp}
    else
      {"", mp}
    end
  end

  defp team_score(_row, mp, _opts), do: {"", mp}

  ## ---------- player cards ----------

  @doc """
  The player cards of `players`, filled in from the schedule: every round
  with its date, board, colour, opponent, result and running score. A round
  robin's rounds not paired yet come from the table; a Swiss round not
  paired yet stays an empty row to fill in by hand. `opts` from the query
  (`results`, `postponed`, `blank`).
  """
  def cards_html(tournament, players, params) do
    opts = options(params)

    cond do
      opts.blank ->
        Enum.map_join(players, "", &blank_card(&1, tournament))

      Tournament.team_round_robin?(tournament) ->
        team_player_cards(tournament, players, opts)

      true ->
        individual_cards(tournament, players, opts)
    end
  end

  @doc false
  def blank_flag?(params), do: options(params).blank

  @doc "The certainty line above the cards (`PrintSchedule`), or \"\"."
  def cards_note(tournament, params) do
    cond do
      options(params).blank ->
        ""

      Tournament.team_round_robin?(tournament) ->
        case PrintSchedule.team(tournament) do
          {:ok, s} -> team_certainty_note(s)
          _ -> ""
        end

      PrintSchedule.round_robin?(tournament) ->
        case PrintSchedule.individual(tournament) do
          {:ok, s} -> certainty_note(s)
          _ -> ""
        end

      true ->
        ""
    end
  end

  defp individual_cards(tournament, players, opts) do
    case PrintSchedule.individual(tournament) do
      {:ok, schedule} ->
        games = games_by_player(tournament)

        Enum.map_join(players, "", fn player ->
          rows = PrintSchedule.player_rows(schedule, player)

          card(
            player,
            card_rows(rows, Map.get(games, player.id, []), tournament, opts),
            tournament
          )
        end)

      {:error, _} ->
        Enum.map_join(players, "", &blank_card(&1, tournament))
    end
  end

  defp games_by_player(tournament) do
    tournament |> Standings.grid_standings() |> Map.new(&{&1.player.id, &1.games})
  end

  # Each round's cells, `[{round, date, board, colour, opponent, result,
  # score}]` as text, from the schedule row and the player's own game
  # records (which carry what a result is worth to them).
  defp card_rows(rows, games, tournament, opts) do
    by_round = Enum.group_by(games, & &1.round)

    {cells, _} =
      Enum.map_reduce(rows, 0.0, fn row, score ->
        game_records = Map.get(by_round, row.round, [])
        score = score + Enum.reduce(game_records, 0.0, &(&1.points + &2))

        postponed? = opts.postponed and PrintSchedule.postponed?(row.pairing)

        result =
          cond do
            postponed? ->
              {:postponed, postponed_text(row.pairing.agreed_date, tournament)}

            not opts.results ->
              ""

            game_records != [] ->
              game_records |> Enum.map_join(" ", &PlayerCard.result_label(&1, tournament))

            true ->
              ""
          end

        date =
          if postponed? and row.pairing.agreed_date,
            do: PairingsEngineWeb.Postponed.date_text(row.pairing.agreed_date),
            else: date_text(row.date)

        opponent =
          cond do
            row.opponent -> opponent_text(row.opponent)
            row.bye != nil or (row.pairing && row.pairing.black_player == nil) -> gettext("bye")
            true -> ""
          end

        colour =
          case row.colour do
            :w when row.opponent != nil -> gettext("White")
            :b -> gettext("Black")
            _ -> ""
          end

        shown_score = if opts.results and game_records != [], do: format_num(score), else: ""

        {%{
           round: row.round,
           date: date,
           board: row.board || "",
           colour: colour,
           opponent: opponent,
           rating: row.opponent && Print.player_rating(row.opponent, tournament),
           result: result,
           score: shown_score,
           projected?: row.projected? and row.board != nil
         }, score}
      end)

    cells
  end

  defp opponent_text(opponent) do
    case opponent.pairing_number do
      nil -> Print.result_card_name(opponent)
      n -> "#{Print.result_card_name(opponent)} (#{n})"
    end
  end

  defp card(player, cells, tournament) do
    body =
      Enum.map_join(cells, "", fn c ->
        result =
          case c.result do
            {:postponed, text} -> "<span class=\"sched-postponed\">#{esc(text)}</span>"
            text -> esc(text)
          end

        "<tr><td class=\"num\">#{c.round}</td><td>#{esc(c.date)}</td>" <>
          "<td class=\"num\">#{esc(c.board)}</td><td>#{esc(c.colour)}</td>" <>
          "<td>#{esc(c.opponent)}</td>" <>
          "<td class=\"num\">#{if c.rating, do: Print.blank_zero(c.rating), else: ""}</td>" <>
          "<td class=\"res\">#{result}</td><td class=\"num\">#{c.score}</td></tr>"
      end)

    card_shell(player, tournament) <>
      "<table><thead><tr><th class=\"num\">#{gettext("Rd")}</th><th>#{gettext("Date")}</th>" <>
      "<th class=\"num\">#{gettext("Board")}</th><th>#{gettext("Colour")}</th>" <>
      "<th>#{gettext("Opponent")}</th><th class=\"num\">#{Print.rating_header(tournament)}</th>" <>
      "<th style=\"text-align:center\">#{gettext("Result")}</th>" <>
      "<th class=\"num\">#{gettext("Score")}</th></tr></thead><tbody>#{body}</tbody></table></div>"
  end

  # The card's frame and heading, the same as the blank cards always had.
  defp card_shell(player, tournament) do
    meta =
      [
        if(Print.player_rating(player, tournament) > 0,
          do: "#{Print.rating_header(tournament)} #{Print.player_rating(player, tournament)}"
        ),
        if(player.federation not in [nil, ""], do: esc(player.federation)),
        if(player.club not in [nil, ""], do: esc(player.club))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    number = if player.pairing_number, do: "#{player.pairing_number}. ", else: ""

    "<div class=\"player-card\" id=\"player-card-#{player.id}\">" <>
      "<h2>#{number}#{esc(Print.result_card_name(player))}</h2>" <>
      "<p class=\"meta\">#{meta}</p>"
  end

  defp blank_card(player, tournament) do
    rows =
      Enum.map_join(1..max(tournament.rounds_count || 0, 1)//1, "", fn n ->
        "<tr><td class=\"num\">#{n}</td><td>#{esc(date_text(PrintSchedule.round_date(tournament, n)))}</td>" <>
          "<td></td><td></td><td></td><td></td><td></td><td></td></tr>"
      end)

    card_shell(player, tournament) <>
      "<table><thead><tr><th class=\"num\">#{gettext("Rd")}</th><th>#{gettext("Date")}</th>" <>
      "<th class=\"num\">#{gettext("Board")}</th><th>#{gettext("Colour")}</th>" <>
      "<th>#{gettext("Opponent")}</th><th class=\"num\">#{Print.rating_header(tournament)}</th>" <>
      "<th style=\"text-align:center\">#{gettext("Result")}</th>" <>
      "<th class=\"num\">#{gettext("Score")}</th></tr></thead><tbody>#{rows}</tbody></table></div>"
  end

  defp team_player_cards(tournament, players, opts) do
    case PrintSchedule.team(tournament) do
      {:ok, schedule} ->
        teams = tournament.id |> Tournaments.list_teams() |> Map.new(&{&1.id, &1})
        games = games_by_player(tournament)

        Enum.map_join(players, "", fn player ->
          case Map.get(teams, player.team_id) do
            nil ->
              blank_card(player, tournament)

            team ->
              rows = PrintSchedule.team_player_rows(schedule, team, player)

              team_player_card(
                player,
                team,
                rows,
                Map.get(games, player.id, []),
                tournament,
                opts
              )
          end
        end)

      {:error, _} ->
        Enum.map_join(players, "", &blank_card(&1, tournament))
    end
  end

  defp team_player_card(player, team, rows, games, tournament, opts) do
    by_round = Enum.group_by(games, & &1.round)

    {body, _} =
      Enum.map_reduce(rows, 0.0, fn row, score ->
        records = if row.seat, do: Map.get(by_round, row.round, []), else: []
        score = score + Enum.reduce(records, 0.0, &(&1.points + &2))
        pairing = row.seat && row.seat.pairing
        postponed? = opts.postponed and PrintSchedule.postponed?(pairing)

        result =
          cond do
            postponed? ->
              "<span class=\"sched-postponed\">#{esc(postponed_text(pairing.agreed_date, tournament))}</span>"

            opts.results and records != [] ->
              esc(Enum.map_join(records, " ", &PlayerCard.result_label(&1, tournament)))

            true ->
              ""
          end

        opponent_team =
          cond do
            row.match == nil -> gettext("does not play this round")
            row.opponent == nil -> gettext("bye")
            true -> team_name(row.opponent)
          end

        {board, colour, opponent} =
          case row.seat do
            nil ->
              {"", "", if(row.opponent, do: gettext("not in the line-up"), else: "")}

            seat ->
              {to_string(seat.k),
               if(seat.colour == :w, do: gettext("White"), else: gettext("Black")),
               if(seat.opponent, do: seat.opponent.name, else: gettext("- no player -"))}
          end

        date =
          if postponed? and pairing.agreed_date,
            do: PairingsEngineWeb.Postponed.date_text(pairing.agreed_date),
            else: date_text(row.date)

        html =
          "<tr><td class=\"num\">#{row.round}</td><td>#{esc(date)}</td>" <>
            "<td>#{esc(opponent_team)}</td><td class=\"num\">#{esc(board)}</td>" <>
            "<td>#{esc(colour)}</td><td>#{esc(opponent)}</td>" <>
            "<td class=\"res\">#{result}</td>" <>
            "<td class=\"num\">#{if opts.results and records != [], do: format_num(score), else: ""}</td></tr>"

        {html, score}
      end)

    card_shell(player, tournament) <>
      "<p class=\"meta\">#{esc(gettext("Team: %{team}", team: team.name))}</p>" <>
      "<table><thead><tr><th class=\"num\">#{gettext("Rd")}</th><th>#{gettext("Date")}</th>" <>
      "<th>#{gettext("Opponent team")}</th><th class=\"num\">#{gettext("Board")}</th>" <>
      "<th>#{gettext("Colour")}</th><th>#{gettext("Opponent")}</th>" <>
      "<th style=\"text-align:center\">#{gettext("Result")}</th>" <>
      "<th class=\"num\">#{gettext("Score")}</th></tr></thead><tbody>#{body}</tbody></table></div>"
  end

  @doc false
  def schedule_css, do: @schedule_css
end
