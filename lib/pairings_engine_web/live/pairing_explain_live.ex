defmodule PairingsEngineWeb.PairingExplainLive do
  @moduledoc """
  "Why were these players paired this way?" - a live, visual explanation of a
  single round's pairings, computed fresh from current data by
  `PairingsEngine.PairingRationale` (the same analysis behind the audit
  trail's `"pairing.round_paired"` entry).

  For each board it shows both players' pre-round score, starting rank and
  colour (with FIDE due-colour agreement), flags floaters (a pairing that
  crosses score brackets - someone "paired up" or "paired down"), confirms no
  rematch, and names the pairing-allocated bye recipient. Round-robin shows
  the deterministic Berger-schedule slot; Keizer shows ladder values.

  Access control matches every other tournament page
  (`Tournaments.get_authorized_tournament!/2`).
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{PairingRationale, Tournaments}
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.Player
  alias PairingsEngine.Tournaments.Tournament
  alias PairingsEngineWeb.AuditLive

  @impl true
  def mount(%{"id" => id, "round" => round}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)
    round_number = String.to_integer(round)
    rationale = PairingRationale.for_round(tournament, round_number)
    paired_rounds = Engine.paired_rounds_count(tournament.id)

    # Cross-round trails for the pinned-popover history strip + sparkline -
    # precomputed once here and rendered hidden into every dot's popover, so
    # pinning stays purely client-side (no LiveView roundtrip). Empty for
    # round 1 (no history), which suppresses the trail chrome entirely.
    trails = PairingRationale.player_trails(tournament, round_number)

    {:ok,
     assign(socket,
       tournament: tournament,
       round_number: round_number,
       rationale: rationale,
       bracket: bracket_layout(rationale),
       trails: trails,
       ladder_max: ladder_max(rationale),
       paired_rounds: paired_rounds,
       anomalies: anomaly_index(rationale),
       page_title: "#{tournament.name} · Pairing rationale - Round #{round_number}"
     )}
  end

  # Top-of-page index of the genuine per-board anomalies - rematch outside
  # match format, a repeat pairing-allocated (engine-assigned) bye, and the
  # softer "already had a bye" note - flattened once here so the summary
  # panel and its per-item anchor links share one source of truth with the
  # inline per-board copy still rendered on each card. `had_prior_pairing_bye`
  # implies `had_prior_bye` (it's the stricter subset - see
  # `PairingRationale.players_with_prior_bye/2`), so a board only ever
  # contributes one entry, not two. Empty for a clean round or an unpaired
  # one, which suppresses the panel entirely (see its `:if` in the template).
  defp anomaly_index(nil), do: []

  defp anomaly_index(%{boards: boards}) do
    Enum.flat_map(boards, fn b ->
      cond do
        not b.is_bye and b.rematch_anomaly ->
          [
            %{
              board: b.board,
              text:
                "Board #{b.board} - #{b.white.player.name} and #{b.black.player.name} " <>
                  "already met in an earlier round"
            }
          ]

        (b.is_bye and b[:bye_detail]) && b.bye_detail.had_prior_pairing_bye ->
          [
            %{
              board: b.board,
              text:
                "Board #{b.board} - #{b.bye_detail.player.name} has now had two engine-assigned byes"
            }
          ]

        (b.is_bye and b[:bye_detail]) && b.bye_detail.had_prior_bye ->
          [
            %{
              board: b.board,
              text: "Board #{b.board} - #{b.bye_detail.player.name} already had a bye earlier"
            }
          ]

        true ->
          []
      end
    end)
  end

  ## ---------- display helpers ----------

  defp player_label(nil), do: "-"

  defp player_label(%Player{} = p) do
    rating = Player.rating(p)

    "#{if p.title not in [nil, ""], do: "#{p.title} "}#{p.name}#{if rating > 0, do: " (#{rating})", else: ""}"
  end

  defp score_str(nil), do: "0"
  defp score_str(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 1)
  defp score_str(n), do: to_string(n)

  # A vacated seat's player name in the "Pairing numbers" table - kept as a
  # named helper (not an inline if/else) so the call site stays short enough
  # for `mix format` to leave it on one line; a formatter-inserted line break
  # between the `<span>` and this text changes the rendered whitespace,
  # which broke an exact-match test once already.
  defp seat_name(nil), do: "- vacant -"
  defp seat_name(side), do: side.player.name

  defp colour_word(:w), do: "White"
  defp colour_word(:b), do: "Black"
  defp colour_word(_), do: "-"

  defp float_note(%{floater: false}), do: nil

  defp float_note(%{white: w, black: b}) when not is_nil(b) do
    {high, low} = if w.score >= b.score, do: {w, b}, else: {b, w}

    "Floater - #{high.player.name} (#{score_str(high.score)}) paired down against " <>
      "#{low.player.name} (#{score_str(low.score)}), who paired up."
  end

  defp float_note(_), do: nil

  defp system_label("round_robin", _tournament), do: "Round robin (Berger schedule)"
  defp system_label("keizer", _tournament), do: "Keizer ladder"

  # Named after the engine that actually paired it, not after whichever one
  # the app happened to ship with when this page was written.
  defp system_label(_swiss, tournament),
    do: "Swiss (FIDE Dutch / #{Tournament.engine_name(tournament)})"

  ## ---------- purely-presentational derivations ----------
  ## These reshape facts PairingRationale already computed into geometry /
  ## scaling for the visuals; they add no new facts and change no semantics.

  # Direction a given side floated, relative to its board's float pair, or nil.
  defp float_dir(%{floater: true, float_down: down}, %{player: %{id: id}}) when down == id,
    do: :down

  defp float_dir(%{floater: true, float_up: up}, %{player: %{id: id}}) when up == id, do: :up
  defp float_dir(_board, _side), do: nil

  # Colour matching the float direction (warm = down, cool = up, accent =
  # none) - CSS custom properties, not fixed hex, so this reads correctly
  # under every theme (SVG presentation attributes participate in the CSS
  # cascade, so `var()` resolves here same as in a stylesheet).
  defp float_colour(:down), do: "var(--warn)"
  defp float_colour(:up), do: "var(--info)"
  defp float_colour(_), do: "var(--accent)"

  # Largest ladder value on the board list, for scaling the Keizer bars.
  defp ladder_max(nil), do: nil

  defp ladder_max(%{boards: boards}) do
    boards
    |> Enum.flat_map(fn b -> [b.white, b.black] end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1.ladder_value)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      vals -> Enum.max(vals)
    end
  end

  defp ladder_pct(value, max) when is_number(value) and is_number(max) and max > 0,
    do: max(round(value / max * 100), 6)

  defp ladder_pct(_value, _max), do: 0

  # Geometry for the score-bracket map. One horizontal band per pre-round
  # score bracket (highest at top; labels live in a sticky HTML gutter so
  # they stay visible while the chart scrolls), one connector per playing
  # board between its two players' bracket bands - a floater's line visibly
  # slopes across bands - plus the bye recipient(s) as lone dashed dots in
  # their own band.
  #
  # Every DOT (one per player, one for a bye recipient) gets its own HTML
  # hover wrap centred exactly on it, showing only that player's detail -
  # hovering a specific circle shows that circle's player, not also
  # whoever they're paired against elsewhere on the chart. Each wrap
  # carries a server-computed popover flip direction so the pure-CSS
  # popover opens toward whichever side of the chart has room, instead of
  # clipping (the scroll container clips vertically too - `overflow-x:
  # auto` forces `overflow-y` to auto as well). Returns nil when there is
  # nothing to draw.
  @bracket_top 34
  @bracket_row_gap 56
  @bracket_col_gap 52
  @bracket_dx 15
  @bracket_pad_left 24
  # Wrap box extends this far beyond each dot centre (dot r=9 + ring halo).
  @bracket_reach 13
  # Vertical room a popover needs to open without clipping (est. max popover
  # height plus its 8px gap) - drives both the above/below flip and the
  # canvas growth that guarantees a below-opening popover has room while
  # it's open (see the reservation comment in bracket_layout/1). The
  # hover popover is short (@bracket_pop_room); a PINNED popover additionally
  # carries the cross-round trail strip + sparkline and is much taller
  # (@bracket_pin_pop_room, capped by the trail's own internal max-height +
  # overflow so this stays a fixed bound regardless of round count). Because
  # the pin re-uses the same server-computed flip direction as hover, the
  # flip itself must reserve the pinned room whenever a trail can appear
  # (round > 1) - otherwise a pinned popover on a near-top/near-bottom dot
  # would clip out of the scroll container.
  @bracket_pop_room 140
  # 310 (the old reservation) + 144 for .pe-trail-rounds' max-height growing
  # 96px -> 240px, + ~38px for the fairness stats row added above the
  # sparkline (up to two wrapped 16px lines plus its 6px margin) - that row
  # is new chrome the old 310 never covered. Rounded up to 500: over-
  # reserving only pads the canvas min-height a little, while under-
  # reserving clips a pinned popover out of the scroll container.
  @bracket_pin_pop_room 500

  defp bracket_layout(nil), do: nil
  defp bracket_layout(%{score_groups: []}), do: nil

  defp bracket_layout(%{boards: boards, score_groups: groups, round_number: round_number}) do
    pop_room = if round_number > 1, do: @bracket_pin_pop_room, else: @bracket_pop_room

    y_of =
      groups
      |> Enum.with_index()
      |> Map.new(fn {g, i} -> {g.score, @bracket_top + i * @bracket_row_gap} end)

    # Score-band index per score, threaded onto every dot so the legend/gutter
    # click-filter (see dot_facets/1) can highlight "everyone in this band"
    # without a new query - counts already come from score_groups below.
    band_idx_of =
      groups
      |> Enum.with_index()
      |> Map.new(fn {g, i} -> {g.score, i} end)

    bands =
      groups
      |> Enum.with_index()
      |> Enum.map(fn {g, i} ->
        %{
          score: g.score,
          count: g.count,
          odd: g.odd,
          y: @bracket_top + i * @bracket_row_gap,
          idx: i
        }
      end)

    # `is_bye` only means black's seat is empty (or `result == "bye"`) - it
    # says nothing about whether anyone is actually still seated. A board
    # can reach here with a seat vacated after pairing (either colour on an
    # ordinary board, or the bye recipient themselves on a bye board - see
    # `PairingRationale.board_context/7`/`annotate_bye/3`'s own guards for
    # the same underlying gap). There's no player to plot a dot for on an
    # empty seat, so these are excluded from the score-bracket graph
    # entirely - they still appear in the plain "Board by board" list below
    # (with a "seat vacant" note), just not on this chart.
    {playing, byes} =
      boards
      |> Enum.split_with(&(not &1.is_bye))
      |> then(fn {playing, byes} ->
        {Enum.filter(playing, &(&1.white && &1.black)), Enum.filter(byes, & &1.white)}
      end)

    columns = playing ++ byes
    width = @bracket_pad_left + length(columns) * @bracket_col_gap + 16
    height = @bracket_top + max(length(groups) - 1, 0) * @bracket_row_gap + 44

    links =
      playing
      |> Enum.with_index()
      |> Enum.map(fn {b, i} ->
        x = column_x(i)

        %{
          board: b.board,
          floater: b.floater,
          rematch: b.rematch,
          rematch_anomaly: b.rematch_anomaly,
          white: %{
            x: x - @bracket_dx,
            y: Map.fetch!(y_of, b.white.score),
            name: b.white.player.name,
            score: b.white.score,
            dir: float_dir(b, b.white)
          },
          black: %{
            x: x + @bracket_dx,
            y: Map.fetch!(y_of, b.black.score),
            name: b.black.player.name,
            score: b.black.score,
            dir: float_dir(b, b.black)
          }
        }
      end)

    # One hover wrap per DOT - two per playing board (white, black), one per
    # bye - each centred on that dot alone, carrying just that player's facts.
    # These same per-dot maps (via dot_wrap/2, which just adds wrap geometry
    # on top) also drive every SVG dot circle/halo/triangle below - one
    # source of truth for "what facets does this dot belong to" instead of
    # re-deriving colour/floater/rematch facts separately for the overlay
    # and the SVG.
    dots =
      playing
      |> Enum.with_index()
      |> Enum.flat_map(fn {b, i} ->
        x = column_x(i)

        [
          dot(
            b,
            b.white,
            :w,
            x - @bracket_dx,
            Map.fetch!(y_of, b.white.score),
            Map.fetch!(band_idx_of, b.white.score)
          ),
          dot(
            b,
            b.black,
            :b,
            x + @bracket_dx,
            Map.fetch!(y_of, b.black.score),
            Map.fetch!(band_idx_of, b.black.score)
          )
        ]
      end)

    bye_dot_entries =
      byes
      |> Enum.with_index(length(playing))
      |> Enum.map(fn {b, i} ->
        dot(
          b,
          b.white,
          :bye,
          column_x(i),
          Map.fetch!(y_of, b.white.score),
          Map.fetch!(band_idx_of, b.white.score)
        )
      end)

    all_dots = dots ++ bye_dot_entries
    wraps = Enum.map(all_dots, &dot_wrap(&1, width, height, pop_room))

    # A popover that opens downward must fit inside the scroll container's
    # vertical clip (`.pe-bracket-scroll` is `overflow-y: hidden` - see its
    # own comment for why that can't be `visible` or `clip`), so the canvas
    # has to be tall enough to hold one. NEITHER reservation is made up
    # front: both are custom properties the CSS applies only while a popover
    # is actually open.
    #
    # Reserving the pinned room permanently came first and padded a huge dead
    # band between the graph and the minimap strip (user-reported). Reserving
    # only the short HOVER room instead was better but not fixed: the flip
    # below deliberately tests against the PINNED room, so on any round past
    # the first essentially every dot opens downward, and the deepest one
    # then sits `@bracket_reach + @bracket_pop_room` above a canvas floor
    # that is only 44px below the lowest band - a permanent ~110px gap.
    # Whether the arithmetic happened to clear the graph's own height varied
    # with each round's bracket shape, which is why it read as intermittent.
    #
    # So the canvas rests at exactly the graph's height and grows only while
    # a wrap is hovered/focused (`--pe-hover-min`) or pinned
    # (`--pe-pinned-min`) - see the two `:has()` rules on
    # `.pe-bracket-canvas` in app.css. The popover covering whatever sits
    # under the chart while it's open is fine and preferred over a permanent
    # empty band; the flip (dot_wrap's pop_v) is untouched, so a pinned
    # popover still always has the side it reserved room on.
    deepest_below =
      wraps
      |> Enum.filter(&(&1.pop_v == "pe-pop-below"))
      |> Enum.map(& &1.y)
      |> Enum.max(fn -> 0 end)

    hover_min_height = max(deepest_below + @bracket_reach + @bracket_pop_room, height)
    pinned_min_height = max(deepest_below + @bracket_reach + pop_room, height)

    # One head-to-head entry per PLAYING board (both wraps present; byes have
    # no opponent) - drives the hidden `.pe-duo` panels under the chart,
    # opened by clicking a pinned player's exact opponent (see app.js).
    duos =
      wraps
      |> Enum.filter(&(&1.colour in [:w, :b]))
      |> Enum.group_by(& &1.board)
      |> Enum.flat_map(fn {board, pair} ->
        w = Enum.find(pair, &(&1.colour == :w))
        b = Enum.find(pair, &(&1.colour == :b))
        if w && b, do: [%{board: board, w: w, b: b}], else: []
      end)
      |> Enum.sort_by(& &1.board)

    axis =
      columns
      |> Enum.with_index()
      |> Enum.map(fn {b, i} ->
        %{x: column_x(i), label: if(b.is_bye, do: "bye", else: to_string(b.board))}
      end)

    %{
      bands: bands,
      links: links,
      wraps: wraps,
      axis: axis,
      width: width,
      height: height,
      hover_min_height: hover_min_height,
      pinned_min_height: pinned_min_height,
      duos: duos,
      has_bye: byes != [],
      has_rematch_anomaly: Enum.any?(playing, & &1.rematch_anomaly),
      has_match_rematch: Enum.any?(playing, &(&1.rematch and not &1.rematch_anomaly)),
      has_against_due: Enum.any?(all_dots, & &1.against_due)
    }
  end

  defp column_x(i), do: @bracket_pad_left + i * @bracket_col_gap + div(@bracket_col_gap, 2)

  # One dot's full popover content: which board, this player's side, and
  # (for a real pairing, not a bye) the shared board-level facts - floater
  # direction and rematch status apply to the specific side that floated /
  # to both sides of the same game respectively. Also carries every fact the
  # legend/gutter click-filter (task 1/2) and the colour-against-due halo
  # (task 3) need, all rolled into a single `facets` string (see
  # dot_facets/1) so the SVG and the CSS filter share one source of truth.
  defp dot(board, side, colour, x, y, band_idx) do
    floater = colour != :bye and board.floater
    rematch = if(colour == :bye, do: false, else: board.rematch)
    rematch_anomaly = if(colour == :bye, do: false, else: board.rematch_anomaly)
    # Deliberate rematches (round-robin / Swiss "match format") vs. flagged
    # anomalies are mutually exclusive by construction (rematch_anomaly is
    # only set when NOT match-format-expected - see PairingRationale).
    match_rematch = rematch and not rematch_anomaly
    # The only colour-history signal PairingRationale exposes is the boolean
    # colour_ok verdict (no numeric imbalance) - see pairing_rationale.ex's
    # `side/6` / `colour_matches_due?/2` - so this halo is binary, not scaled.
    # Byes are excluded like floater/rematch above, and for the same kind of
    # reason: a bye recipient's side is built as the board's WHITE side (see
    # PairingRationale's `board_context/7`), so `colour_ok` compares a
    # fictitious White against their real due colour. Without this guard a
    # player due Black would get a halo claiming they "received White" on a
    # round they didn't play a game at all.
    against_due = colour != :bye and side.colour_due != nil and not side.colour_ok

    base = %{
      board: board.board,
      side: side,
      colour: colour,
      x: x,
      y: y,
      dir: if(colour == :bye, do: nil, else: float_dir(board, side)),
      rematch: rematch,
      rematch_anomaly: rematch_anomaly,
      floater: floater,
      match_rematch: match_rematch,
      against_due: against_due,
      band_idx: band_idx,
      bye_detail: Map.get(board, :bye_detail)
    }

    Map.put(base, :facets, dot_facets(base))
  end

  # Space-separated facet tokens for one dot - consumed both as the
  # `data-facets` attribute JS reads to decide what to dim (see the
  # delegated listener in assets/js/app.js) and, indirectly, as the set of
  # `data-filter` values the legend/gutter buttons can target. Keep this in
  # sync with link_facets/1 and the `data-filter` values in the template.
  defp dot_facets(d) do
    [
      colour_key(d.colour),
      (d.colour != :bye and not d.floater) && "within",
      d.floater && "float",
      d.rematch_anomaly && "anomaly",
      d.match_rematch && "rematch",
      d.dir == :down && "down",
      d.dir == :up && "up",
      d.against_due && "against-due",
      "band-#{d.band_idx}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  # Same idea as dot_facets/1 but for a board's connecting `<line>` - no
  # colour/direction/band facets (a link spans two dots that may disagree on
  # those), just its link-type classification.
  defp link_facets(l) do
    [
      not l.floater && "within",
      l.floater && "float",
      l.rematch_anomaly && "anomaly",
      (l.rematch and not l.rematch_anomaly) && "rematch"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  # <title>/popover-adjacent one-liner for a dot, including the
  # against-due-colour note when applicable (task 3).
  defp dot_title(%{colour: :bye} = w),
    do: "#{w.side.player.name} - bye, score #{score_str(w.side.score)}#{due_title_suffix(w)}"

  defp dot_title(w),
    do:
      "#{w.side.player.name} - #{colour_word(w.colour)}, score #{score_str(w.side.score)}#{due_title_suffix(w)}"

  defp due_title_suffix(%{against_due: true}), do: " - against due colour"
  defp due_title_suffix(_), do: ""

  # The HTML hover wrap for one dot: a small box centred on it (ring drawn
  # by CSS, always dead-centre since the box is sized 2*reach square around
  # the dot), plus flip classes choosing which way the popover opens.
  defp dot_wrap(d, width, height, pop_room) do
    pop_v =
      if d.y - @bracket_reach >= pop_room and
           d.y - @bracket_reach >= height - (d.y + @bracket_reach),
         do: "pe-pop-above",
         else: "pe-pop-below"

    # Threshold must be at least half the WIDEST popover that can appear on
    # a pinned dot (the pinned popover is 300px wide, centred on the dot via
    # `left: 50%; transform: translateX(-50%)`) plus a safety margin, or a
    # centred popover near the canvas edge overflows past x=0/width even
    # while "not flipped". Half of 300 is 150 - preserve the same ~25px
    # buffer the old 150 threshold had over the old 250px popover's
    # half-width of 125: 150 + 25 = 175.
    pop_h =
      cond do
        d.x < 175 -> "pe-pop-edge-left"
        d.x > width - 175 -> "pe-pop-edge-right"
        true -> nil
      end

    Map.merge(d, %{
      left: d.x - @bracket_reach,
      top: d.y - @bracket_reach,
      pop_v: pop_v,
      pop_h: pop_h,
      id: dot_id(d.board, d.colour),
      # This round's opponent's wrap id (nil for a bye) - rendered as
      # `data-opponent` so the delegated click listener in assets/js/app.js
      # can detect "the pinned player's exact opponent was clicked" and open
      # the board's head-to-head duo panel instead of re-pinning.
      opponent_dot_id: opponent_dot_id(d),
      aria: dot_aria(d)
    })
  end

  defp opponent_dot_id(%{colour: :w, board: board}), do: dot_id(board, :b)
  defp opponent_dot_id(%{colour: :b, board: board}), do: dot_id(board, :w)
  defp opponent_dot_id(_bye), do: nil

  # Display rating for a duo panel's side - FIDE first, national fallback
  # (Player.rating/1), nil when unrated so the tag is dropped entirely.
  defp duo_rating(wrap) do
    case PairingsEngine.Tournaments.Player.rating(wrap.side.player) do
      r when is_integer(r) and r > 0 -> r
      _ -> nil
    end
  end

  defp dot_aria(%{colour: :bye, side: side, board: board} = d),
    do: "Board #{board}, bye: #{side.player.name}" <> due_aria_suffix(d)

  defp dot_aria(%{colour: colour, side: side, board: board} = d),
    do: "Board #{board}, #{colour_word(colour)}: #{side.player.name}" <> due_aria_suffix(d)

  defp due_aria_suffix(%{against_due: true}), do: ", against due colour"
  defp due_aria_suffix(_), do: ""

  # Stable per-dot element id, shared by the map's own hover wrap (as its
  # `id`) and each board card's colour disc (as its `data-dot-target`) - a
  # delegated click listener in assets/js/app.js matches the two, toggles a
  # `.is-pinned` class on the wrap, and scrolls it into view, pinning its
  # ring/popover open until a different dot is pinned. See app.css for the
  # `.is-pinned` styling.
  defp dot_id(board, colour), do: "pe-dot-#{board}-#{colour_key(colour)}"

  defp colour_key(:w), do: "w"
  defp colour_key(:b), do: "b"
  defp colour_key(:bye), do: "bye"

  ## ---------- shared SVG fragments ----------
  ## Both the full interactive chart and the small overview minimap (task B)
  ## draw the same bands / links / dots over the same layout & viewBox - SVG
  ## scales for free. These components are the single source of that markup;
  ## the minimap passes interactive={false} to drop the hover/filter/halo/
  ## triangle/text chrome and keep just the overview shapes.

  attr :bands, :list, required: true
  attr :width, :integer, required: true

  defp bracket_bands(assigns) do
    ~H"""
    <g>
      <rect
        :for={band <- @bands}
        x="0"
        y={band.y - 22}
        width={@width}
        height="44"
        fill={if rem(band.idx, 2) == 0, do: "var(--surface)", else: "var(--surface-alt)"}
      />
    </g>
    """
  end

  attr :links, :list, required: true
  attr :interactive, :boolean, default: true

  defp bracket_links(assigns) do
    ~H"""
    <g>
      <line
        :for={l <- @links}
        x1={l.white.x}
        y1={l.white.y}
        x2={l.black.x}
        y2={l.black.y}
        class={["pe-link", @interactive && "pe-filterable"]}
        data-facets={@interactive && link_facets(l)}
        stroke={
          cond do
            l.rematch_anomaly -> "var(--danger)"
            l.floater -> "var(--warn)"
            l.rematch -> "var(--text-soft)"
            true -> "var(--border)"
          end
        }
        stroke-width={if l.rematch_anomaly, do: "3.5", else: "2.5"}
        stroke-dasharray={
          cond do
            l.floater and not l.rematch_anomaly -> "5 3"
            l.rematch and not l.rematch_anomaly -> "1.5 2.5"
            true -> "0"
          end
        }
        stroke-linecap="round"
      />
    </g>
    """
  end

  attr :wraps, :list, required: true
  attr :interactive, :boolean, default: true

  defp bracket_dots(assigns) do
    ~H"""
    <g :for={w <- @wraps}>
      <circle
        :if={w.colour != :bye}
        cx={w.x}
        cy={w.y}
        r="9"
        fill={if w.colour == :w, do: "var(--surface)", else: "var(--accent)"}
        stroke="var(--accent)"
        stroke-width="2"
        class={["pe-dot", @interactive && "pe-filterable"]}
        data-facets={@interactive && w.facets}
      >
        <title :if={@interactive}>{dot_title(w)}</title>
      </circle>
      <circle
        :if={w.colour == :bye}
        cx={w.x}
        cy={w.y}
        r="9"
        fill="var(--surface)"
        stroke="var(--accent)"
        stroke-width="2"
        stroke-dasharray="3 2.4"
        class={["pe-dot", @interactive && "pe-filterable"]}
        data-facets={@interactive && w.facets}
      >
        <title :if={@interactive}>{dot_title(w)}</title>
      </circle>
      <text
        :if={@interactive and w.colour == :bye}
        x={w.x}
        y={w.y + 3.5}
        font-size="9.5"
        font-weight="700"
        text-anchor="middle"
        fill="var(--accent)"
        class="pe-filterable"
        data-facets={w.facets}
      >
        B
      </text>
      <%!-- Colour-against-due halo (task 3): a second, unfilled ring -
            never drawn for players whose due colour was satisfied, so it
            only ever adds a warning, never noise. Interactive chart only. --%>
      <circle
        :if={@interactive and w.against_due}
        cx={w.x}
        cy={w.y}
        r="13"
        fill="none"
        stroke="var(--warn)"
        stroke-width="1.75"
        stroke-dasharray="2 2"
        class="pe-dot pe-dot-halo pe-filterable"
        data-facets={w.facets}
      >
        <title>
          Received {colour_word(w.colour)}; colour history says {colour_word(w.side.colour_due)} was due.
        </title>
      </circle>
      <%!-- Paired-up/-down marker: a bare coloured triangle glyph - an
            interim design wrapped it in a filled circle chip, and the user
            explicitly asked for the plain triangles back. --%>
      <text
        :if={@interactive and w.dir}
        x={w.x}
        y={w.y - 13}
        font-size="12"
        font-weight="700"
        text-anchor="middle"
        fill={float_colour(w.dir)}
        class="pe-tri pe-filterable"
        data-facets={w.facets}
      >
        {if w.dir == :down, do: "▼", else: "▲"}
      </text>
    </g>
    """
  end

  ## ---------- cross-round trail popover (task A) ----------
  ## Rendered hidden into every dot's popover; CSS reveals it only when the
  ## dot is PINNED (`.pe-board-wrap.is-pinned .pe-trail`), so casual hover
  ## scanning stays light. All data is precomputed server-side by
  ## PairingRationale.player_trails/2 - pinning never hits the server.

  attr :trail, :list, required: true
  attr :summary, :map, default: nil

  defp trail_popover(assigns) do
    assigns = assign(assigns, :spark, sparkline(assigns.trail))

    ~H"""
    <div class="pe-trail">
      <div class="pe-trail-title">Pairing fairness</div>
      <%!-- Summary digest (task 4d) - reuses the page's existing compact-stat
            visual language (.pe-stat/.pe-stat-n, see the page's summary strip
            above) rather than inventing new chrome, just a smaller variant
            for the popover's tighter width. Byes only renders when > 0 (no
            empty chrome for a player who's never had one). --%>
      <div :if={@summary} class="pe-trail-stats">
        <span class="pe-stat pe-stat-sm" title="Colour balance (real games)">
          <span class="pe-stat-n">{@summary.colour.w}W · {@summary.colour.b}B</span>
        </span>
        <span class="pe-stat pe-stat-sm" title="Rounds paired up vs paired down">
          <span class="pe-stat-n">{@summary.floats.up}▲ · {@summary.floats.down}▼</span>
        </span>
        <span class="pe-stat pe-stat-sm" title="Average rating of real opponents faced">
          <span class="pe-stat-n">{@summary.avg_opponent_rating || "-"}</span> avg opp
        </span>
        <span :if={@summary.byes > 0} class="pe-stat pe-stat-sm" title="Byes so far">
          <span class="pe-stat-n">{@summary.byes}</span> bye{if @summary.byes > 1, do: "s"}
        </span>
      </div>
      <svg
        :if={@spark}
        class="pe-trail-spark"
        width={@spark.w}
        height={@spark.h}
        viewBox={"0 0 #{@spark.w} #{@spark.h}"}
        aria-hidden="true"
      >
        <polyline
          points={@spark.line}
          fill="none"
          stroke="var(--accent)"
          stroke-width="1.5"
          stroke-linejoin="round"
          stroke-linecap="round"
        />
        <circle
          :for={pt <- @spark.dots}
          cx={pt.x}
          cy={pt.y}
          r={if pt.current, do: "2.6", else: "1.8"}
          fill={if pt.current, do: "var(--warn)", else: "var(--accent)"}
        />
      </svg>
      <%!-- The right-hand column is the running total AFTER each round, so
            the last row is deliberately one result ahead of the pre-round
            score on the pairing card behind this popover. Said out loud in a
            caption because the two numbers sitting a click apart otherwise
            read as a contradiction - especially on a bye, which already
            counts here the moment the round is paired. --%>
      <div class="pe-trail-rounds">
        <div :for={e <- @trail} class={["pe-trail-row", "pe-trail-#{e.outcome}"]}>
          <span class="pe-trail-rd">R{e.round}</span>
          <span class={["pe-trail-col", trail_col_class(e.colour)]}>{trail_col_label(e.colour)}</span>
          <span class="pe-trail-res">{trail_res_label(e)}</span>
          <span class="pe-trail-opp" title={e.opponent_name}>{trail_opp_label(e)}</span>
          <span class="pe-trail-sc" title="Score after this round">{score_str(e.score)}</span>
        </div>
      </div>
      <div class="pe-trail-note">Score column is the total after each round.</div>
    </div>
    """
  end

  defp trail_col_class("W"), do: "is-w"
  defp trail_col_class("B"), do: "is-b"
  defp trail_col_class("bye"), do: "is-bye"
  defp trail_col_class(_), do: "is-absent"

  defp trail_col_label("W"), do: "W"
  defp trail_col_label("B"), do: "B"
  defp trail_col_label("bye"), do: "-"
  defp trail_col_label(_), do: "·"

  defp trail_res_label(%{outcome: :pending}), do: "this round"
  defp trail_res_label(%{outcome: :absent}), do: "absent"
  defp trail_res_label(%{outcome: :bye}), do: "bye"
  defp trail_res_label(%{result: r}), do: r

  defp trail_opp_label(%{outcome: :bye}), do: "(bye)"
  defp trail_opp_label(%{outcome: :absent}), do: "-"
  defp trail_opp_label(%{opponent_name: nil}), do: "-"
  defp trail_opp_label(%{opponent_name: n, opponent_seed: s}), do: "#{n} ##{s}"

  # Tiny inline sparkline of the running score after each round. `nil` when
  # there aren't at least two points to draw a line between.
  defp sparkline(trail) do
    scores = Enum.map(trail, & &1.score)

    case scores do
      [_, _ | _] ->
        w = 226
        h = 32
        pad = 4
        {min_s, max_s} = Enum.min_max(scores)
        span = max(max_s - min_s, 1.0)
        n = length(scores)
        step = (w - 2 * pad) / (n - 1)

        dots =
          scores
          |> Enum.with_index()
          |> Enum.map(fn {s, i} ->
            x = pad + i * step
            y = pad + (1 - (s - min_s) / span) * (h - 2 * pad)
            %{x: Float.round(x, 1), y: Float.round(y, 1), current: i == n - 1}
          end)

        line = Enum.map_join(dots, " ", fn d -> "#{d.x},#{d.y}" end)
        %{w: w, h: h, line: line, dots: dots}

      _ ->
        nil
    end
  end

  # One player's side of a pairing card: colour disc, name, score/seed, the
  # FIDE due-colour verdict, any float direction, and (Keizer) a ladder bar.
  attr :side, :map, required: true
  attr :colour, :atom, required: true
  attr :board, :map, required: true
  attr :ladder_max, :any, default: nil

  defp pairing_side(assigns) do
    assigns =
      assigns
      |> assign(:dir, float_dir(assigns.board, assigns.side))
      |> assign(
        :dot_id,
        dot_id(assigns.board.board, if(assigns.board.is_bye, do: :bye, else: assigns.colour))
      )

    ~H"""
    <div class={["pe-side", @colour == :w && "pe-side-w", @colour == :b && "pe-side-b"]}>
      <button
        type="button"
        data-dot-target={@dot_id}
        class={["pe-disc", @colour == :w && "pe-disc-w", @colour == :b && "pe-disc-b"]}
        title={"Show #{@side.player.name} on the chart above"}
        aria-label={"Show #{@side.player.name} on the chart above"}
      ></button>
      <div class="pe-side-body">
        <div class="pe-name">{player_label(@side.player)}</div>
        <div class="pe-meta">
          <%!-- Spelled out rather than just "pre-round score": this is the
                score going INTO the round, which is what the pairing was
                computed from, while the trail popover one click away lists
                the score AFTER each round. They differ by the current
                round's result - most visibly for a bye, which scores the
                moment the round is paired, so a bye recipient's popover is
                already a point ahead of this number by design. --%>
          <span
            class="pe-score"
            title="Score going into this round - what this pairing was based on"
          >
            {score_str(@side.score)}
          </span>
          <span class="pe-seed" title="starting rank">#{@side.pairing_number}</span>
          <span class="pe-side-colour">{colour_word(@colour)}</span>
          <span :if={@dir == :down} class="pe-tag pe-tag-down">▼ paired down</span>
          <span :if={@dir == :up} class="pe-tag pe-tag-up">▲ paired up</span>
        </div>
        <div class="pe-due">
          <span :if={@side.colour_due == nil} class="pe-tag pe-tag-muted">no colour history yet</span>
          <span :if={@side.colour_due != nil and @side.colour_ok} class="pe-tag pe-tag-ok">
            ✓ matches due colour ({colour_word(@side.colour_due)})
          </span>
          <span :if={@side.colour_due != nil and not @side.colour_ok} class="pe-tag pe-tag-warn">
            ✗ against due colour ({colour_word(@side.colour_due)})
          </span>
        </div>
        <div
          :if={@side.ladder_value}
          class="pe-ladder"
          title={"Keizer ladder value #{@side.ladder_value}"}
        >
          <div class="pe-ladder-fill" style={"width: #{ladder_pct(@side.ladder_value, @ladder_max)}%"}>
          </div>
          <span class="pe-ladder-num">ladder {@side.ladder_value}</span>
        </div>
      </div>
    </div>
    """
  end

  # A "which round?" picker so the arbiter can hop between explanations
  # without going back to the audit page first.
  attr :tournament, :map, required: true
  attr :paired_rounds, :integer, required: true
  attr :round_number, :integer, required: true

  defp round_selector(assigns) do
    ~H"""
    <div
      :if={@paired_rounds > 0}
      id="explain-round-selector"
      class="round-picker"
      style="margin-bottom: 12px"
    >
      <.link
        :for={n <- 1..@paired_rounds}
        navigate={~p"/t/#{@tournament.id}/pairings/#{n}/explain"}
        class={["pe-btn", n == @round_number && "active"]}
      >
        {n}
      </.link>
    </div>
    """
  end

  @impl true
  def render(%{rationale: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} tournament={@tournament} active="audit">
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">Pairing rationale for round {@round_number}</p>
        </div>
      </div>

      <AuditLive.subnav tournament={@tournament} active={:explain} />
      <.round_selector
        tournament={@tournament}
        paired_rounds={@paired_rounds}
        round_number={@round_number}
      />

      <div class="card error-note" style="display: block; margin: 12px 0">
        Round {@round_number} has not been paired yet, so there is nothing to explain.
        <.link navigate={~p"/t/#{@tournament.id}/audit"}>Back to audit trail</.link>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} tournament={@tournament} active="audit">
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">
            Pairing rationale for round {@round_number} - {system_label(
              @rationale.pairing_system,
              @tournament
            )}
          </p>
        </div>
        <div class="actions" style="margin: 0">
          <.link class="pe-btn" navigate={~p"/t/#{@tournament.id}/audit"}>Back to audit trail</.link>
        </div>
      </div>

      <AuditLive.subnav tournament={@tournament} active={:explain} />
      <.round_selector
        tournament={@tournament}
        paired_rounds={@paired_rounds}
        round_number={@round_number}
      />

      <p class="hint" style="margin: 4px 0 12px">
        This is a live analysis of the current data (pre-round standings, colour history and
        pairing output), not a stored replay. The engine's internal tie-break reasoning is not
        recorded in what it hands back, so for Swiss this shows the input state that constrained
        the decision and the observable shape of its output (brackets, floaters, byes). Items marked
        <strong>Worth a look</strong>
        below are automated data-consistency checks, not proof of
        an actual arbiting error - they flag patterns worth a second look, nothing more.
      </p>

      <div :if={@anomalies != []} class="card" style="margin: 8px 0">
        <h3 style="margin-top: 0">Worth a look</h3>
        <p :for={item <- @anomalies} class="pe-warning" style="margin-top: 6px">
          <.link href={"#pe-board-#{item.board}"}>{item.text}</.link>
        </p>
      </div>

      <div class="card pe-summary" style="margin: 8px 0">
        <span class="pe-stat">
          <span class="pe-stat-n">{@rationale.summary.boards}</span> board(s)
        </span>
        <span class="pe-stat">
          <span class="pe-stat-n">{@rationale.summary.byes}</span> bye(s)
        </span>
        <span class={["pe-stat", @rationale.summary.floaters > 0 && "is-warm"]}>
          <span class="pe-stat-n">{@rationale.summary.floaters}</span> floater(s)
        </span>
        <span class={["pe-stat", @rationale.summary.rematches > 0 && "is-danger"]}>
          <span class="pe-stat-n">{@rationale.summary.rematches}</span> rematch(es)
        </span>
      </div>

      <details class="card" style="margin: 8px 0">
        <summary style="cursor: pointer; font-weight: 650">
          Pairing numbers ({length(@rationale.boards)} board{if length(@rationale.boards) != 1,
            do: "s"})
        </summary>
        <p class="hint" style="margin: 8px 0 10px">
          The classic pairing-sheet format - starting rank vs. starting rank, board by board. The
          bracket map below shows the same pairings with the reasoning behind them.
        </p>
        <table class="pe-table">
          <thead>
            <tr>
              <th class="num">Board</th>
              <th>White</th>
              <th>Black</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={b <- @rationale.boards}>
              <td class="num">{b.board}</td>
              <td>
                <span :if={b.white} class="pe-seed">{b.white.pairing_number}</span> {seat_name(
                  b.white
                )}
              </td>
              <td :if={!b.is_bye}>
                <span :if={b.black} class="pe-seed">{b.black.pairing_number}</span> {seat_name(
                  b.black
                )}
              </td>
              <td :if={b.is_bye} class="hint">bye</td>
            </tr>
          </tbody>
        </table>
      </details>

      <div :if={@rationale.berger} class="card" style="margin: 8px 0">
        <h3 style="margin-top: 0">Berger schedule</h3>
        <p :if={@rationale.berger.match_format} style="margin: 0">
          This is match {@rationale.berger.match_number}, leg {@rationale.berger.leg}. The whole
          schedule is fully determined by the number of players - there is no choice to explain.
        </p>
        <p :if={!@rationale.berger.match_format} style="margin: 0">
          Cycle {@rationale.berger.cycle} of {@rationale.berger.total_cycles}, schedule round {@rationale.berger.cycle_round}. The Berger table fixes every pairing in advance - this
          round's boards are the deterministic slot, not a computed choice.
        </p>
      </div>

      <div
        :if={@rationale.score_groups != []}
        class="card pe-bracket-map"
        data-active-filter=""
        style="margin: 8px 0"
      >
        <h3 style="margin-top: 0">Pre-round score brackets</h3>
        <p class="hint" style="margin-top: 0">
          Players grouped by their standing going into this round (highest at the top). Each line
          is one board; a connector that slopes across bands is a floater - an odd bracket can't
          pair entirely within itself, so it floats a player to the neighbouring bracket. Hover
          (or tap) a pairing for its full detail. Click a legend item or a score-band label to
          highlight just that slice of the map.
        </p>

        <div :if={@bracket} class="pe-bracket-scroll">
          <%!-- No aria-hidden here even though the gutter used to carry it:
                the band rows are now real, focusable filter buttons, and
                focusable content inside an aria-hidden subtree is an a11y
                violation (tabbable but invisible to assistive tech). --%>
          <div class="pe-band-gutter" style={"height: #{@bracket.height}px"}>
            <button
              :for={band <- @bracket.bands}
              type="button"
              class={["pe-band-row", rem(band.idx, 2) == 1 && "is-alt"]}
              style={"top: #{band.y - 22}px"}
              data-filter={"band-#{band.idx}"}
              title="Click to highlight only this score band"
              aria-label={"Highlight only the #{score_str(band.score)}-point score band (#{band.count} players)"}
            >
              <span class="pe-band-score">{score_str(band.score)}</span>
              <span class="pe-band-meta">
                {band.count}p<span :if={band.odd} class="pe-band-odd"> · odd</span>
              </span>
            </button>
          </div>

          <div
            class="pe-bracket-canvas"
            style={"width: #{@bracket.width}px; min-height: #{@bracket.height}px; --pe-hover-min: #{@bracket.hover_min_height}px; --pe-pinned-min: #{@bracket.pinned_min_height}px"}
          >
            <svg
              class="pe-bracket-svg"
              width={@bracket.width}
              height={@bracket.height}
              viewBox={"0 0 #{@bracket.width} #{@bracket.height}"}
              role="img"
              aria-label="Score-bracket map of this round's pairings"
            >
              <.bracket_bands bands={@bracket.bands} width={@bracket.width} />
              <g>
                <text
                  :for={a <- @bracket.axis}
                  x={a.x}
                  y={@bracket.height - 7}
                  font-size="10"
                  text-anchor="middle"
                  fill="var(--text-soft)"
                >
                  {a.label}
                </text>
              </g>
              <.bracket_links links={@bracket.links} />
              <.bracket_dots wraps={@bracket.wraps} />
            </svg>

            <div class="pe-board-overlay">
              <div
                :for={w <- @bracket.wraps}
                id={w.id}
                class={["pe-board-wrap", w.pop_v, w.pop_h]}
                tabindex="0"
                aria-label={w.aria}
                data-opponent={w.opponent_dot_id}
                data-board={w.board}
                style={"left: #{w.left}px; top: #{w.top}px"}
              >
                <div class="pe-dot-popover" role="tooltip">
                  <div class="pe-pop-name">{w.side.player.name}</div>

                  <div class="pe-pop-tags">
                    <span class="pe-tag pe-tag-muted">Board {w.board}</span>
                    <span :if={w.colour == :bye} class="pe-tag pe-tag-bye">bye</span>
                    <span :if={w.colour != :bye} class="pe-side-colour">{colour_word(w.colour)}</span>
                    <span class="pe-score">{score_str(w.side.score)}</span>
                    <span class="pe-seed">seed #{w.side.pairing_number}</span>
                  </div>

                  <div class="pe-pop-tags">
                    <span :if={w.dir == :down} class="pe-tag pe-tag-down">▼ paired down</span>
                    <span :if={w.dir == :up} class="pe-tag pe-tag-up">▲ paired up</span>
                    <span :if={w.side.colour_due == nil} class="pe-tag pe-tag-muted">
                      no colour history yet
                    </span>
                    <span :if={w.side.colour_due != nil and w.side.colour_ok} class="pe-tag pe-tag-ok">
                      ✓ due {colour_word(w.side.colour_due)}
                    </span>
                    <span
                      :if={w.side.colour_due != nil and not w.side.colour_ok}
                      class="pe-tag pe-tag-warn"
                    >
                      ✗ due {colour_word(w.side.colour_due)}
                    </span>
                  </div>

                  <div :if={w.rematch or w.side.had_prior_bye} class="pe-pop-tags">
                    <span
                      :if={w.rematch}
                      class={[
                        "pe-tag",
                        w.rematch_anomaly && "pe-tag-danger",
                        !w.rematch_anomaly && "pe-tag-muted"
                      ]}
                    >
                      {if w.rematch_anomaly, do: "REMATCH", else: "rematch (match format)"}
                    </span>
                    <span :if={w.side.had_prior_bye} class="pe-tag pe-tag-warn">already had a bye</span>
                  </div>

                  <div :if={w.colour == :bye and w.bye_detail} class="pe-pop-foot">
                    {w.bye_detail.convention}
                  </div>

                  <.trail_popover
                    :if={@round_number > 1 and @trails[w.side.player.id]}
                    trail={@trails[w.side.player.id][:rounds]}
                    summary={@trails[w.side.player.id][:summary]}
                  />
                </div>
              </div>
            </div>
          </div>
        </div>

        <div
          :if={@bracket}
          id="pe-minimap"
          class="pe-minimap-wrap"
          phx-hook=".BracketMinimap"
          aria-hidden="true"
        >
          <%!-- Overview strip (task B): the same bands/links/dots over the
                same viewBox, scaled down - no halos/triangles/text/overlay,
                and not `.pe-filterable`, so an active legend/band filter
                leaves the minimap full (it's a whole-round overview, by
                design). The viewport rect + scroll sync is driven by the
                colocated BracketMinimap hook below; the hook also hides this
                whole element when the chart doesn't overflow horizontally.
                `preserveAspectRatio="none"` stretches the SVG to fill the
                strip's own width (letterboxing with "meet" wasted the sides
                and, worse, meant clicked/dragged x didn't map linearly onto
                strip.scrollWidth, throwing off the hook's seek/sync math). --%>
          <svg
            class="pe-minimap-svg"
            width="100%"
            viewBox={"0 0 #{@bracket.width} #{@bracket.height}"}
            preserveAspectRatio="none"
            role="img"
            aria-label="Overview of the score-bracket map"
          >
            <.bracket_bands bands={@bracket.bands} width={@bracket.width} />
            <.bracket_links links={@bracket.links} interactive={false} />
            <.bracket_dots wraps={@bracket.wraps} interactive={false} />
          </svg>
          <div class="pe-minimap-viewport"></div>
        </div>

        <%!-- Head-to-head duo panels (one hidden panel per playing board):
              pin a player, then click their EXACT opponent's dot to open the
              board's panel here under the chart; clicking either of the two
              dots (or the × button) closes it again. Pure server-rendered
              markup toggled by the delegated click listener in
              assets/js/app.js - no round-trip, same philosophy as pinning. --%>
        <div
          :for={duo <- (@bracket && @bracket.duos) || []}
          id={"pe-duo-#{duo.board}"}
          class="pe-duo"
          data-dots={"#{duo.w.id} #{duo.b.id}"}
        >
          <div class="pe-duo-head">
            <span class="pe-tag pe-tag-muted">Board {duo.board}</span>
            <strong>{duo.w.side.player.name}</strong>
            <span class="pe-duo-vs">vs</span>
            <strong>{duo.b.side.player.name}</strong>
            <button type="button" class="pe-duo-close" aria-label="Close head-to-head">✕</button>
          </div>

          <div class="pe-duo-grid">
            <div :for={{w, colour_label} <- [{duo.w, "White"}, {duo.b, "Black"}]} class="pe-duo-side">
              <div class="pe-pop-name">{w.side.player.name}</div>
              <div class="pe-pop-tags">
                <span class="pe-side-colour">{colour_label}</span>
                <span class="pe-score">{score_str(w.side.score)}</span>
                <span class="pe-seed">seed #{w.side.pairing_number}</span>
                <span :if={duo_rating(w) != nil} class="pe-tag pe-tag-muted">
                  {duo_rating(w)}
                </span>
              </div>
              <div class="pe-pop-tags">
                <span :if={w.dir == :down} class="pe-tag pe-tag-down">▼ paired down</span>
                <span :if={w.dir == :up} class="pe-tag pe-tag-up">▲ paired up</span>
                <span :if={w.side.colour_due == nil} class="pe-tag pe-tag-muted">
                  no colour history yet
                </span>
                <span :if={w.side.colour_due != nil and w.side.colour_ok} class="pe-tag pe-tag-ok">
                  ✓ due {colour_word(w.side.colour_due)}
                </span>
                <span
                  :if={w.side.colour_due != nil and not w.side.colour_ok}
                  class="pe-tag pe-tag-warn"
                >
                  ✗ due {colour_word(w.side.colour_due)}
                </span>
                <span :if={w.side.had_prior_bye} class="pe-tag pe-tag-warn">already had a bye</span>
              </div>
            </div>
          </div>

          <div class="pe-pop-tags pe-duo-shared">
            <span class="pe-tag pe-tag-muted">
              score gap {score_str(abs(duo.w.side.score - duo.b.side.score))}
            </span>
            <span :if={duo_rating(duo.w) && duo_rating(duo.b)} class="pe-tag pe-tag-muted">
              rating gap {abs(duo_rating(duo.w) - duo_rating(duo.b))}
            </span>
            <span
              :if={duo.w.rematch}
              class={[
                "pe-tag",
                duo.w.rematch_anomaly && "pe-tag-danger",
                !duo.w.rematch_anomaly && "pe-tag-muted"
              ]}
            >
              {if duo.w.rematch_anomaly,
                do: "REMATCH - they already played each other",
                else: "rematch (match format)"}
            </span>
            <span :if={!duo.w.rematch} class="pe-tag pe-tag-ok">
              first meeting this tournament
            </span>
          </div>
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".BracketMinimap">
          // Overview minimap for the (often wider-than-viewport) bracket
          // scroll strip. The strip's `scroll` event doesn't bubble to
          // document, so the delegated-listener pattern the rest of this page
          // uses can't see it - this is a real hook bound directly to the
          // strip, cleaned up on destroy so round navigation doesn't leave a
          // second listener behind.
          export default {
            mounted() {
              this.strip = this.el.closest(".pe-bracket-map")?.querySelector(".pe-bracket-scroll");
              this.viewport = this.el.querySelector(".pe-minimap-viewport");
              if (!this.strip || !this.viewport) return;

              this.ticking = false;
              this.onScroll = () => {
                if (this.ticking) return;
                this.ticking = true;
                requestAnimationFrame(() => { this.ticking = false; this.sync(); });
              };
              this.onResize = () => this.sync();
              this.onDown = (e) => { this.dragging = true; this.seek(e); };
              this.onMove = (e) => { if (this.dragging) this.seek(e, true); };
              this.onUp = () => { this.dragging = false; };

              this.strip.addEventListener("scroll", this.onScroll, { passive: true });
              window.addEventListener("resize", this.onResize);
              this.el.addEventListener("pointerdown", this.onDown);
              window.addEventListener("pointermove", this.onMove);
              window.addEventListener("pointerup", this.onUp);

              this.sync();
            },

            updated() { this.sync(); },

            // Position the viewport rect from the strip's scroll geometry, and
            // hide the whole minimap when there's nothing to scroll.
            sync() {
              if (!this.strip || !this.viewport) return;
              const { scrollWidth, clientWidth, scrollLeft } = this.strip;
              const overflow = scrollWidth > clientWidth + 1;
              // Must be an explicit "block": the stylesheet default is
              // display:none (no flash before this hook runs), so clearing
              // the inline style ("") would fall back to hidden forever.
              this.el.style.display = overflow ? "block" : "none";
              if (!overflow) return;

              const w = this.el.clientWidth;
              this.viewport.style.left = (scrollLeft / scrollWidth * w) + "px";
              this.viewport.style.width = (clientWidth / scrollWidth * w) + "px";
            },

            // Scroll the strip so the clicked/dragged minimap point is centred.
            // A click keeps the strip's CSS smooth glide; during a DRAG each
            // pointermove must track instantly (`instant` true) - the strip
            // has `scroll-behavior: smooth`, and re-triggering a smooth
            // animation on every move would rubber-band behind the pointer.
            seek(e, instant) {
              if (!this.strip) return;
              const rect = this.el.getBoundingClientRect();
              const frac = Math.min(Math.max((e.clientX - rect.left) / rect.width, 0), 1);
              const target = frac * this.strip.scrollWidth - this.strip.clientWidth / 2;
              this.strip.scrollTo({left: Math.max(0, target), behavior: instant ? "instant" : "smooth"});
            },

            destroyed() {
              if (this.strip) this.strip.removeEventListener("scroll", this.onScroll);
              window.removeEventListener("resize", this.onResize);
              if (this.el) this.el.removeEventListener("pointerdown", this.onDown);
              window.removeEventListener("pointermove", this.onMove);
              window.removeEventListener("pointerup", this.onUp);
            }
          }
        </script>

        <div class="pe-legend">
          <button
            type="button"
            class="pe-legend-item"
            data-filter="w"
            title="Click to highlight only these"
          >
            <span class="pe-legend-disc pe-disc-w"></span> White
          </button>
          <button
            type="button"
            class="pe-legend-item"
            data-filter="b"
            title="Click to highlight only these"
          >
            <span class="pe-legend-disc pe-disc-b"></span> Black
          </button>
          <button
            :if={@bracket && @bracket.has_bye}
            type="button"
            class="pe-legend-item"
            data-filter="bye"
            title="Click to highlight only these"
          >
            <span class="pe-legend-disc pe-disc-byedot"></span> bye
          </button>
          <button
            type="button"
            class="pe-legend-item"
            data-filter="within"
            title="Click to highlight only these"
          >
            <span class="pe-legend-line"></span> within bracket
          </button>
          <button
            type="button"
            class="pe-legend-item"
            data-filter="float"
            title="Click to highlight only these"
          >
            <span class="pe-legend-line is-float"></span> floater
          </button>
          <button
            :if={@bracket && @bracket.has_rematch_anomaly}
            type="button"
            class="pe-legend-item"
            data-filter="anomaly"
            title="Click to highlight only these"
          >
            <span class="pe-legend-line is-anomaly"></span> rematch (anomaly)
          </button>
          <button
            :if={@bracket && @bracket.has_match_rematch}
            type="button"
            class="pe-legend-item"
            data-filter="rematch"
            title="Click to highlight only these"
          >
            <span class="pe-legend-line is-rematch"></span> rematch (match format)
          </button>
          <button
            type="button"
            class="pe-legend-item"
            data-filter="down"
            title="Click to highlight only these"
          >
            <span class="pe-legend-tri down">▼</span> paired down
          </button>
          <button
            type="button"
            class="pe-legend-item"
            data-filter="up"
            title="Click to highlight only these"
          >
            <span class="pe-legend-tri up">▲</span> paired up
          </button>
          <button
            :if={@bracket && @bracket.has_against_due}
            type="button"
            class="pe-legend-item"
            data-filter="against-due"
            title="Player's own colour history says they were due White (or Black) next, but this pairing gave them the other colour - click to highlight."
          >
            <span class="pe-legend-halo"></span> colour against due
          </button>
        </div>
      </div>

      <h3 style="margin: 18px 0 8px">Board by board</h3>
      <div class="pe-pair-grid">
        <div
          :for={b <- @rationale.boards}
          id={"pe-board-#{b.board}"}
          class={[
            "pe-pair-card",
            b.is_bye && "pe-bye-card",
            not b.is_bye && b.rematch && "is-rematch",
            not b.is_bye && not b.rematch && b.floater && "is-float"
          ]}
        >
          <div class="pe-pair-head">
            <span class="pe-board-no">Board {b.board}</span>
            <span :if={@rationale.pair_by_category && b.category} class="pe-tag pe-tag-muted">
              {b.category}
            </span>
            <span class="pe-head-flags">
              <span :if={b.is_bye} class="pe-tag pe-tag-bye">bye</span>
              <span :if={not b.is_bye and b.floater} class="pe-tag pe-tag-float">floater</span>
              <span :if={not b.is_bye and not b.floater} class="pe-tag pe-tag-muted">same bracket</span>
              <span :if={not b.is_bye and b.rematch} class="pe-tag pe-tag-danger">REMATCH</span>
              <span :if={not b.is_bye and not b.rematch} class="pe-tag pe-tag-ok">
                no prior meeting ✓
              </span>
            </span>
          </div>

          <.pairing_side :if={b.white} side={b.white} colour={:w} board={b} ladder_max={@ladder_max} />
          <p :if={!b.white} class="pe-pair-foot">
            Seat vacant - this board isn't finished yet.
          </p>

          <div :if={not b.is_bye} class="pe-vs">vs</div>
          <.pairing_side
            :if={not b.is_bye and b.black}
            side={b.black}
            colour={:b}
            board={b}
            ladder_max={@ladder_max}
          />
          <p :if={not b.is_bye and !b.black} class="pe-pair-foot">
            Seat vacant - this board isn't finished yet.
          </p>
          <p :if={not b.is_bye and float_note(b)} class="pe-pair-foot">{float_note(b)}</p>
          <p :if={not b.is_bye and b.rematch_anomaly} class="pe-warning">
            <strong>Worth a look:</strong>
            these two players already met in an earlier round of this tournament, and neither
            round-robin nor Swiss "match format" is enabled here to explain a deliberate
            back-to-back rematch - worth double-checking the game history for a data issue.
          </p>

          <p :if={b.is_bye and b[:bye_detail]} class="pe-pair-foot">
            {b.bye_detail.convention}
          </p>
          <p
            :if={b.is_bye and b[:bye_detail] != nil and b.bye_detail.had_prior_bye}
            class="pe-warning"
          >
            <strong>Note:</strong> this player already had a bye earlier.
          </p>
          <p
            :if={b.is_bye and b[:bye_detail] != nil and b.bye_detail.had_prior_pairing_bye}
            class="pe-warning"
          >
            <strong>Worth a look:</strong>
            this player has now received more than one pairing-allocated (engine-assigned) bye -
            FIDE Dutch pairing normally avoids repeating that for the same player whenever an
            alternative exists.
          </p>
        </div>
      </div>

      <div :if={@rationale.byes.requested != []} class="card table-card" style="margin-top: 16px">
        <%!-- .table-card zeroes the card's own padding (tables run
              edge-to-edge), so a heading inside one must carry its own -
              same pattern as the norms page's table-card headings. Without
              it this title sat flush against the card edge, visibly
              misaligned with the padded table cells below. --%>
        <h3 style="margin: 0; padding: 16px 16px 8px">Requested / absence byes this round</h3>
        <table class="pe-table">
          <thead>
            <tr>
              <th>Player</th><th>Type</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={rb <- @rationale.byes.requested}>
              <td>{player_label(rb.player)}</td>
              <td>{rb.type}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
