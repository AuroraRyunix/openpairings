defmodule PairingsEngineWeb.PrintController do
  @moduledoc """
  Print-friendly, print()-on-load HTML documents for a tournament. See
  `docs/printing.md` for the full reference (every document, its route, the
  `round` query param, and which pages link to which document).

  Quick summary:

    * `GET /t/:id/print/players`   — roster, no round scoping.
    * `GET /t/:id/print/cards`     — one card per player, full round-by-round
      history (never limited to a single round).
    * `GET /t/:id/print/pairings?round=n` — board pairings for round `n`.
      Defaults to round 1; 404s if that round hasn't been paired.
    * `GET /t/:id/print/standings?round=n` — standings as they stood right
      after round `n` (computed honestly via `PairingsEngine.Standings`,
      passing only rounds `<= n`). Omit `round` for current/overall
      standings. 404s if round `n` hasn't been paired yet.
    * `GET /t/:id/print/results?round=n` — one result slip per board of
      round `n` (byes skipped). `round` defaults to the latest paired round;
      404s if round `n` hasn't been paired.
    * `GET /t/:id/print/crosstable` — full Swiss cross table: one row per
      player (current standings order), one column per played round.
  """

  use PairingsEngineWeb, :controller

  alias PairingsEngine.{Tournaments, Keizer}

  import Phoenix.HTML, only: [html_escape: 1, safe_to_string: 1]

  @print_css """
  * { box-sizing: border-box; }
  body { font-family: 'Segoe UI', system-ui, sans-serif; color: #111; margin: 24px; }
  h1 { font-size: 20px; margin: 0 0 2px; }
  .sub { color: #555; margin: 0 0 18px; font-size: 13px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th { text-align: left; border-bottom: 2px solid #000; padding: 5px 8px; font-size: 11px;
       text-transform: uppercase; letter-spacing: 0.04em; }
  td { padding: 5px 8px; border-bottom: 1px solid #ccc; }
  .num { text-align: right; }
  .player-card { border: 1.5px solid #000; padding: 14px 16px; margin-bottom: 16px;
                 page-break-inside: avoid; }
  .player-card h2 { font-size: 16px; margin: 0; }
  .player-card .meta { color: #444; font-size: 12.5px; margin: 2px 0 10px; }
  .player-card table td, .player-card table th { padding: 4px 8px; }
  @media print { .player-card { break-inside: avoid; } }
  """

  @result_cards_css """
  @page { size: A4 portrait; margin: 10mm; }
  .result-card { border: 1px dashed #000; box-sizing: border-box; height: 90mm; padding: 10px 16px;
                 margin-bottom: 0; display: flex; flex-direction: column; page-break-inside: avoid; }
  .result-card:nth-child(3n) { page-break-after: always; }
  .result-card .rc-head { display: flex; justify-content: space-between; font-size: 12px; color: #444; }
  .result-card .rc-head strong { color: #111; }
  .result-card .rc-players { display: flex; align-items: center; justify-content: space-between;
                              margin: 10px 0 18px; }
  .result-card .rc-player { font-size: 15px; max-width: 42%; }
  .result-card .rc-player .rc-sub { display: block; color: #555; font-size: 11.5px; margin-top: 2px; }
  .result-card .rc-vs { color: #999; font-size: 12px; padding: 0 8px; }
  .result-card .rc-result-row { display: flex; justify-content: center; gap: 56px;
                                 font-size: 26px; font-weight: bold; margin: 6px 0 14px; }
  .result-card .rc-other-row { text-align: center; font-size: 12px; color: #555; margin-bottom: auto; }
  .result-card .rc-sign-row { display: flex; justify-content: space-between; margin-top: 10px; }
  .result-card .rc-sign-row .sig { border-top: 1px solid #000; width: 44%; padding-top: 4px;
                                    text-align: center; font-size: 11px; color: #444; }
  @media print { .result-card { break-inside: avoid; } }
  """

  @crosstable_css """
  @page { size: A4 landscape; margin: 12mm; }
  .crosstable-wrap { overflow-x: auto; }
  table.crosstable { font-size: 11px; white-space: nowrap; }
  table.crosstable th, table.crosstable td { padding: 4px 6px; }
  """

  def player_list(conn, %{"id" => id}) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)
    players = Tournaments.list_players(tournament.id)

    rows =
      players
      |> Enum.with_index(1)
      |> Enum.map_join("", fn {p, i} ->
        "<tr><td class=\"num\">#{i}</td><td>#{esc(p.title)}</td><td><strong>#{esc(p.name)}</strong></td>" <>
          "<td class=\"num\">#{blank_zero(p.fide_rating)}</td><td class=\"num\">#{blank_zero(p.national_rating)}</td>" <>
          "<td>#{esc(p.federation)}</td><td>#{esc(p.club)}</td></tr>"
      end)

    body =
      "<table><thead><tr><th class=\"num\">#</th><th>Title</th><th>Name</th><th class=\"num\">FIDE</th>" <>
        "<th class=\"num\">Nat.</th><th>Fed</th><th>Club</th></tr></thead><tbody>#{rows}</tbody></table>"

    print_page(conn, tournament.name, "Registered players (#{length(players)})", body)
  end

  def player_cards(conn, %{"id" => id}) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)
    players = Tournaments.list_players(tournament.id)

    round_rows =
      Enum.map_join(1..tournament.rounds_count, "", fn n ->
        "<tr><td class=\"num\">#{n}</td><td></td><td></td><td></td><td></td></tr>"
      end)

    cards =
      players
      |> Enum.with_index(1)
      |> Enum.map_join("", fn {p, i} ->
        meta =
          [
            if(p.fide_rating > 0, do: "FIDE #{p.fide_rating}"),
            if(p.national_rating > 0, do: "Nat. #{p.national_rating}"),
            if(p.federation != "", do: esc(p.federation)),
            if(p.club != "", do: esc(p.club))
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" · ")

        "<div class=\"player-card\"><h2>#{i}. #{esc(p.title)} #{esc(p.name)}</h2>" <>
          "<p class=\"meta\">#{meta}</p>" <>
          "<table><thead><tr><th class=\"num\">Rd</th><th>Opponent</th><th>Colour</th>" <>
          "<th>Result</th><th>Score</th></tr></thead><tbody>#{round_rows}</tbody></table></div>"
      end)

    print_page(conn, tournament.name, "Player cards", cards)
  end

  def pairing_list(conn, %{"id" => id} = params) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)
    number = parse_round(params["round"]) || 1
    round = Tournaments.get_round(tournament.id, number)

    if round == nil do
      send_resp(conn, 404, "Round #{number} has not been paired yet")
    else
      rows =
        Enum.map_join(round.pairings, "", fn p ->
          "<tr><td class=\"num\">#{p.board}#{fixed_board_note(p)}</td>" <>
            "<td><strong>#{esc(p.white_player && p.white_player.name)}</strong></td>" <>
            "<td class=\"num\">#{p.white_player && blank_zero(player_rating(p.white_player))}</td>" <>
            "<td style=\"text-align:center\">#{esc(display_result(p.result))}</td>" <>
            "<td><strong>#{esc((p.black_player && p.black_player.name) || "— bye —")}</strong></td>" <>
            "<td class=\"num\">#{p.black_player && blank_zero(player_rating(p.black_player))}</td></tr>"
        end)

      body =
        "<table><thead><tr><th class=\"num\">Board</th><th>White</th><th class=\"num\">Elo</th>" <>
          "<th style=\"text-align:center\">Result</th><th>Black</th><th class=\"num\">Elo</th></tr></thead>" <>
          "<tbody>#{rows}</tbody></table>"

      print_page(conn, tournament.name, "Pairings — round #{number}", body)
    end
  end

  def standings(conn, %{"id" => id} = params) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)
    rounds_paired = PairingsEngine.Standings.rounds_paired(tournament.id)
    requested_round = parse_round(params["round"])
    keizer? = tournament.pairing_system == "keizer"

    cond do
      requested_round != nil and Tournaments.get_round(tournament.id, requested_round) == nil ->
        send_resp(conn, 404, "Round #{requested_round} has not been paired yet")

      true ->
        entries =
          case {keizer?, requested_round} do
            {true, nil} -> Keizer.standings(tournament)
            {true, n} -> Keizer.standings(tournament, through_round: n)
            {false, nil} -> PairingsEngine.Standings.standings(tournament)
            {false, n} -> PairingsEngine.Standings.standings(tournament, through_round: n)
          end

        label = requested_round || rounds_paired

        print_page(
          conn,
          tournament.name,
          "Standings after round #{label}",
          standings_body(entries, tournament, keizer?)
        )
    end
  end

  # Tournaments without categories render exactly as before (byte-identical):
  # no Category column, no per-category tables. Tournaments with categories
  # get a Category column on the main table plus one small standings table
  # per category afterwards — same ordering (each category's ranks are the
  # overall ranks, just filtered), not re-ranked within the category.
  #
  # Keizer tournaments (`keizer? == true`) render the ladder columns
  # (Rank/Name/Elo/Value/Keizer pts/Score) instead of the FIDE points +
  # tiebreak columns — same table shape `PairingsEngineWeb.StandingsLive`
  # uses for a Keizer tournament — with the same category treatment.
  defp standings_body(entries, tournament, true) do
    has_categories = tournament.categories != []
    cat_header = if has_categories, do: "<th>Category</th>", else: ""

    rows = Enum.map_join(entries, "", &keizer_standings_row(&1, has_categories))

    main_table =
      "<table><thead><tr><th class=\"num\">Rank</th><th>Name</th><th class=\"num\">Elo</th>" <>
        "<th class=\"num\">Value</th><th class=\"num\">Keizer pts</th><th class=\"num\">Score</th>" <>
        "#{cat_header}</tr></thead><tbody>#{rows}</tbody></table>"

    if has_categories do
      main_table <> keizer_category_standings_tables(entries, tournament)
    else
      main_table
    end
  end

  defp standings_body(entries, tournament, false) do
    has_categories = tournament.categories != []

    tb_headers = Enum.map_join(tournament.tiebreaks, "", &"<th class=\"num\">#{esc(&1)}</th>")
    cat_header = if has_categories, do: "<th>Category</th>", else: ""

    rows =
      Enum.map_join(entries, "", fn e ->
        cat_cell =
          if has_categories,
            do: "<td>#{esc(category_or_dash(e.player.category))}</td>",
            else: ""

        standings_row(e, tournament, cat_cell)
      end)

    main_table =
      "<table><thead><tr><th class=\"num\">Rank</th><th>Name</th><th class=\"num\">Elo</th>" <>
        "<th class=\"num\">Pts</th>#{tb_headers}#{cat_header}</tr></thead><tbody>#{rows}</tbody></table>"

    if has_categories do
      main_table <> category_standings_tables(entries, tournament)
    else
      main_table
    end
  end

  defp category_standings_tables(entries, tournament) do
    tb_headers = Enum.map_join(tournament.tiebreaks, "", &"<th class=\"num\">#{esc(&1)}</th>")

    Enum.map_join(tournament.categories, "", fn category ->
      rows =
        entries
        |> Enum.filter(&(&1.player.category == category))
        |> Enum.map_join("", &standings_row(&1, tournament))

      "<h2 style=\"margin-top:24px\">Category: #{esc(category)}</h2>" <>
        "<table><thead><tr><th class=\"num\">Rank</th><th>Name</th><th class=\"num\">Elo</th>" <>
        "<th class=\"num\">Pts</th>#{tb_headers}</tr></thead><tbody>#{rows}</tbody></table>"
    end)
  end

  defp keizer_category_standings_tables(entries, tournament) do
    Enum.map_join(tournament.categories, "", fn category ->
      rows =
        entries
        |> Enum.filter(&(&1.player.category == category))
        |> Enum.map_join("", &keizer_standings_row(&1, false))

      "<h2 style=\"margin-top:24px\">Category: #{esc(category)}</h2>" <>
        "<table><thead><tr><th class=\"num\">Rank</th><th>Name</th><th class=\"num\">Elo</th>" <>
        "<th class=\"num\">Value</th><th class=\"num\">Keizer pts</th><th class=\"num\">Score</th>" <>
        "</tr></thead><tbody>#{rows}</tbody></table>"
    end)
  end

  defp standings_row(e, tournament, cat_cell \\ "") do
    tb_cells =
      Enum.map_join(tournament.tiebreaks, "", fn code ->
        "<td class=\"num\">#{Map.get(e.tiebreaks, code, 0.0)}</td>"
      end)

    "<tr><td class=\"num\">#{e.rank}</td><td><strong>#{esc(e.player.name)}</strong></td>" <>
      "<td class=\"num\">#{blank_zero(player_rating(e.player))}</td>" <>
      "<td class=\"num\"><strong>#{e.points}</strong></td>#{tb_cells}#{cat_cell}</tr>"
  end

  defp keizer_standings_row(e, has_categories) do
    cat_cell =
      if has_categories,
        do: "<td>#{esc(category_or_dash(e.player.category))}</td>",
        else: ""

    "<tr><td class=\"num\">#{e.rank}</td><td><strong>#{esc(e.player.name)}</strong></td>" <>
      "<td class=\"num\">#{blank_zero(player_rating(e.player))}</td>" <>
      "<td class=\"num\">#{e.value}</td><td class=\"num\"><strong>#{e.points}</strong></td>" <>
      "<td class=\"num\">#{e.raw_points}</td>#{cat_cell}</tr>"
  end

  defp category_or_dash(nil), do: "—"
  defp category_or_dash(""), do: "—"
  defp category_or_dash(category), do: category

  def result_cards(conn, %{"id" => id} = params) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)
    rounds_paired = PairingsEngine.Standings.rounds_paired(tournament.id)
    number = parse_round(params["round"]) || max(rounds_paired, 1)
    round = Tournaments.get_round(tournament.id, number)

    if round == nil do
      send_resp(conn, 404, "Round #{number} has not been paired yet")
    else
      cards =
        round.pairings
        |> Enum.reject(&(&1.black_player_id == nil))
        |> Enum.map_join("", &result_card(&1, tournament, number))

      print_page(
        conn,
        tournament.name,
        "Result cards — round #{number}",
        cards,
        @result_cards_css
      )
    end
  end

  def crosstable(conn, %{"id" => id}) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)
    rounds_paired = PairingsEngine.Standings.rounds_paired(tournament.id)
    entries = PairingsEngine.Standings.standings(tournament)
    by_id = Map.new(entries, &{&1.player.id, &1})
    rounds = if rounds_paired > 0, do: Enum.to_list(1..rounds_paired), else: []

    round_headers = Enum.map_join(rounds, "", &"<th class=\"num\">Rd #{&1}</th>")
    tb_headers = Enum.map_join(tournament.tiebreaks, "", &"<th class=\"num\">#{esc(&1)}</th>")

    rows =
      Enum.map_join(entries, "", fn e ->
        round_cells =
          Enum.map_join(rounds, "", fn n ->
            case Enum.find(e.games, &(&1.round == n)) do
              nil -> "<td class=\"num\"></td>"
              game -> "<td class=\"num\">#{esc(crosstable_cell(game, by_id, tournament))}</td>"
            end
          end)

        tb_cells =
          Enum.map_join(tournament.tiebreaks, "", fn code ->
            "<td class=\"num\">#{Map.get(e.tiebreaks, code, 0.0)}</td>"
          end)

        "<tr><td class=\"num\">#{e.rank}</td><td><strong>#{esc(e.player.name)}</strong></td>" <>
          "<td class=\"num\">#{blank_zero(player_rating(e.player))}</td>#{round_cells}" <>
          "<td class=\"num\"><strong>#{e.points}</strong></td>#{tb_cells}</tr>"
      end)

    body =
      "<div class=\"crosstable-wrap\"><table class=\"crosstable\"><thead><tr><th class=\"num\">Rank</th>" <>
        "<th>Name</th><th class=\"num\">Elo</th>#{round_headers}<th class=\"num\">Pts</th>#{tb_headers}" <>
        "</tr></thead><tbody>#{rows}</tbody></table></div>"

    print_page(conn, tournament.name, "Cross table", body, @crosstable_css)
  end

  defp result_card(pairing, tournament, round_number) do
    white = pairing.white_player
    black = pairing.black_player

    "<div class=\"result-card\">" <>
      "<div class=\"rc-head\"><strong>#{esc(tournament.name)}</strong>" <>
      "<span>Round #{round_number} &middot; Board #{pairing.board}</span></div>" <>
      "<div class=\"rc-players\">" <>
      "<div class=\"rc-player\">White: <strong>#{esc(result_card_name(white))}</strong>" <>
      "<span class=\"rc-sub\">#{result_card_sub(white)}</span></div>" <>
      "<div class=\"rc-vs\">vs</div>" <>
      "<div class=\"rc-player\">Black: <strong>#{esc(result_card_name(black))}</strong>" <>
      "<span class=\"rc-sub\">#{result_card_sub(black)}</span></div>" <>
      "</div>" <>
      "<div class=\"rc-result-row\"><span>1 &ndash; 0</span><span>&frac12; &ndash; &frac12;</span>" <>
      "<span>0 &ndash; 1</span></div>" <>
      "<div class=\"rc-other-row\">other: ............</div>" <>
      "<div class=\"rc-sign-row\"><div class=\"sig\">White</div><div class=\"sig\">Black</div></div>" <>
      "</div>"
  end

  defp result_card_name(nil), do: ""
  defp result_card_name(player), do: "#{if player.title != "", do: "#{player.title} "}#{player.name}"

  defp result_card_sub(nil), do: ""

  defp result_card_sub(player) do
    rating = player_rating(player)
    number = player.pairing_number

    [
      if(rating > 0, do: "#{rating}"),
      if(number, do: "N&deg;#{number}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" &middot; ")
  end

  # Compact cross-table cell notation, e.g. "12w1" (beat opponent #12 as
  # white), "5b½" (drew opponent #5 as black), "-w+" (forfeit win as white,
  # no real game so no opponent number shown), "bye".
  defp crosstable_cell(%{opponent_id: nil}, _by_id, _t), do: "bye"

  defp crosstable_cell(%{played: false, voluntary: false} = game, _by_id, t) do
    "-#{crosstable_colour(game.colour)}#{crosstable_forfeit_symbol(game, t)}"
  end

  defp crosstable_cell(game, by_id, t) do
    opponent_number =
      case Map.get(by_id, game.opponent_id) do
        nil -> "?"
        entry -> entry.player.pairing_number || "?"
      end

    "#{opponent_number}#{crosstable_colour(game.colour)}#{crosstable_result_symbol(game, t)}"
  end

  defp crosstable_colour(:w), do: "w"
  defp crosstable_colour(:b), do: "b"
  defp crosstable_colour(_), do: ""

  defp crosstable_forfeit_symbol(%{points: p}, t), do: if(p >= t.points_win, do: "+", else: "-")

  defp crosstable_result_symbol(%{points: p}, t) do
    cond do
      p >= t.points_win -> "1"
      p <= t.points_loss -> "0"
      true -> "½"
    end
  end

  # Display-only annotation for a board that involves a player with a
  # `fixed_board` override (SWAR "special table") — e.g. "(table 5)". Real
  # board renumbering happens nowhere; this purely flags it for the arbiter
  # printing the sheet. See docs/printing.md.
  defp fixed_board_note(pairing) do
    boards =
      [pairing.white_player, pairing.black_player]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.fixed_board)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case boards do
      [] -> ""
      boards -> " <span class=\"fixed-board-note\">(table #{Enum.join(boards, ", ")})</span>"
    end
  end

  defp parse_round(nil), do: nil
  defp parse_round(""), do: nil
  defp parse_round(value), do: String.to_integer(value)

  defp player_rating(player), do: PairingsEngine.Tournaments.Player.rating(player)

  defp display_result(""), do: ""
  defp display_result("1/2-1/2"), do: "½-½"
  defp display_result("bye"), do: "bye"
  defp display_result(result), do: result

  defp print_page(conn, title, subtitle, body, extra_css \\ "") do
    html = """
    <!doctype html><html><head><meta charset="utf-8"><title>#{esc(title)}</title>
    <style>#{@print_css}</style><style>#{extra_css}</style></head><body>
    <h1>#{esc(title)}</h1><p class="sub">#{esc(subtitle)}</p>#{body}
    <script>window.onload = () => window.print();</script></body></html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  defp esc(nil), do: ""
  defp esc(text), do: text |> html_escape() |> safe_to_string()

  defp blank_zero(0), do: ""
  defp blank_zero(n), do: to_string(n)
end
