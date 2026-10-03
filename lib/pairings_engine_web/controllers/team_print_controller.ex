defmodule PairingsEngineWeb.TeamPrintController do
  @moduledoc """
  Print documents for a team tournament, beside the team pairings and team
  standings `PrintController` prints. Same shell (`PrintController.print_page/6`),
  same routes prefix, same print-on-load behaviour; see `docs/printing.md`.

    * `GET /t/:id/print/team-crosstable` - a team round robin as a team x team
      grid of game points with match-point and game-point totals; a team Swiss
      as one row per team with, per round, the opponent's number, the colour
      of board 1, the match score and the running match points.
    * `GET /t/:id/print/team-match-sheets?round=n` - one A4 result sheet per
      match of round `n` (default: the latest paired round): both line-ups
      with colours and ratings, a box for each board's result, the match
      score, and lines for both captains and the arbiter. `?match=<id>`
      prints a single match. Results already entered are filled in.
    * `GET /t/:id/print/team-rosters` - each team's board order: board, name,
      rating, FIDE ID, federation. `?team=<id>` prints one team.
    * `GET /t/:id/print/board-prizes` - per board number, the players ranked
      by percentage, then points, then performance. `?min_games=n` leaves out
      players with fewer games.

  All four answer 404 for a tournament that is not paired as teams. The data
  comes from `PairingsEngine.TeamSheets`, which reads `TeamStandings`; nothing
  is scored here.
  """

  use PairingsEngineWeb, :controller

  alias PairingsEngine.{Standings, TeamSheets, Tournaments}
  alias PairingsEngine.Tournaments.{Team, Tournament}
  alias PairingsEngineWeb.PrintController, as: Print

  import PairingsEngine.TeamSheets, only: [points_text: 1]

  @cross_css """
  @page { size: A4 landscape; margin: 12mm; }
  table.team-cross { font-size: 11px; white-space: nowrap; }
  table.team-cross th, table.team-cross td { padding: 4px 6px; text-align: center; }
  table.team-cross td.tc-team, table.team-cross th.tc-team { text-align: left; }
  table.team-cross td.tc-diag {
    background-image: repeating-linear-gradient(45deg, #000 0, #000 2px, transparent 2px, transparent 6px);
  }
  table.team-cross td.tc-total { font-weight: 700; }
  table.team-cross td.tc-round { line-height: 1.25; }
  table.team-cross .tc-opp { font-weight: 700; }
  table.team-cross .tc-score { font-size: 10.5px; }
  table.team-cross .tc-mp { font-size: 9.5px; color: #555; }
  """

  @sheet_css """
  @page { size: A4 portrait; margin: 12mm; }
  .match-sheet { page-break-after: always; break-after: page; }
  .match-sheet:last-child { page-break-after: auto; break-after: auto; }
  .ms-head { display: flex; justify-content: space-between; align-items: baseline; gap: 12px;
             border-bottom: 2px solid #000; padding-bottom: 4px; font-size: 12px; }
  .ms-head strong { font-size: 14px; }
  .match-sheet h2 { font-size: 17px; margin: 14px 0 10px; display: flex; justify-content: space-between; gap: 12px; }
  .match-sheet h2 span { font-weight: 400; font-size: 12px; color: #555; }
  .match-sheet h2 span.ms-title { font-weight: 700; font-size: 17px; color: #000; }
  table.ms-boards td, table.ms-boards th { padding: 6px 6px; vertical-align: middle; }
  table.ms-boards td { height: 13mm; border-bottom: 1px solid #888; }
  table.ms-boards .ms-name { font-size: 14px; }
  table.ms-boards .ms-table-no { display: block; font-size: 9px; color: #666; font-weight: 400; }
  .ms-result { display: inline-block; min-width: 22mm; height: 9mm; line-height: 9mm; border: 1.5px solid #000;
               text-align: center; font-weight: 700; font-size: 15px; }
  .ms-total { margin-top: 12px; display: flex; justify-content: flex-end; align-items: center; gap: 10px;
              font-size: 14px; }
  .ms-total .ms-result { min-width: 30mm; }
  .ms-sigs { display: flex; gap: 14mm; margin-top: 22mm; }
  .ms-sig { flex: 1 1 0; border-top: 1px solid #000; padding-top: 3px; font-size: 11px; color: #333; }
  .ms-sig small { display: block; color: #666; font-size: 10px; }
  .ms-note { margin-top: 10px; font-size: 10.5px; color: #555; }
  """

  @roster_css """
  @page { size: A4 portrait; margin: 14mm; }
  .roster { page-break-inside: avoid; break-inside: avoid; margin-bottom: 18px; }
  .roster h2 { font-size: 15px; margin: 0 0 2px; }
  .roster .roster-meta { font-size: 11.5px; color: #555; margin: 0 0 4px; }
  .roster .out { color: #777; font-style: italic; }
  """

  @prize_css """
  @page { size: A4 portrait; margin: 14mm; }
  .prize-board { page-break-inside: avoid; break-inside: avoid; margin-bottom: 20px; }
  .prize-board h2 { font-size: 15px; margin: 0 0 4px; }
  """

  ## ---------- team cross table ----------

  @doc """
  `GET /t/:id/print/team-crosstable` - see the module doc. Always the current
  picture; the sheet says so with a postponed or missing-result banner when it
  is not final.
  """
  def cross_table(conn, %{"id" => id}) do
    with_team_tournament(conn, id, fn tournament ->
      cross = TeamSheets.cross_table(tournament)

      body =
        Print.tournament_info_html(tournament) <>
          Print.postponed_banner(tournament, nil) <>
          cross_table_html(cross)

      Print.print_page(
        conn,
        tournament,
        tournament.name,
        gettext("Team cross table after round %{n}", n: cross.rounds),
        body,
        @cross_css
      )
    end)
  end

  defp cross_table_html(%{kind: :round_robin} = cross) do
    numbers = Enum.map(cross.teams, & &1.number)

    head =
      "<th>#{gettext("No.")}</th><th class=\"tc-team\">#{gettext("Team")}</th>" <>
        Enum.map_join(numbers, "", &"<th>#{&1}</th>") <>
        "<th>MP</th><th>GP</th><th>#{gettext("Rank")}</th>"

    rows =
      Enum.map_join(cross.teams, "", fn row ->
        cells =
          Enum.map_join(cross.teams, "", fn col ->
            if col.team.id == row.team.id do
              "<td class=\"tc-diag\"></td>"
            else
              "<td>#{rr_cell(Map.get(row.cells, col.team.id, []))}</td>"
            end
          end)

        "<tr><td>#{row.number}</td><td class=\"tc-team\"><strong>#{Print.esc(row.team.name)}</strong></td>" <>
          cells <>
          "<td class=\"tc-total\">#{Print.esc(Print.format_num(row.mp))}</td>" <>
          "<td class=\"tc-total\">#{Print.esc(Print.format_num(row.gp))}</td>" <>
          "<td>#{row.rank}</td></tr>"
      end)

    table(head, rows)
  end

  defp cross_table_html(%{kind: :swiss} = cross) do
    head =
      "<th>#{gettext("Rank")}</th><th>#{gettext("No.")}</th><th class=\"tc-team\">#{gettext("Team")}</th>" <>
        Enum.map_join(1..max(cross.rounds, 1), "", &"<th>R#{&1}</th>") <>
        "<th>MP</th><th>GP</th>"

    rows =
      Enum.map_join(cross.rows, "", fn row ->
        "<tr><td>#{row.rank}</td><td>#{row.number}</td>" <>
          "<td class=\"tc-team\"><strong>#{Print.esc(row.team.name)}</strong></td>" <>
          Enum.map_join(row.rounds, "", &swiss_cell/1) <>
          "<td class=\"tc-total\">#{Print.esc(Print.format_num(row.mp))}</td>" <>
          "<td class=\"tc-total\">#{Print.esc(Print.format_num(row.gp))}</td></tr>"
      end)

    table(head, rows)
  end

  defp table(head, rows) do
    "<div class=\"crosstable-wrap\"><table id=\"team-cross-table\" class=\"team-cross\">" <>
      "<thead><tr>#{head}</tr></thead><tbody>#{rows}</tbody></table></div>"
  end

  defp rr_cell([]), do: "&middot;"

  defp rr_cell(meetings) do
    meetings
    |> Enum.sort_by(& &1.round)
    |> Enum.map_join(" / ", fn c ->
      if c.gp, do: Print.esc(points_text(c.gp)), else: "&middot;"
    end)
  end

  defp swiss_cell(nil), do: "<td class=\"tc-round\"></td>"

  defp swiss_cell(%{bye?: true} = c) do
    "<td class=\"tc-round\"><div class=\"tc-opp\">#{gettext("bye")}</div>" <>
      "<div class=\"tc-mp\">MP #{Print.esc(Print.format_num(c.mp_total))}</div></td>"
  end

  defp swiss_cell(c) do
    colour = if c.colour == :white, do: "w", else: "b"

    score =
      if c.gp,
        do:
          "<div class=\"tc-score\">#{Print.esc(points_text(c.gp))}-#{Print.esc(points_text(c.opp_gp))}</div>",
        else: ""

    mp =
      if c.mp,
        do: "<div class=\"tc-mp\">MP #{Print.esc(Print.format_num(c.mp_total))}</div>",
        else: ""

    "<td class=\"tc-round\"><div class=\"tc-opp\">#{c.opponent_number} #{colour}</div>#{score}#{mp}</td>"
  end

  ## ---------- match result sheets ----------

  @doc """
  `GET /t/:id/print/team-match-sheets?round=n&match=id` - see the module doc.
  """
  def match_sheets(conn, %{"id" => id} = params) do
    with_team_tournament(conn, id, fn tournament ->
      number =
        Print.parse_round(params["round"]) || max(Standings.rounds_paired(tournament.id), 1)

      opts = match_opts(params["match"])

      case TeamSheets.match_sheets(tournament, number, opts) do
        :error ->
          send_resp(conn, 404, gettext("Round %{n} has no team matches", n: number))

        {:ok, %{sheets: sheets} = sheets_data} ->
          body = Enum.map_join(sheets, "", &match_sheet_html(&1, tournament, sheets_data))

          Print.print_page(
            conn,
            tournament,
            tournament.name,
            gettext("Match result sheets - round %{n}", n: number),
            body,
            @sheet_css
          )
      end
    end)
  end

  defp match_opts(nil), do: []

  defp match_opts(value) do
    case Integer.parse(value) do
      {n, ""} -> [match_id: n]
      _ -> [match_id: -1]
    end
  end

  defp match_sheet_html(sheet, tournament, %{round: round, date: date}) do
    a = sheet.team_a
    b = sheet.team_b
    entered? = Enum.any?(sheet.rows, &(&1.result != ""))
    m = sheet.match

    meta =
      [
        gettext("Round %{n}", n: round),
        gettext("Match %{n}", n: sheet.number),
        date && Print.esc(date)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" &middot; ")

    head =
      "<div class=\"ms-head\"><strong>#{Print.esc(tournament.name)}</strong><span>#{meta}</span></div>"

    title =
      "<h2><span class=\"ms-title\">#{Print.esc(a.name)} &ndash; #{Print.esc(b.name)}</span>" <>
        "<span>#{gettext("%{team} has White on board 1", team: Print.esc(a.name))}</span></h2>"

    rows = Enum.map_join(sheet.rows, "", &sheet_row_html/1)

    boards =
      "<table class=\"ms-boards\"><thead><tr>" <>
        "<th class=\"num\">#{gettext("Bd")}</th><th>#{gettext("Col.")}</th>" <>
        "<th>#{Print.esc(a.name)}</th><th class=\"num\">Elo</th>" <>
        "<th style=\"text-align:center\">#{gettext("Result")}</th>" <>
        "<th>#{Print.esc(b.name)}</th><th class=\"num\">Elo</th><th>#{gettext("Col.")}</th>" <>
        "</tr></thead><tbody>#{rows}</tbody></table>"

    score_box =
      if entered?,
        do: "#{points_text(m.gp_a)} - #{points_text(m.gp_b)}",
        else: "&nbsp;"

    total =
      "<div class=\"ms-total\"><span>#{gettext("Match score")}</span>" <>
        "<span class=\"ms-result\">#{score_box}</span></div>"

    sigs =
      "<div class=\"ms-sigs\">" <>
        sig(gettext("Captain %{team}", team: Print.esc(a.name)), a) <>
        sig(gettext("Captain %{team}", team: Print.esc(b.name)), b) <>
        "<div class=\"ms-sig\">#{gettext("Arbiter")}" <>
        arbiter_name(tournament) <> "</div></div>"

    "<section class=\"match-sheet\" id=\"match-sheet-#{m.match_id}\">#{head}#{title}#{boards}#{total}#{sigs}" <>
      "<p class=\"ms-note\">#{gettext("Results are written from the first-named team's side: 1 - 0 is a win for %{team}.", team: Print.esc(a.name))}</p></section>"
  end

  defp sig(label, %Team{captain: captain}) do
    name = if captain in [nil, ""], do: "", else: "<small>#{Print.esc(captain)}</small>"
    "<div class=\"ms-sig\">#{label}#{name}</div>"
  end

  defp arbiter_name(%{chief_arbiter: name}) when name not in [nil, ""],
    do: "<small>#{Print.esc(name)}</small>"

  defp arbiter_name(_), do: ""

  defp sheet_row_html(row) do
    b_colour = if row.a_colour == :white, do: :black, else: :white

    "<tr><td class=\"num\"><strong>#{row.board}</strong>" <>
      "<span class=\"ms-table-no\">#{gettext("table %{n}", n: row.round_board)}</span></td>" <>
      "<td>#{colour_text(row.a_colour)}</td>" <>
      "<td class=\"ms-name\"><strong>#{Print.esc(seat_name(row.a_player))}</strong></td>" <>
      "<td class=\"num\">#{rating_text(row.a_player, row.a_rating)}</td>" <>
      "<td style=\"text-align:center\"><span class=\"ms-result\">#{result_text(row)}</span></td>" <>
      "<td class=\"ms-name\"><strong>#{Print.esc(seat_name(row.b_player))}</strong></td>" <>
      "<td class=\"num\">#{rating_text(row.b_player, row.b_rating)}</td>" <>
      "<td>#{colour_text(b_colour)}</td></tr>"
  end

  defp colour_text(:white), do: gettext("White")
  defp colour_text(:black), do: gettext("Black")

  defp seat_name(nil), do: gettext("- no player -")
  defp seat_name(player), do: player.name

  defp rating_text(nil, _), do: ""
  defp rating_text(_player, rating) when rating in [nil, 0], do: ""
  defp rating_text(_player, rating), do: Integer.to_string(rating)

  # The board's result from the first-named team's side, so a sheet reads
  # left to right the way the line-up does whatever the colours are.
  defp result_text(%{result: ""}), do: "&nbsp;"
  defp result_text(%{postponed?: true}), do: gettext("postponed")

  defp result_text(row) do
    text = "#{points_text(row.a_points)} - #{points_text(row.b_points)}"
    if row.forfeit?, do: Print.esc(text) <> " ff", else: Print.esc(text)
  end

  ## ---------- rosters ----------

  @doc """
  `GET /t/:id/print/team-rosters?team=id` - see the module doc.
  """
  def rosters(conn, %{"id" => id} = params) do
    with_team_tournament(conn, id, fn tournament ->
      rosters = TeamSheets.rosters(tournament)

      rosters =
        case params["team"] do
          nil -> rosters
          team_id -> Enum.filter(rosters, &(to_string(&1.team.id) == team_id))
        end

      if rosters == [] do
        send_resp(conn, 404, gettext("No such team"))
      else
        Print.print_page(
          conn,
          tournament,
          tournament.name,
          gettext("Team rosters - board order"),
          Print.tournament_info_html(tournament) <> Enum.map_join(rosters, "", &roster_html/1),
          @roster_css
        )
      end
    end)
  end

  defp roster_html(%{team: team, number: number, players: players}) do
    captain =
      if team.captain in [nil, ""],
        do: "",
        else: " &middot; " <> gettext("Captain: %{name}", name: Print.esc(team.captain))

    rows =
      Enum.map_join(players, "", fn %{board: k, player: p} ->
        out =
          if p.status == "active",
            do: "",
            else: " <span class=\"out\">(#{Print.esc(p.status)})</span>"

        "<tr><td class=\"num\">#{k}</td>" <>
          "<td>#{Print.esc(p.title)}</td>" <>
          "<td><strong>#{Print.esc(p.name)}</strong>#{out}</td>" <>
          "<td class=\"num\">#{Print.blank_zero(Tournaments.Player.rating(p))}</td>" <>
          "<td class=\"num\">#{p.fide_id}</td>" <>
          "<td>#{Print.esc(p.federation)}</td></tr>"
      end)

    "<section class=\"roster\" id=\"roster-#{team.id}\">" <>
      "<h2>#{number}. #{Print.esc(team.name)}</h2>" <>
      "<p class=\"roster-meta\">#{ngettext("%{count} player", "%{count} players", length(players))}#{captain}</p>" <>
      "<table><thead><tr><th class=\"num\">#{gettext("Bd")}</th><th>#{gettext("Title")}</th>" <>
      "<th>#{gettext("Name")}</th><th class=\"num\">Elo</th><th class=\"num\">FIDE ID</th>" <>
      "<th>#{gettext("Fed.")}</th></tr></thead><tbody>#{rows}</tbody></table></section>"
  end

  ## ---------- board prizes ----------

  @doc """
  `GET /t/:id/print/board-prizes?min_games=n` - see the module doc.
  """
  def board_prizes(conn, %{"id" => id} = params) do
    with_team_tournament(conn, id, fn tournament ->
      min_games = parse_min_games(params["min_games"])
      boards = TeamSheets.board_prizes(tournament, min_games: min_games)
      teams = tournament.id |> Tournaments.list_teams() |> Map.new(&{&1.id, &1})

      body =
        Print.tournament_info_html(tournament) <>
          Print.postponed_banner(tournament, nil) <>
          if(boards == [],
            do: "<p>#{gettext("No board results yet.")}</p>",
            else: Enum.map_join(boards, "", &prize_board_html(&1, teams))
          )

      Print.print_page(
        conn,
        tournament,
        tournament.name,
        gettext("Board prizes"),
        body,
        @prize_css
      )
    end)
  end

  defp parse_min_games(value) do
    case value && Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp prize_board_html(%{board: board, rows: rows}, teams) do
    body =
      Enum.map_join(rows, "", fn %{rank: rank, stat: s} ->
        team = Map.get(teams, s.team_id)

        "<tr><td class=\"num\">#{rank}</td>" <>
          "<td><strong>#{Print.esc(s.player.name)}</strong></td>" <>
          "<td>#{Print.esc(team && team.name)}</td>" <>
          "<td class=\"num\">#{s.games}</td>" <>
          "<td class=\"num\">#{Print.esc(points_text(s.points))}</td>" <>
          "<td class=\"num\">#{if s.percentage, do: Print.esc(Print.format_num(s.percentage)), else: "-"}</td>" <>
          "<td class=\"num\">#{s.performance || "-"}</td></tr>"
      end)

    "<section class=\"prize-board\" id=\"prize-board-#{board}\"><h2>#{gettext("Board %{n}", n: board)}</h2>" <>
      "<table><thead><tr><th class=\"num\">#</th><th>#{gettext("Name")}</th><th>#{gettext("Team")}</th>" <>
      "<th class=\"num\">#{gettext("Games")}</th><th class=\"num\">Pts</th><th class=\"num\">%</th>" <>
      "<th class=\"num\">#{gettext("Perf")}</th></tr></thead><tbody>#{body}</tbody></table></section>"
  end

  ## ---------- shared ----------

  defp with_team_tournament(conn, id, fun) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)

    if Tournament.paired_as_teams?(tournament) do
      fun.(tournament)
    else
      send_resp(conn, 404, gettext("This is not a team tournament"))
    end
  end
end
