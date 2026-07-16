defmodule PairingsEngineWeb.PairingExplainLive do
  @moduledoc """
  "Why were these players paired this way?" — a live, visual explanation of a
  single round's pairings, computed fresh from current data by
  `PairingsEngine.PairingRationale` (the same analysis behind the audit
  trail's `"pairing.round_paired"` entry).

  For each board it shows both players' pre-round score, starting rank and
  colour (with FIDE due-colour agreement), flags floaters (a pairing that
  crosses score brackets — someone "paired up" or "paired down"), confirms no
  rematch, and names the pairing-allocated bye recipient. Round-robin shows
  the deterministic Berger-schedule slot; Keizer shows ladder values.

  Access control matches every other tournament page
  (`Tournaments.get_authorized_tournament!/2`).
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{PairingRationale, Tournaments}
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.Player
  alias PairingsEngineWeb.AuditLive

  @impl true
  def mount(%{"id" => id, "round" => round}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)
    round_number = String.to_integer(round)
    rationale = PairingRationale.for_round(tournament, round_number)
    paired_rounds = Engine.paired_rounds_count(tournament.id)

    {:ok,
     assign(socket,
       tournament: tournament,
       round_number: round_number,
       rationale: rationale,
       bracket: bracket_layout(rationale),
       ladder_max: ladder_max(rationale),
       paired_rounds: paired_rounds,
       page_title: "#{tournament.name} · Pairing rationale — Round #{round_number}"
     )}
  end

  ## ---------- display helpers ----------

  defp player_label(nil), do: "—"

  defp player_label(%Player{} = p) do
    rating = Player.rating(p)
    "#{if p.title not in [nil, ""], do: "#{p.title} "}#{p.name}#{if rating > 0, do: " (#{rating})", else: ""}"
  end

  defp score_str(nil), do: "0"
  defp score_str(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 1)
  defp score_str(n), do: to_string(n)

  defp colour_word(:w), do: "White"
  defp colour_word(:b), do: "Black"
  defp colour_word(_), do: "—"

  defp float_note(%{floater: false}), do: nil

  defp float_note(%{white: w, black: b}) when not is_nil(b) do
    {high, low} = if w.score >= b.score, do: {w, b}, else: {b, w}

    "Floater — #{high.player.name} (#{score_str(high.score)}) paired down against " <>
      "#{low.player.name} (#{score_str(low.score)}), who paired up."
  end

  defp float_note(_), do: nil

  defp system_label("round_robin"), do: "Round robin (Berger schedule)"
  defp system_label("keizer"), do: "Keizer ladder"
  defp system_label(_), do: "Swiss (FIDE Dutch / JaVaFo)"

  ## ---------- purely-presentational derivations ----------
  ## These reshape facts PairingRationale already computed into geometry /
  ## scaling for the visuals; they add no new facts and change no semantics.

  # Direction a given side floated, relative to its board's float pair, or nil.
  defp float_dir(%{floater: true, float_down: down}, %{player: %{id: id}}) when down == id, do: :down
  defp float_dir(%{floater: true, float_up: up}, %{player: %{id: id}}) when up == id, do: :up
  defp float_dir(_board, _side), do: nil

  # Colour matching the float direction (warm = down, cool = up, green = none).
  defp float_colour(:down), do: "#b5762f"
  defp float_colour(:up), do: "#3a6ea5"
  defp float_colour(_), do: "#2e5e44"

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

  # Geometry for the score-bracket map SVG. One horizontal band per pre-round
  # score bracket (highest at top), and one connector per playing board between
  # its two players' bracket bands — so a floater's line visibly slopes across
  # bands. Returns nil when there is nothing to draw.
  defp bracket_layout(nil), do: nil
  defp bracket_layout(%{score_groups: []}), do: nil

  defp bracket_layout(%{boards: boards, score_groups: groups}) do
    top = 34
    row_gap = 56
    left = 132
    col_gap = 52
    dx = 15

    y_of =
      groups
      |> Enum.with_index()
      |> Map.new(fn {g, i} -> {g.score, top + i * row_gap} end)

    bands =
      groups
      |> Enum.with_index()
      |> Enum.map(fn {g, i} ->
        %{score: g.score, count: g.count, odd: g.odd, y: top + i * row_gap, idx: i}
      end)

    playing = Enum.reject(boards, & &1.is_bye)

    links =
      playing
      |> Enum.with_index()
      |> Enum.map(fn {b, i} ->
        x = left + i * col_gap + div(col_gap, 2)

        %{
          board: b.board,
          floater: b.floater,
          white: %{
            x: x - dx,
            y: Map.fetch!(y_of, b.white.score),
            name: b.white.player.name,
            score: b.white.score,
            dir: float_dir(b, b.white)
          },
          black: %{
            x: x + dx,
            y: Map.fetch!(y_of, b.black.score),
            name: b.black.player.name,
            score: b.black.score,
            dir: float_dir(b, b.black)
          }
        }
      end)

    %{
      bands: bands,
      links: links,
      width: left + length(playing) * col_gap + 40,
      height: top + max(length(groups) - 1, 0) * row_gap + 44,
      band_width: left + length(playing) * col_gap + 40,
      left: left
    }
  end

  # One player's side of a pairing card: colour disc, name, score/seed, the
  # FIDE due-colour verdict, any float direction, and (Keizer) a ladder bar.
  attr :side, :map, required: true
  attr :colour, :atom, required: true
  attr :board, :map, required: true
  attr :ladder_max, :any, default: nil

  defp pairing_side(assigns) do
    assigns = assign(assigns, :dir, float_dir(assigns.board, assigns.side))

    ~H"""
    <div class={["pe-side", @colour == :w && "pe-side-w", @colour == :b && "pe-side-b"]}>
      <span class={["pe-disc", @colour == :w && "pe-disc-w", @colour == :b && "pe-disc-b"]} aria-hidden="true">
      </span>
      <div class="pe-side-body">
        <div class="pe-name">{player_label(@side.player)}</div>
        <div class="pe-meta">
          <span class="pe-score" title="pre-round score">{score_str(@side.score)}</span>
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
        <div :if={@side.ladder_value} class="pe-ladder" title={"Keizer ladder value #{@side.ladder_value}"}>
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
    <div :if={@paired_rounds > 0} id="explain-round-selector" class="round-picker" style="margin-bottom: 12px">
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
            Pairing rationale for round {@round_number} — {system_label(@rationale.pairing_system)}
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
        pairing output), not a stored replay. JaVaFo's internal tie-break reasoning can't be
        extracted, so for Swiss this shows the input state that constrained the decision and the
        observable shape of its output (brackets, floaters, byes).
      </p>

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

      <div :if={@rationale.berger} class="card" style="margin: 8px 0">
        <h3 style="margin-top: 0">Berger schedule</h3>
        <p :if={@rationale.berger.match_format} style="margin: 0">
          This is match {@rationale.berger.match_number}, leg {@rationale.berger.leg}. The whole
          schedule is fully determined by the number of players — there is no choice to explain.
        </p>
        <p :if={!@rationale.berger.match_format} style="margin: 0">
          Cycle {@rationale.berger.cycle} of {@rationale.berger.total_cycles}, schedule round
          {@rationale.berger.cycle_round}. The Berger table fixes every pairing in advance — this
          round's boards are the deterministic slot, not a computed choice.
        </p>
      </div>

      <div :if={@rationale.score_groups != []} class="card" style="margin: 8px 0">
        <h3 style="margin-top: 0">Pre-round score brackets</h3>
        <p class="hint" style="margin-top: 0">
          Players grouped by their standing going into this round (highest at the top). Each line
          is one board; a connector that slopes across bands is a floater — an odd bracket can't
          pair entirely within itself, so it floats a player to the neighbouring bracket.
        </p>

        <div :if={@bracket} class="pe-bracket-scroll">
          <svg
            class="pe-bracket-svg"
            width={@bracket.width}
            height={@bracket.height}
            viewBox={"0 0 #{@bracket.width} #{@bracket.height}"}
            role="img"
            aria-label="Score-bracket map of this round's pairings"
          >
            <g>
              <rect
                :for={band <- @bracket.bands}
                x="0"
                y={band.y - 22}
                width={@bracket.band_width}
                height="44"
                rx="6"
                fill={if rem(band.idx, 2) == 0, do: "#faf9f6", else: "#f1efe9"}
              />
            </g>
            <g>
              <text
                :for={band <- @bracket.bands}
                x="12"
                y={band.y + 5}
                font-size="13"
                fill="#6f6a60"
              >
                <tspan font-weight="700" fill="#24211c">{score_str(band.score)}</tspan>
                · {band.count}p<tspan :if={band.odd} fill="#a76a25"> · odd</tspan>
              </text>
            </g>
            <g>
              <line
                :for={l <- @bracket.links}
                x1={l.white.x}
                y1={l.white.y}
                x2={l.black.x}
                y2={l.black.y}
                stroke={if l.floater, do: "#b5762f", else: "#9db8a8"}
                stroke-width="2.5"
                stroke-dasharray={if l.floater, do: "5 3", else: "0"}
                stroke-linecap="round"
              />
            </g>
            <g :for={l <- @bracket.links}>
              <circle cx={l.white.x} cy={l.white.y} r="9" fill="#ffffff" stroke="#2e5e44" stroke-width="2">
                <title>{l.white.name} — White, score {score_str(l.white.score)}</title>
              </circle>
              <circle cx={l.black.x} cy={l.black.y} r="9" fill="#2e5e44">
                <title>{l.black.name} — Black, score {score_str(l.black.score)}</title>
              </circle>
              <text
                :if={l.white.dir}
                x={l.white.x}
                y={l.white.y - 13}
                font-size="12"
                font-weight="700"
                text-anchor="middle"
                fill={float_colour(l.white.dir)}
              >{if l.white.dir == :down, do: "▼", else: "▲"}</text>
              <text
                :if={l.black.dir}
                x={l.black.x}
                y={l.black.y - 13}
                font-size="12"
                font-weight="700"
                text-anchor="middle"
                fill={float_colour(l.black.dir)}
              >{if l.black.dir == :down, do: "▼", else: "▲"}</text>
            </g>
          </svg>
        </div>

        <div class="pe-legend">
          <span class="pe-legend-item"><span class="pe-legend-disc pe-disc-w"></span> White</span>
          <span class="pe-legend-item"><span class="pe-legend-disc pe-disc-b"></span> Black</span>
          <span class="pe-legend-item"><span class="pe-legend-line"></span> within bracket</span>
          <span class="pe-legend-item"><span class="pe-legend-line is-float"></span> floater</span>
          <span class="pe-legend-item"><span class="pe-legend-tri down">▼</span> paired down</span>
          <span class="pe-legend-item"><span class="pe-legend-tri up">▲</span> paired up</span>
        </div>
      </div>

      <h3 style="margin: 18px 0 8px">Board by board</h3>
      <div class="pe-pair-grid">
        <div
          :for={b <- @rationale.boards}
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

          <.pairing_side side={b.white} colour={:w} board={b} ladder_max={@ladder_max} />

          <div :if={not b.is_bye} class="pe-vs">vs</div>
          <.pairing_side
            :if={not b.is_bye}
            side={b.black}
            colour={:b}
            board={b}
            ladder_max={@ladder_max}
          />
          <p :if={not b.is_bye and float_note(b)} class="pe-pair-foot">{float_note(b)}</p>

          <p :if={b.is_bye and b[:bye_detail]} class="pe-pair-foot">
            {b.bye_detail.convention}
          </p>
          <p
            :if={b.is_bye and b[:bye_detail] != nil and b.bye_detail.had_prior_bye}
            class="pe-warning"
          >
            <strong>Note:</strong> this player already had a bye earlier.
          </p>
        </div>
      </div>

      <div :if={@rationale.byes.requested != []} class="card table-card" style="margin-top: 16px">
        <h3 style="margin: 0 0 8px">Requested / absence byes this round</h3>
        <table class="pe-table">
          <thead>
            <tr><th>Player</th><th>Type</th></tr>
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
