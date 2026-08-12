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
      Defaults to round 1; 404s if that round hasn't been paired. Also
      accepts `?absentees=1` to append a below-the-table "Absentees"
      section listing byes-table rows (requested half/zero-point byes,
      plain absences) — off by default.
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

  alias PairingsEngine.{Tournaments, Keizer, PairingDisplay}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  import Phoenix.HTML, only: [html_escape: 1, safe_to_string: 1]

  @print_css """
  * { box-sizing: border-box; }
  body { font-family: 'Segoe UI', system-ui, sans-serif; color: #111; margin: 24px; }
  .print-header { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; }
  .print-header-title { min-width: 0; }
  .print-header-logo { max-height: 18mm; max-width: 55mm; flex-shrink: 0; }
  h1 { font-size: 20px; margin: 0 0 2px; }
  .sub { color: #555; margin: 0 0 18px; font-size: 13px; }
  .tourney-info { color: #333; margin: 0 0 16px; font-size: 12px; border-bottom: 1px solid #ccc;
                  padding-bottom: 8px; }
  .tourney-info span:not(:last-child)::after { content: "\\00b7"; margin: 0 8px; color: #999; }
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
  .pf-credit { margin-top: 24px; padding-top: 8px; border-top: 1px solid #ccc;
               color: #888; font-size: 10px; }
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

  @score_sheet_css """
  @page { size: A4 portrait; margin: 10mm; }
  .score-sheet { page-break-after: always; height: 275mm; box-sizing: border-box;
                 display: flex; flex-direction: column; }
  .score-sheet:last-child { page-break-after: auto; }
  .ss-head { display: flex; justify-content: space-between; align-items: baseline;
             font-size: 12px; border-bottom: 2px solid #000; padding-bottom: 4px; }
  .ss-head strong { font-size: 14px; }
  .ss-players { display: flex; justify-content: space-between; gap: 16px; margin: 8px 0; font-size: 13px; }
  .ss-player { flex: 1 1 0; min-width: 0; }
  .ss-who { font-size: 9px; color: #666; text-transform: uppercase; letter-spacing: 0.04em; margin-right: 5px; }
  .ss-sub { color: #555; font-size: 11px; }
  .ss-grid { display: flex; gap: 10px; flex: 1; }
  .ss-moves { flex: 1; border-collapse: collapse; font-size: 11px; }
  .ss-moves th { font-size: 9px; color: #666; border-bottom: 1px solid #000; text-align: center; padding-bottom: 2px; }
  .ss-moves td { border-bottom: 1px solid #ccc; height: 5.3mm; }
  .ss-moves .ss-n { width: 8mm; text-align: right; color: #777; padding-right: 4px; border-right: 1px solid #000; }
  .ss-footer { margin-top: 8px; display: flex; justify-content: space-between; align-items: baseline; font-size: 12px; }
  .ss-result { font-weight: bold; }
  .ss-sig i { display: inline-block; width: 30mm; border-bottom: 1px solid #000; margin-left: 4px; }
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
  @rr_crosstable_css @crosstable_css <>
                       """
                       table.crosstable td.rr-diag {
                         background-image: repeating-linear-gradient(45deg, #000 0, #000 2px, transparent 2px, transparent 6px);
                       }
                       """

  # Place cards ("chevalets") — see docs/printing.md "Place cards" for the
  # full fold geometry writeup. Short version: each player gets a whole A4
  # page split into two 148.5mm-tall halves by a horizontal fold line at
  # the vertical center (`.place-card-fold`, an absolutely-positioned
  # dashed rule at `top: 148.5mm` — it doesn't consume height, so the two
  # `.place-card-half` panels stack to exactly 297mm). The top half prints
  # the player's details upright, unrotated; the bottom half prints the
  # *same* details again but with `transform: rotate(180deg)`
  # (`.place-card-flip`).
  #
  # Folding: crease along that middle line and fold the two halves so the
  # printed face ends up on the OUTSIDE of both resulting flaps (i.e. fold
  # the blank reverse together, print side out) — the same direction a
  # free-standing tent/A-frame card always folds, never folding the ink
  # onto itself. Standing the card up this way puts the crease at the top
  # (the ridge) with the two flaps splaying down and outward, one facing
  # each side of the board.
  #
  # Why the bottom half needs the extra 180° rotation: the top flap keeps
  # its on-page orientation as it swings toward the reader facing it, so it
  # reads upright with no help needed. The bottom flap, on the other hand,
  # was printed further down the *same upright* page, but after the fold it
  # ends up facing the *opposite* direction (the far side of the board) —
  # and reaching that far side means it rotated through 180° around the
  # fold axis on the way there. Printing it pre-rotated 180° on the flat
  # page exactly cancels that in-flight rotation, so by the time it's
  # standing it reads upright to the reader on that far side too. Skipping
  # the CSS rotation (or rotating the wrong half) produces a card that's
  # only readable from one side — the "reads upside-down after folding"
  # failure mode this comment exists to prevent.
  @place_cards_css """
  @page { size: A4 portrait; margin: 0; }
  .place-card-page { position: relative; width: 210mm; height: 297mm;
                      page-break-after: always; overflow: hidden; }
  .place-card-page:last-child { page-break-after: auto; }
  .place-card-half { box-sizing: border-box; height: 148.5mm; width: 210mm; padding: 14mm 10mm;
                      display: flex; flex-direction: column; align-items: center;
                      justify-content: center; text-align: center; }
  .place-card-flip { transform: rotate(180deg); }
  .place-card-fold { position: absolute; left: 0; right: 0; top: 148.5mm; height: 0;
                      border-top: 1px dashed #999; }
  .place-card-fold::after { content: "fold here"; position: absolute; left: 50%; top: -7px;
                             transform: translateX(-50%); background: #fff; padding: 0 6px;
                             font-size: 8px; letter-spacing: .08em; text-transform: uppercase;
                             color: #999; }
  .place-card-logo { max-height: 22mm; max-width: 70mm; margin-bottom: 8mm; }
  .place-card-name { font-size: 30px; font-weight: 700; margin: 0 0 4px; }
  .place-card-title-line { font-size: 15px; color: #444; margin: 0 0 8px; }
  .place-card-meta { font-size: 14px; color: #333; margin: 2px 0 0; }
  .place-card-board { font-size: 20px; font-weight: 700; margin-top: 10mm; border: 2px solid #000;
                       padding: 4px 16px; display: inline-block; }
  """

  defp place_card_board_map(tournament, round_param) do
    rounds_paired = PairingsEngine.Standings.rounds_paired(tournament.id)
    number = parse_round(round_param) || rounds_paired

    case number > 0 && Tournaments.get_round(tournament.id, number) do
      false -> %{}
      nil -> %{}
      round -> board_map(round.pairings)
    end
  end

  defp board_map(pairings) do
    Enum.reduce(pairings, %{}, fn p, acc ->
      acc
      |> put_board(p.white_player_id, p.board)
      |> put_board(p.black_player_id, p.board)
    end)
  end

  defp put_board(map, nil, _board), do: map
  defp put_board(map, player_id, board), do: Map.put(map, player_id, board)

  # Sensible defaults: name is always shown (not a toggle); title, rating
  # and board are the fields an arbiter almost always wants on a seating
  # card, so they default on. Federation/club default off purely for space
  # — a tent card is small — but are one query param away.
  defp place_card_fields(params) do
    %{
      title: flag(params["title"], true),
      rating: flag(params["rating"], true),
      federation: flag(params["federation"], false),
      club: flag(params["club"], false),
      board: flag(params["board"], true)
    }
  end

  defp flag(nil, default), do: default
  defp flag(value, _default), do: value not in ["0", "false", "no"]

  defp place_card_logo_html(tournament) do
    case Tournaments.logo_data_uri(tournament) do
      nil -> ""
      uri -> "<img class=\"place-card-logo\" src=\"#{uri}\" alt=\"\" />"
    end
  end

  # `print_page/5`'s shared header, next to every print document's own
  # title/subtitle — place cards render their own bigger, centered logo via
  # `place_card_logo_html/1` above, but every other print document (pairing
  # list, standings, player list/cards, crosstable, result cards) went
  # through `print_page/5` and never showed the logo at all: uploading one
  # had no visible effect anywhere outside place cards. Same tournament
  # logo, just small and top-right so it doesn't crowd the title.
  defp header_logo_html(tournament) do
    case Tournaments.logo_data_uri(tournament) do
      nil -> ""
      uri -> "<img class=\"print-header-logo\" src=\"#{uri}\" alt=\"\" />"
    end
  end

  defp place_card_page(player, board_map, fields, logo_html) do
    "<div class=\"place-card-page\">" <>
      "<div class=\"place-card-half\">#{place_card_panel(player, board_map, fields, logo_html)}</div>" <>
      "<div class=\"place-card-fold\"></div>" <>
      "<div class=\"place-card-half place-card-flip\">#{place_card_panel(player, board_map, fields, logo_html)}</div>" <>
      "</div>"
  end

  defp place_card_panel(player, board_map, fields, logo_html) do
    title_html =
      if fields.title and player.title != "",
        do: "<p class=\"place-card-title-line\">#{esc(player.title)}</p>",
        else: ""

    meta =
      [
        if(fields.rating and player_rating(player) > 0, do: "#{player_rating(player)}"),
        if(fields.federation and player.federation != "", do: esc(player.federation)),
        if(fields.club and player.club != "", do: esc(player.club))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" &middot; ")

    board = fields.board && Map.get(board_map, player.id)
    board_html = if board, do: "<div class=\"place-card-board\">Board #{board}</div>", else: ""

    logo_html <>
      "<h2 class=\"place-card-name\">#{esc(player.name)}</h2>" <>
      title_html <>
      "<p class=\"place-card-meta\">#{meta}</p>" <>
      board_html
  end

  # The optional columns `player_list/2` can show, in the fixed display
  # order the printed table always uses (Title before Name, everything
  # else after). Every one of these is also a column on the Players
  # grid's own Display panel, under the SAME key
  # (`PairingsEngineWeb.PlayersLive.all_columns/1`) — the `?cols=` query
  # param `players_live.ex` builds is literally `@visible` filtered down
  # to this list, so the print shows exactly what the arbiter had checked
  # on screen when they clicked Print.
  # Every column is `{key, header_label, numeric?}` — `key` matching the
  # grid key one-for-one so `?cols=` is literally the arbiter's on-screen
  # `@visible` list, and this order being the order the grid itself shows
  # them in. `player_list_value/2` below renders each key's cell.
  #
  # Only PLAYER-DATA columns live here. The grid's score-derived columns
  # (Cl, Pts, Ga, Perf, We, W-We and the tiebreaks) need a full standings
  # computation and a chosen round to mean anything, which is exactly
  # what "Print standings" already is — printing them on a registration
  # list would be a second, subtly-different standings table.
  @player_list_columns [
    {:pr, "Pr.", false},
    {:aff, "Aff.", false},
    {:paid, "Paid", false},
    {:nr, "Nr", true},
    {:cat, "Cat", false},
    {:title, "Title", false},
    {:birth_year, "Birth", true},
    {:sex, "Sex", false},
    {:federation, "Fed", false},
    {:national_id, "Id Nat", true},
    {:fide_id, "Id FIDE", true},
    {:national_rating, "Nat.", true},
    {:fide_rating, "FIDE", true},
    {:elo_used, "Elo used", true},
    {:club, "Club", false},
    {:status, "Status", false},
    {:fixed_board, "Table", true}
  ]

  # The set a bare/bookmarked link (or the crosstable's own link to this
  # action) gets — what the printed list always showed before it became
  # configurable, so an existing bookmark prints exactly as it used to.
  @player_list_default_columns [:title, :fide_rating, :national_rating, :federation, :club]

  def player_list(conn, %{"id" => id} = params) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)
    players = Tournaments.list_players(tournament.id)
    cols = player_list_columns(params["cols"])
    # Same "round about to be paired" the Players grid uses to decide
    # whether a Pr. cell's A(1,2,3) is upper- or lower-case — see
    # `player_list_value(:pr, ...)` below and `PlayersLive.build_grid/2`.
    current_round = PairingsEngine.Standings.rounds_paired(tournament.id) + 1

    rows =
      players
      |> Enum.with_index(1)
      |> Enum.map_join("", &player_list_row(&1, cols, current_round))

    body =
      tournament_info_html(tournament) <>
        "<table><thead><tr>#{player_list_header(cols)}</tr></thead><tbody>#{rows}</tbody></table>"

    print_page(conn, tournament, tournament.name, "Registered players (#{length(players)})", body)
  end

  defp player_list_columns(nil), do: selected_player_columns(@player_list_default_columns)

  defp player_list_columns(csv) do
    requested =
      csv
      |> String.split(",", trim: true)
      |> Enum.flat_map(fn key ->
        try do
          [String.to_existing_atom(key)]
        rescue
          ArgumentError -> []
        end
      end)
      |> MapSet.new()

    Enum.filter(@player_list_columns, fn {key, _label, _num?} ->
      MapSet.member?(requested, key)
    end)
  end

  defp selected_player_columns(keys) do
    Enum.filter(@player_list_columns, fn {key, _label, _num?} -> key in keys end)
  end

  # Name is never optional — it's the one column a player list can't be
  # without — and Title, when shown, reads better in front of it.
  defp player_list_header(cols) do
    {before_name, after_name} = split_around_name(cols)

    ths = fn columns ->
      Enum.map_join(columns, "", fn {_key, label, num?} ->
        ~s(<th#{num_class(num?)}>#{esc(label)}</th>)
      end)
    end

    ~s(<th class="num">#</th>) <> ths.(before_name) <> "<th>Name</th>" <> ths.(after_name)
  end

  defp player_list_row({p, i}, cols, current_round) do
    {before_name, after_name} = split_around_name(cols)

    tds = fn columns ->
      Enum.map_join(columns, "", fn {key, _label, num?} ->
        ~s(<td#{num_class(num?)}>#{player_list_value(key, p, current_round)}</td>)
      end)
    end

    ~s(<tr><td class="num">#{i}</td>) <>
      tds.(before_name) <>
      "<td><strong>#{esc(p.name)}</strong></td>" <> tds.(after_name) <> "</tr>"
  end

  defp split_around_name(cols) do
    Enum.split_with(cols, fn {key, _label, _num?} -> key == :title end)
  end

  defp num_class(true), do: ~s( class="num")
  defp num_class(false), do: ""

  defp player_list_value(:aff, p, _current_round), do: if(p.affiliated, do: "", else: "N")
  defp player_list_value(:nr, p, _current_round), do: blank_zero(p.pairing_number)
  defp player_list_value(:cat, p, _current_round), do: esc(p.category)
  defp player_list_value(:title, p, _current_round), do: esc(p.title)
  defp player_list_value(:birth_year, p, _current_round), do: blank_zero(p.birth_year)
  defp player_list_value(:sex, p, _current_round), do: esc(p.sex)
  defp player_list_value(:federation, p, _current_round), do: esc(p.federation)
  defp player_list_value(:national_id, p, _current_round), do: esc(p.national_id)
  defp player_list_value(:fide_id, p, _current_round), do: esc(p.fide_id)
  defp player_list_value(:national_rating, p, _current_round), do: blank_zero(p.national_rating)
  defp player_list_value(:fide_rating, p, _current_round), do: blank_zero(p.fide_rating)
  defp player_list_value(:elo_used, p, _current_round), do: blank_zero(Player.rating(p))
  defp player_list_value(:club, p, _current_round), do: esc(p.club)
  defp player_list_value(:status, p, _current_round), do: esc(p.status)
  defp player_list_value(:fixed_board, p, _current_round), do: blank_zero(p.fixed_board)

  defp player_list_value(:paid, p, _current_round) do
    case p.paid do
      "paid" -> "P"
      "nopaid" -> "N"
      "gratis" -> "G"
      _ -> ""
    end
  end

  # SWAR's presence notation, same rules — and the same capital/lowercase
  # A distinction — as the Players grid's own "Pr." cell
  # (`PlayersLive.cell(entry, "pr")`): capital when one of the listed
  # rounds IS the round about to be paired, lowercase otherwise.
  defp player_list_value(:pr, p, current_round) do
    rounds = to_string(p.absent_rounds)

    cond do
      p.forfeit ->
        "F"

      p.absent ->
        "A"

      rounds == "" ->
        ""

      true ->
        absent_now? = to_string(current_round) in String.split(rounds, ",")
        if(absent_now?, do: "A", else: "a") <> "(" <> esc(rounds) <> ")"
    end
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

    print_page(
      conn,
      tournament,
      tournament.name,
      "Player cards",
      tournament_info_html(tournament) <> cards
    )
  end

  @doc """
  `GET /t/:id/print/placecards` — one tent card ("chevalet") per player, for
  standing on the table at their seat. See `docs/printing.md` "Place cards"
  for the fold geometry and field-toggle query params
  (`?title=`/`?rating=`/`?federation=`/`?club=`/`?board=`, each `0`/`1`;
  name is always shown). Not round-scoped by a 404 the way pairings/results
  are — `?round=n` (default: latest paired round) only controls whether a
  board number is available to show; with no paired round at all, cards
  simply render without one.
  """
  def place_cards(conn, %{"id" => id} = params) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)
    players = Tournaments.list_players(tournament.id)
    board_map = place_card_board_map(tournament, params["round"])
    fields = place_card_fields(params)
    logo_html = place_card_logo_html(tournament)

    cards =
      Enum.map_join(players, "", &place_card_page(&1, board_map, fields, logo_html))

    print_page(
      conn,
      tournament,
      tournament.name,
      "Place cards",
      tournament_info_html(tournament) <> cards,
      @place_cards_css
    )
  end

  def pairing_list(conn, %{"id" => id} = params) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)
    number = parse_round(params["round"]) || 1
    round = Tournaments.get_round(tournament.id, number)

    if round == nil do
      send_resp(conn, 404, "Round #{number} has not been paired yet")
    else
      rows =
        round.pairings
        |> PairingDisplay.with_display_boards()
        |> Enum.map_join("", fn %{pairing: p, board: board} ->
          "<tr><td class=\"num\">#{board}</td>" <>
            "<td><strong>#{esc(p.white_player && p.white_player.name)}</strong></td>" <>
            "<td class=\"num\">#{p.white_player && blank_zero(player_rating(p.white_player))}</td>" <>
            "<td style=\"text-align:center\">#{esc(display_result(p.result))}</td>" <>
            "<td><strong>#{esc((p.black_player && p.black_player.name) || "— bye —")}</strong></td>" <>
            "<td class=\"num\">#{p.black_player && blank_zero(player_rating(p.black_player))}</td></tr>"
        end)

      body =
        tournament_info_html(tournament) <>
          "<table><thead><tr><th class=\"num\">Board</th><th>White</th><th class=\"num\">Elo</th>" <>
          "<th style=\"text-align:center\">Result</th><th>Black</th><th class=\"num\">Elo</th></tr></thead>" <>
          "<tbody>#{rows}</tbody></table>" <>
          absentees_section(tournament, number, params["absentees"])

      print_page(conn, tournament, tournament.name, "Pairings — round #{number}", body)
    end
  end

  @doc """
  GET /t/:id/print/pairings-alpha?round=N — the "where do I sit" list: every
  paired player for the round, sorted by name, with their board, colour and
  opponent. One row per player (both sides of every board), so an arriving
  player can find themselves alphabetically.
  """
  def pairing_alpha(conn, %{"id" => id} = params) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)
    number = parse_round(params["round"]) || 1
    round = Tournaments.get_round(tournament.id, number)

    if round == nil do
      send_resp(conn, 404, "Round #{number} has not been paired yet")
    else
      # Alphabetical order is the whole point of this document, so unlike
      # pairing_list/2 above, fixed-table boards aren't moved — just
      # relabelled (board_labels/1, not with_display_boards/1) so a
      # fixed-table player still finds their real table number here, not
      # the ordinary board they'd have gotten without one.
      board_by_pairing_id =
        round.pairings |> PairingDisplay.board_labels() |> Map.new(&{&1.pairing.id, &1.board})

      entries =
        round.pairings
        |> Enum.flat_map(fn p ->
          board = Map.fetch!(board_by_pairing_id, p.id)

          if p.black_player == nil do
            [
              %{
                name: p.white_player && p.white_player.name,
                board: board,
                colour: "—",
                opp: "bye"
              }
            ]
          else
            [
              %{
                name: p.white_player.name,
                board: board,
                colour: "White",
                opp: p.black_player.name
              },
              %{
                name: p.black_player.name,
                board: board,
                colour: "Black",
                opp: p.white_player.name
              }
            ]
          end
        end)
        |> Enum.reject(&(&1.name in [nil, ""]))
        |> Enum.sort_by(&String.downcase(&1.name))

      rows =
        Enum.map_join(entries, "", fn e ->
          "<tr><td><strong>#{esc(e.name)}</strong></td>" <>
            "<td class=\"num\">#{e.board}</td>" <>
            "<td style=\"text-align:center\">#{esc(e.colour)}</td>" <>
            "<td>#{esc(e.opp)}</td></tr>"
        end)

      body =
        tournament_info_html(tournament) <>
          "<table><thead><tr><th>Player</th><th class=\"num\">Board</th>" <>
          "<th style=\"text-align:center\">Colour</th><th>Opponent</th></tr></thead>" <>
          "<tbody>#{rows}</tbody></table>"

      print_page(
        conn,
        tournament,
        tournament.name,
        "Alphabetical pairing list — round #{number}",
        body
      )
    end
  end

  # `?absentees=1` — off by default per the arbiter's explicit request
  # ("the absents can be below, don't print them per default, add a
  # toggle somewhere"): a byes-table row (`"requested-half"`/
  # `"requested-zero"`/`"absent"` — SWAR-imported or a live round-specific
  # absence) is DIFFERENT from a pairing-allocated bye (a real `Pairing`
  # row with `black_player_id: nil, result: "bye"`, already rendered as an
  # ordinary board row above, unaffected by this toggle). Positioned BELOW
  # the main pairing table, never interleaved — mirrors the section
  # PairingsLive/LiveRoundLive/PublicPairingsLive already render (see
  # `Tournaments.list_byes_for_round/2` and `Standings.bye_points/2`, the
  # shared query/scoring pattern reused here).
  defp absentees_section(_tournament, _number, absentees) when absentees not in ["1", "true"],
    do: ""

  defp absentees_section(tournament, number, _absentees) do
    byes = Tournaments.list_byes_for_round(tournament.id, number)

    case byes do
      [] ->
        ""

      byes ->
        rows =
          Enum.map_join(byes, "", fn bye ->
            points = PairingsEngine.Standings.bye_points_for_row(bye, tournament)

            "<tr><td>#{esc(bye.player.name)}</td>" <>
              "<td style=\"text-align:center\">#{esc(bye_type_label(bye.type))} (#{points} pt)</td></tr>"
          end)

        "<h2 style=\"margin-top:24px\">Absentees</h2>" <>
          "<table><thead><tr><th>Player</th><th style=\"text-align:center\">Bye</th></tr></thead>" <>
          "<tbody>#{rows}</tbody></table>"
    end
  end

  # Same labels PairingsEngineWeb.PairingsLive uses for a byes-table row's
  # `type` — distinct from the "bye" badge shown for a pairing-allocated
  # bye (a real Pairing row), since these never appear in round.pairings.
  defp bye_type_label("requested-half"), do: "requested half-point bye"
  defp bye_type_label("requested-zero"), do: "requested zero-point bye"
  defp bye_type_label("absent"), do: "absent"
  defp bye_type_label(other), do: other

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

        # Manual ranking (SWAR parity #23) only ever applies to the current
        # standings (`requested_round == nil`) — a `?round=n` print is a
        # snapshot of standings *as they honestly stood right after round
        # n* (see the moduledoc), and today's hand-set arbiter order has no
        # meaning applied retroactively to a past round's numbers. Not
        # offered for Keizer either — see docs/manual-standings.md.
        entries =
          if not keizer? and requested_round == nil do
            PairingsEngine.Standings.apply_manual_ranking(entries, tournament)
          else
            entries
          end

        label = requested_round || rounds_paired

        manual_banner =
          if not keizer? and requested_round == nil and tournament.manual_ranking do
            manual_ranking_banner(tournament, entries)
          else
            ""
          end

        print_page(
          conn,
          tournament,
          tournament.name,
          "Standings after round #{label}",
          tournament_info_html(tournament) <>
            manual_banner <> standings_body(entries, tournament, keizer?)
        )
    end
  end

  # Loud, printed banner for the manual-ranking override (SWAR parity #23
  # requirement 3) — a silent override on a document an arbiter might post
  # on the wall or hand to a federation is exactly the "indistinguishable
  # from a tiebreak bug" scenario the feature exists to avoid.
  defp manual_ranking_banner(tournament, entries) do
    stale? = PairingsEngine.Standings.manual_ranking_stale?(tournament)
    incomplete? = PairingsEngine.Standings.manual_ranking_incomplete?(entries)

    stale_note =
      if stale?,
        do:
          " <strong>A result changed since this order was last set — it may no longer match the real standings.</strong>",
        else: ""

    incomplete_note =
      if incomplete?,
        do: " A player was added after this was turned on and has not been placed yet.",
        else: ""

    "<div style=\"border: 2px solid #000; padding: 8px 12px; margin-bottom: 14px; font-size: 12.5px;\">" <>
      "<strong>MANUAL RANKING IS ON.</strong> The rank column below is the arbiter's hand-set order, " <>
      "not the computed tiebreak order.#{incomplete_note}#{stale_note}</div>"
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
        tournament,
        tournament.name,
        "Result cards — round #{number}",
        tournament_info_html(tournament) <> cards,
        @result_cards_css
      )
    end
  end

  @doc """
  GET /t/:id/print/scoresheets?round=N — one full-page score sheet per board:
  header, both players (name / rating / federation), an 80-move grid
  (two 40-move columns of White/Black) and a result + signature footer.
  """
  def score_sheets(conn, %{"id" => id} = params) do
    tournament = Tournaments.get_authorized_tournament!(conn.assigns.current_scope, id)
    rounds_paired = PairingsEngine.Standings.rounds_paired(tournament.id)
    number = parse_round(params["round"]) || max(rounds_paired, 1)
    round = Tournaments.get_round(tournament.id, number)

    if round == nil do
      send_resp(conn, 404, "Round #{number} has not been paired yet")
    else
      sheets =
        round.pairings
        |> Enum.reject(&(&1.black_player_id == nil))
        |> Enum.sort_by(& &1.board)
        |> Enum.map_join("", &score_sheet(&1, tournament, number))

      print_page(
        conn,
        tournament,
        tournament.name,
        "Score sheets — round #{number}",
        sheets,
        @score_sheet_css
      )
    end
  end

  defp score_sheet(pairing, tournament, round_number) do
    white = pairing.white_player
    black = pairing.black_player

    "<div class=\"score-sheet\">" <>
      "<div class=\"ss-head\"><strong>#{esc(tournament.name)}</strong>" <>
      "<span>Round #{round_number} &middot; Board #{pairing.board}#{fixed_board_note(pairing)}</span></div>" <>
      "<div class=\"ss-players\">" <>
      "<div class=\"ss-player\"><span class=\"ss-who\">White</span><strong>#{esc(result_card_name(white))}</strong> " <>
      "<span class=\"ss-sub\">#{result_card_sub(white)}</span></div>" <>
      "<div class=\"ss-player\"><span class=\"ss-who\">Black</span><strong>#{esc(result_card_name(black))}</strong> " <>
      "<span class=\"ss-sub\">#{result_card_sub(black)}</span></div>" <>
      "</div>" <>
      "<div class=\"ss-grid\">#{ss_move_column(1, 40)}#{ss_move_column(41, 80)}</div>" <>
      "<div class=\"ss-footer\"><span class=\"ss-result\">Result: &nbsp; 1&ndash;0 &nbsp;&nbsp; &frac12;&ndash;&frac12; &nbsp;&nbsp; 0&ndash;1</span>" <>
      "<span class=\"ss-sig\">White <i></i> &nbsp; Black <i></i></span></div>" <>
      "</div>"
  end

  defp ss_move_column(from, to) do
    rows =
      for n <- from..to, into: "" do
        "<tr><td class=\"ss-n\">#{n}</td><td></td><td></td></tr>"
      end

    "<table class=\"ss-moves\"><thead><tr><th></th><th>White</th><th>Black</th></tr></thead>" <>
      "<tbody>#{rows}</tbody></table>"
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
      tournament_info_html(tournament) <>
        "<div class=\"crosstable-wrap\"><table class=\"crosstable\"><thead><tr><th class=\"num\">Rank</th>" <>
        "<th>Name</th><th class=\"num\">Elo</th>#{round_headers}<th class=\"num\">Pts</th>#{tb_headers}" <>
        "</tr></thead><tbody>#{rows}</tbody></table></div>"

    print_page(conn, tournament, tournament.name, "Cross table", body, @crosstable_css)
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

    col_headers =
      Enum.map_join(players, "", &"<th class=\"num\">#{&1.player.pairing_number}</th>")

    rows =
      Enum.map_join(players, "", fn row_entry ->
        cells = Enum.map_join(players, "", &rr_crosstable_cell(row_entry, &1, tournament))

        "<tr><td class=\"num\">#{row_entry.player.pairing_number}</td>" <>
          "<td><strong>#{esc(row_entry.player.name)}</strong></td>#{cells}" <>
          "<td class=\"num\"><strong>#{row_entry.points}</strong></td>" <>
          "<td class=\"num\">#{row_entry.rank}</td></tr>"
      end)

    body =
      tournament_info_html(tournament) <>
        "<div class=\"crosstable-wrap\"><table class=\"crosstable rr-crosstable\"><thead><tr><th class=\"num\">#</th>" <>
        "<th>Name</th>#{col_headers}<th class=\"num\">Pts</th><th class=\"num\">Rank</th></tr></thead>" <>
        "<tbody>#{rows}</tbody></table></div>"

    print_page(conn, tournament, tournament.name, "Cross table", body, @rr_crosstable_css)
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

  defp result_card_name(player),
    do: "#{if player.title != "", do: "#{player.title} "}#{player.name}"

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

  # A `?round=` that isn't a positive integer is treated as "no round given"
  # (the caller falls back to the default), the same forgiving way `parse_limit`
  # below handles junk — `String.to_integer/1` here turned `?round=abc` into a
  # 500 instead.
  defp parse_round(value) do
    case value && Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

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
  defp display_result("1/2-0"), do: "½-0"
  defp display_result("0-1/2"), do: "0-½"
  defp display_result("bye"), do: "bye"
  defp display_result(result), do: result

  # The credit line on every printed document, mirroring
  # `PairingsEngineWeb.SettingsAboutLive`'s own "About" tab wording (same
  # engine name via `Tournament.pairing_system_label/1`) — one source of
  # truth for what gets said, shown in the two places an arbiter is most
  # likely to actually read it: on paper, and where the app explains
  # itself.
  defp print_footer(tournament) do
    engine = Tournament.pairing_system_label(tournament.pairing_system)

    ~s(<p class="pf-credit">Paired by OpenPairings using #{esc(engine)} &middot; ) <>
      ~s(many thanks to Tom Wuyts for his valuable feedback.</p>)
  end

  defp print_page(conn, tournament, title, subtitle, body, extra_css \\ "") do
    # These pages are assembled here rather than through the root layout, so
    # the auto-print trigger needs the response's CSP nonce spelled out (see
    # PairingsEngineWeb.CSP); without it the browser refuses to run it and the
    # print dialog never opens.
    nonce = esc(conn.assigns[:csp_nonce])

    html = """
    <!doctype html><html><head><meta charset="utf-8"><title>#{esc(title)}</title>
    <style>#{@print_css}</style><style>#{extra_css}</style></head><body>
    <div class="print-header">
    <div class="print-header-title"><h1>#{esc(title)}</h1><p class="sub">#{esc(subtitle)}</p></div>
    #{header_logo_html(tournament)}
    </div>#{body}
    #{print_footer(tournament)}
    <script nonce="#{nonce}">window.onload = () => window.print();</script></body></html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  defp esc(nil), do: ""
  defp esc(text), do: text |> html_escape() |> safe_to_string()

  # Compact tournament-identity block shown near the top of every print
  # document, right below the `<h1>` name / subtitle `print_page/5` already
  # renders: federation, dates, chief arbiter, rate of play, and the FIDE
  # tournament ID (only shown once the tournament is flagged
  # FIDE-homologated — an unset/inapplicable ID is simply omitted, same as
  # every other blank field here). Reject-and-join so a tournament missing
  # some of this (very possible pre-Settings-completion) just shows less,
  # never an empty label or a stray separator.
  defp tournament_info_html(tournament) do
    items =
      [
        if(tournament.federation != "", do: "Federation: #{esc(tournament.federation)}"),
        tournament_dates_item(tournament),
        round_dates_item(tournament.round_dates),
        if(tournament.chief_arbiter != "", do: "Chief arbiter: #{esc(tournament.chief_arbiter)}"),
        if(tournament.deputy_arbiter != "",
          do: "Deputy arbiter: #{esc(tournament.deputy_arbiter)}"
        ),
        if(tournament.rate_of_play != "", do: "Rate of play: #{esc(tournament.rate_of_play)}"),
        if(tournament.fide_homologated and tournament.fide_tournament_id != "",
          do: "FIDE ID: #{esc(tournament.fide_tournament_id)}"
        )
      ]
      |> Enum.reject(&is_nil/1)

    case items do
      [] -> ""
      items -> "<p class=\"tourney-info\">#{Enum.map_join(items, "", &"<span>#{&1}</span>")}</p>"
    end
  end

  defp tournament_dates_item(%{start_date: start_date, end_date: end_date}) do
    cond do
      start_date not in [nil, ""] and end_date not in [nil, ""] and end_date != start_date ->
        "Dates: #{esc(start_date)} – #{esc(end_date)}"

      start_date not in [nil, ""] ->
        "Dates: #{esc(start_date)}"

      true ->
        nil
    end
  end

  # `round_dates` (ISO per-round dates, index = round - 1) is a distinct
  # concept from `start_date`/`end_date` above (arbitrary free-text festival
  # dates) — a tournament can set either, both, or neither, so this is a
  # separate item rather than a fallback. "Round dates" (not "Dates", the
  # label `tournament_dates_item/1` already uses above) to keep the two
  # unambiguous when both are present. Same collapsing logic as
  # `PairingsEngineWeb.Components.PublicTournamentMeta`'s round-dates line
  # (single date vs first–last range), duplicated here rather than shared
  # since this module builds raw HTML strings, not HEEx.
  defp round_dates_item(nil), do: nil
  defp round_dates_item([]), do: nil

  defp round_dates_item(dates) do
    case Enum.reject(dates, &(&1 in [nil, ""])) do
      [] -> nil
      [single] -> "Round date: #{esc(single)}"
      real -> "Round dates: #{esc(List.first(real))} – #{esc(List.last(real))}"
    end
  end

  defp blank_zero(0), do: ""
  defp blank_zero(n), do: to_string(n)
end
