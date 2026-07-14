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
      404s if round `n` hasn't been paired. Also accepts `?limit=L` (test
      print — only the first `L` cards) and `?order=stack` (stack-cut
      imposition — see `stack_cut_cards/3`), independently or combined.
    * `GET /t/:id/print/crosstable` — for Swiss and Keizer tournaments, the
      full Swiss cross table: one row per player (current standings order),
      one column per played round. For round-robin tournaments, instead the
      classic players×players grid: rows/columns ordered by pairing number,
      cell (A, B) is A's result against B (both cycles' results for a
      double round robin), diagonal hatched out.
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

  # Card height (30mm) + margin-bottom (2mm) = 32mm per card. Eight of those
  # stack to 256mm, comfortably inside the 277mm an A4 portrait page has left
  # after 10mm top/bottom margins (leaving headroom for the page-1 title/
  # subtitle that `print_page/5` always renders above the cards). One
  # compact row per board: header line, then a single players+signatures
  # line, then the circle-one result line — see `result_card/3`.
  @result_cards_css """
  @page { size: A4 portrait; margin: 10mm; }
  .result-card { border: 1px dashed #000; box-sizing: border-box; height: 30mm; padding: 2mm 4mm;
                 margin-bottom: 2mm; display: flex; flex-direction: column; justify-content: space-between;
                 page-break-inside: avoid; }
  .result-card:nth-child(8n) { page-break-after: always; margin-bottom: 0; }
  .result-card .rc-head { display: flex; justify-content: space-between; font-size: 8.5px; color: #555; }
  .result-card .rc-head strong { color: #111; }
  .result-card .rc-players { display: flex; align-items: baseline; justify-content: space-between; gap: 8px; }
  .result-card .rc-player { font-size: 11px; display: flex; align-items: baseline; gap: 5px; flex: 1 1 46%;
                             min-width: 0; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
  .result-card .rc-player.rc-black { flex-direction: row-reverse; justify-content: flex-end; }
  .result-card .rc-who { font-size: 7.5px; color: #777; text-transform: uppercase; letter-spacing: 0.04em; }
  .result-card .rc-sub { color: #666; font-size: 8.5px; font-weight: normal; }
  .result-card .rc-sig { font-size: 8px; color: #666; display: inline-flex; align-items: baseline; gap: 3px; }
  .result-card .rc-sig i { font-style: normal; display: inline-block; width: 16mm; border-bottom: 1px solid #000; }
  .result-card .rc-result-row { display: flex; align-items: baseline; justify-content: center; gap: 26px;
                                 font-size: 18px; font-weight: bold; }
  .result-card .rc-result-row .rc-other { margin-left: auto; font-size: 8px; font-weight: normal; color: #666; }
  @media print { .result-card { break-inside: avoid; } }
  .result-card.rc-blank { border-style: none; }
  """

  @crosstable_css """
  @page { size: A4 landscape; margin: 12mm; }
  .crosstable-wrap { overflow-x: auto; }
  table.crosstable { font-size: 11px; white-space: nowrap; }
  table.crosstable th, table.crosstable td { padding: 4px 6px; }
  """

  # Same page/table rules as @crosstable_css, plus the diagonal "self" cell
  # of a round-robin players×players grid — hatched via a CSS gradient (no
  # image asset needed) rather than solid black, so it still reads as "not a
  # result" rather than looking like a printing error.
  @rr_crosstable_css @crosstable_css <> """
  table.crosstable td.rr-diag {
    background-image: repeating-linear-gradient(45deg, #000 0, #000 2px, transparent 2px, transparent 6px);
  }
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
      pairings = Enum.reject(round.pairings, &(&1.black_player_id == nil))

      pairings =
        case parse_limit(params["limit"]) do
          nil -> pairings
          limit -> Enum.take(pairings, limit)
        end

      cards =
        case params["order"] do
          "stack" -> stack_cut_cards(pairings, tournament, number)
          _ -> Enum.map_join(pairings, "", &result_card(&1, tournament, number))
        end

      print_page(
        conn,
        tournament.name,
        "Result cards — round #{number}",
        cards,
        @result_cards_css
      )
    end
  end

  # Guillotine-cut ("stack-cut") imposition for `?order=stack`. The arbiter
  # prints every page, stacks the whole printout, then makes 8 straight
  # guillotine cuts — one between each pair of adjacent card rows — turning
  # the stack into 8 piles, one per card *slot* (1st-from-top card of every
  # page in pile 1, 2nd-from-top of every page in pile 2, and so on). Piles
  # are then collated top-to-bottom: pile 1 first, then pile 2, etc.
  #
  # With the default board-order layout, pile 1 would hold boards 1, 9, 17,
  # ... (every 8th board) — useless. Instead, with `P` total pages, we place
  # board index `s*P + p` (0-based) into slot `s` (0-based, top to bottom) of
  # page `p` (0-based), so that collating the piles afterwards recovers plain
  # board order 1, 2, 3, ... Slots run out of real cards past `n` — a `P`-th
  # of the way into the *last* slot(s) — those render as blank placeholder
  # cards (`.rc-blank`, borderless) purely to keep every page's card count
  # (and thus the cut geometry) at a fixed 8, not to be printed on.
  #
  # Worked example — 20 cards, 8 per page -> P = ceil(20/8) = 3 pages:
  #
  #   slot 0: boards  0, 1, 2      (indices 0*3+0, 0*3+1, 0*3+2)
  #   slot 1: boards  3, 4, 5
  #   slot 2: boards  6, 7, 8
  #   slot 3: boards  9,10,11
  #   slot 4: boards 12,13,14
  #   slot 5: boards 15,16,17
  #   slot 6: boards 18,19,blank   (index 20 is out of range — n == 20)
  #   slot 7: blank,blank,blank
  #
  # Every pile is full (3 cards) except slot 6 (2 real + 1 blank) and slot 7
  # (all blank) — i.e. only the *last* pile(s) are short, exactly as
  # required. `?order=stack` combines with `?limit`: limiting trims the
  # board-ordered list first, and this imposition runs over whatever's left.
  defp stack_cut_cards([], _tournament, _round_number), do: ""

  defp stack_cut_cards(pairings, tournament, round_number) do
    n = length(pairings)
    pages = div(n + 7, 8)
    ordered = List.to_tuple(pairings)

    for p <- 0..(pages - 1), s <- 0..7, into: "" do
      idx = s * pages + p

      if idx < n do
        result_card(elem(ordered, idx), tournament, round_number)
      else
        blank_result_card()
      end
    end
  end

  defp blank_result_card, do: "<div class=\"result-card rc-blank\"></div>"

  @doc """
  `GET /t/:id/print/crosstable` — dispatches on `tournament.pairing_system`:
  round robin gets the classic players×players grid (`round_robin_crosstable/2`),
  everything else (Swiss, Keizer) keeps the existing round-by-round Swiss
  cross table (`swiss_crosstable/2`) unchanged.
  """
  def crosstable(conn, %{"id" => id}) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)

    if tournament.pairing_system == "round_robin" do
      round_robin_crosstable(conn, tournament)
    else
      swiss_crosstable(conn, tournament)
    end
  end

  defp swiss_crosstable(conn, tournament) do
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

  # Classic round-robin players×players grid: rows and columns are the same
  # players, ordered by (frozen) pairing_number — column headers are pairing
  # numbers, not opponent names, the same cross-referencing convention the
  # Swiss cross table's cells use. Only players who actually have a
  # pairing_number are included as rows/columns — round robin freezes that
  # set at its first pairing (see `PairingsEngine.RoundRobin`) and never
  # grows it, so anyone without one was never scheduled at all and has
  # nothing to show here. A double round robin's structural odd-player-count
  # bye never appears as a column (there's no real opponent to cross-
  # reference), but its zero points are already folded into the player's
  # "Pts" total via `PairingsEngine.Standings`.
  defp round_robin_crosstable(conn, tournament) do
    entries = PairingsEngine.Standings.standings(tournament)

    players =
      entries
      |> Enum.filter(&(&1.player.pairing_number != nil))
      |> Enum.sort_by(& &1.player.pairing_number)

    col_headers = Enum.map_join(players, "", &"<th class=\"num\">#{&1.player.pairing_number}</th>")

    rows =
      Enum.map_join(players, "", fn row_entry ->
        cells = Enum.map_join(players, "", &rr_crosstable_cell(row_entry, &1, tournament))

        "<tr><td class=\"num\">#{row_entry.player.pairing_number}</td>" <>
          "<td><strong>#{esc(row_entry.player.name)}</strong></td>#{cells}" <>
          "<td class=\"num\"><strong>#{row_entry.points}</strong></td>" <>
          "<td class=\"num\">#{row_entry.rank}</td></tr>"
      end)

    body =
      "<div class=\"crosstable-wrap\"><table class=\"crosstable rr-crosstable\"><thead><tr><th class=\"num\">#</th>" <>
        "<th>Name</th>#{col_headers}<th class=\"num\">Pts</th><th class=\"num\">Rank</th></tr></thead>" <>
        "<tbody>#{rows}</tbody></table></div>"

    print_page(conn, tournament.name, "Cross table", body, @rr_crosstable_css)
  end

  # `row_entry`'s result(s) against `col_entry`, from `row_entry`'s own game
  # list (already filtered to that opponent) sorted by round ascending — for
  # a double round robin (rr_cycles == 2) this naturally puts the first
  # cycle's result before the second's, since cycle 1's rounds are always
  # numbered lower. A pairing with no result yet simply isn't in `.games`
  # (see `PairingsEngine.Standings.pairing_records/3`), so the cell is blank
  # rather than guessing.
  defp rr_crosstable_cell(row_entry, col_entry, _tournament)
       when row_entry.player.id == col_entry.player.id,
       do: "<td class=\"num rr-diag\"></td>"

  defp rr_crosstable_cell(row_entry, col_entry, tournament) do
    symbols =
      row_entry.games
      |> Enum.filter(&(&1.opponent_id == col_entry.player.id))
      |> Enum.sort_by(& &1.round)
      |> Enum.map_join(" ", &rr_result_symbol(&1, tournament))

    "<td class=\"num\">#{symbols}</td>"
  end

  # Played games use the ordinary 1 / ½ / 0 result symbol; a forfeit (no
  # game played) uses the win/loss-shaped +/- symbol instead — reusing
  # `crosstable_result_symbol/2` and `crosstable_forfeit_symbol/2` below,
  # the same distinction the Swiss cross table's cells already draw.
  defp rr_result_symbol(game, tournament) do
    if game.played,
      do: crosstable_result_symbol(game, tournament),
      else: crosstable_forfeit_symbol(game, tournament)
  end

  defp result_card(pairing, tournament, round_number) do
    white = pairing.white_player
    black = pairing.black_player

    "<div class=\"result-card\">" <>
      "<div class=\"rc-head\"><strong>#{esc(tournament.name)}</strong>" <>
      "<span>Round #{round_number} &middot; Board #{pairing.board}#{fixed_board_note(pairing)}</span></div>" <>
      "<div class=\"rc-players\">" <>
      "<div class=\"rc-player\"><span class=\"rc-who\">White</span> <strong>#{esc(result_card_name(white))}</strong>" <>
      "<span class=\"rc-sub\">#{result_card_sub(white)}</span>" <>
      "<span class=\"rc-sig\">Sign <i></i></span></div>" <>
      "<div class=\"rc-player rc-black\"><span class=\"rc-sig\">Sign <i></i></span>" <>
      "<span class=\"rc-sub\">#{result_card_sub(black)}</span> <strong>#{esc(result_card_name(black))}</strong>" <>
      "<span class=\"rc-who\">Black</span></div>" <>
      "</div>" <>
      "<div class=\"rc-result-row\"><span>1 &ndash; 0</span><span>&frac12; &ndash; &frac12;</span>" <>
      "<span>0 &ndash; 1</span><span class=\"rc-other\">other: ............</span></div>" <>
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

  # `?limit=L` for the result-cards test print: a positive integer keeps only
  # the first `L` cards (board order). Anything else — missing, blank,
  # non-numeric, zero, negative — is treated as "no limit" (full print)
  # rather than raising or 400ing, since a bad query param here is far more
  # likely to be a typo than an attack worth rejecting loudly.
  defp parse_limit(nil), do: nil
  defp parse_limit(""), do: nil

  defp parse_limit(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

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
