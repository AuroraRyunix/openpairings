defmodule PairingsEngineWeb.HistoryLive do
  @moduledoc """
  The tournament history page (`/t/:id/history`) — a visual, chronological
  view of everything that has happened to a tournament, built from two
  sources merged into one stream:

    * `PairingsEngine.Audit` rows — every state-changing action, with the
      before/after payload rich enough to render a real field-level diff.
    * `PairingsEngine.Snapshots` rows — the automatic restore points taken
      before each irreversible action.

  Distinct from `PairingsEngineWeb.AuditLive`, which is the dense, paginated,
  filterable *table* of the same audit rows. This page is the narrative view:
  fewer entries, more context per entry, and the restore points shown inline
  where they sit in time. The two share `AuditLive.describe/1` so an action's
  prose is written once.

  Read-only — the restore action itself lives in a later change.
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{Audit, History, Snapshots, Tournaments}
  alias PairingsEngineWeb.AuditLive

  # Above this many players the bump chart is an unreadable hairball and the
  # network a solid disc, so both collapse to a note instead of pretending.
  @chart_player_limit 24

  # How many audit rows to pull. The stream is merged with snapshots and
  # rendered in full (no pagination) — this is the "recent narrative" view,
  # with AuditLive remaining the exhaustive paginated one.
  @audit_limit 120

  # Maps an action code onto the timeline category that colours its dot.
  # Anything unmatched falls back to "tournament" (neutral slate) rather
  # than being hidden, so a new action code is still visible here.
  @kinds %{
    "player" => "players",
    "pairing" => "pairings",
    "tournament" => "tournament",
    "logo" => "settings",
    "forbidden_pairing" => "settings",
    "category" => "settings",
    "categories" => "settings",
    "pair_by_category" => "settings",
    "standings" => "standings",
    "import" => "imports",
    "collaborator" => "collaborators",
    "registration" => "settings",
    "public_pages" => "settings"
  }

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     socket
     |> assign(
       tournament: tournament,
       page_title: "#{tournament.name} · History",
       filter: "all"
     )
     |> load_stream()}
  end

  @impl true
  def handle_info({:tournament_changed, _id, _hint}, socket) do
    case Tournaments.get_authorized_tournament(
           socket.assigns.current_scope,
           socket.assigns.tournament.id
         ) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "This tournament was deleted.")
         |> push_navigate(to: ~p"/")}

      tournament ->
        {:noreply, socket |> assign(tournament: tournament) |> load_stream()}
    end
  end

  @impl true
  def handle_event("filter", %{"kind" => kind}, socket) do
    {:noreply, socket |> assign(filter: kind) |> load_stream()}
  end

  ## ---------- building the merged stream ----------

  defp load_stream(socket) do
    tournament = socket.assigns.tournament

    events =
      tournament.id
      |> Audit.list_for_tournament(limit: @audit_limit)
      |> Enum.map(&audit_event/1)

    snapshots =
      tournament.id
      |> Snapshots.list()
      |> Enum.map(&snapshot_event/1)

    entries =
      (events ++ snapshots)
      |> Enum.sort_by(&sort_key/1, :desc)
      |> filter_entries(socket.assigns.filter)

    {rounds, series} = History.standings_evolution(tournament)
    network = History.pairing_network(tournament)

    assign(socket,
      entries: entries,
      days: group_by_day(entries),
      snapshot_count: length(snapshots),
      event_count: length(events),
      bump: bump_chart(rounds, series),
      network: network_chart(network)
    )
  end

  ## ---------- bump chart (standings evolution) ----------

  # Turns the rank-per-round series into ready-to-draw SVG geometry. All the
  # arithmetic lives here rather than in the template so the markup stays
  # readable and the viewBox maths is in one place.
  defp bump_chart([], _series), do: nil
  defp bump_chart(_rounds, []), do: nil

  defp bump_chart(rounds, series) when length(series) > @chart_player_limit do
    %{too_many: length(series), rounds: rounds, lines: [], labels: [], ticks: []}
  end

  defp bump_chart(rounds, series) do
    # Fixed geometry in user units; the SVG scales to its container via
    # viewBox + preserveAspectRatio, so these are ratios, not pixels.
    left = 34
    right = 150
    top = 18
    row = 26
    col = 86

    ranks = length(series)
    width = left + right + max(length(rounds) - 1, 1) * col
    height = top * 2 + max(ranks - 1, 1) * row

    x = fn round_number ->
      idx = Enum.find_index(rounds, &(&1 == round_number)) || 0
      left + idx * col
    end

    y = fn rank -> top + (rank - 1) * row end

    lines =
      series
      |> Enum.with_index()
      |> Enum.map(fn {s, idx} ->
        points =
          Enum.map(s.points, fn p ->
            %{cx: x.(p.round), cy: y.(p.rank), rank: p.rank, round: p.round, points: p.points}
          end)

        %{
          player_id: s.player_id,
          name: s.name,
          final_rank: s.final_rank,
          hue: series_hue(idx),
          d: polyline(points),
          dots: points,
          label_x: (List.last(points) || %{cx: left}).cx + 10,
          label_y: (List.last(points) || %{cy: top}).cy
        }
      end)

    %{
      too_many: nil,
      rounds: rounds,
      width: width,
      height: height,
      lines: lines,
      ticks: Enum.map(rounds, fn r -> %{x: x.(r), label: "R#{r}"} end),
      rank_ticks: for(rank <- 1..ranks, do: %{y: y.(rank), label: to_string(rank)})
    }
  end

  defp polyline(points),
    do: points |> Enum.map(fn p -> "#{p.cx},#{p.cy}" end) |> Enum.join(" ")

  # Evenly spaced hues around the wheel, offset so the first few are visually
  # distinct rather than all reds. Fixed rather than accent-derived for the
  # same reason the timeline categories are.
  defp series_hue(index), do: rem(index * 47 + 205, 360)

  ## ---------- pairing network ----------

  # Circular layout: players evenly spaced on a ring, games as chords. A ring
  # is the right shape for this data — every player has roughly the same
  # number of games, so a force layout would converge on a circle anyway,
  # without being deterministic between renders.
  defp network_chart(%{nodes: []}), do: nil

  defp network_chart(%{nodes: nodes}) when length(nodes) > @chart_player_limit,
    do: %{too_many: length(nodes), nodes: [], edges: []}

  defp network_chart(%{nodes: nodes, edges: edges}) do
    size = 420
    centre = size / 2
    radius = centre - 74
    count = length(nodes)

    placed =
      nodes
      |> Enum.with_index()
      |> Map.new(fn {node, idx} ->
        # Start at 12 o'clock and go clockwise.
        angle = 2 * :math.pi() * idx / count - :math.pi() / 2

        {node.player_id,
         Map.merge(node, %{
           x: centre + radius * :math.cos(angle),
           y: centre + radius * :math.sin(angle),
           angle: angle
         })}
      end)

    max_games = placed |> Map.values() |> Enum.map(& &1.games) |> Enum.max(fn -> 1 end)

    %{
      too_many: nil,
      size: size,
      centre: centre,
      max_games: max_games,
      nodes:
        placed
        |> Map.values()
        |> Enum.sort_by(&{&1.name, &1.player_id})
        |> Enum.map(fn n ->
          Map.merge(n, %{
            r: 5 + 4 * (n.games / max_games),
            # Push the label outside the ring, anchored so text runs away
            # from the centre rather than through it.
            label_x: centre + (radius + 14) * :math.cos(n.angle),
            label_y: centre + (radius + 14) * :math.sin(n.angle),
            anchor: if(:math.cos(n.angle) < -0.1, do: "end", else: "start")
          })
        end),
      edges:
        Enum.flat_map(edges, fn e ->
          with %{} = a <- Map.get(placed, e.a),
               %{} = b <- Map.get(placed, e.b) do
            [
              %{
                x1: a.x,
                y1: a.y,
                x2: b.x,
                y2: b.y,
                count: e.count,
                rounds: e.rounds,
                a_name: a.name,
                b_name: b.name
              }
            ]
          else
            _ -> []
          end
        end)
    }
  end

  defp round1(n) when is_float(n), do: Float.round(n, 1)
  defp round1(n), do: n

  # The two sources timestamp differently: `audit_logs` uses Ecto's default
  # `:naive_datetime`, `tournament_snapshots` uses `:utc_datetime`. Both store
  # UTC, but mixing the two struct types blows up the merged sort, so both are
  # normalised to `DateTime` here. Done at read time rather than by migrating
  # the audit table, which the existing audit page also reads.
  defp to_utc(%DateTime{} = at), do: at
  defp to_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  # Both tables store whole seconds, so a snapshot and the action it protects
  # routinely share a timestamp and their true order isn't recoverable from
  # it. Break the tie by meaning rather than arbitrarily: a snapshot is always
  # captured *before* the action it guards, so at equal times it sorts older
  # (and, since the stream is newest-first, renders below the action). The
  # `id` third makes the order fully deterministic within a source, so the
  # list can't reshuffle between renders.
  defp sort_key(%{at: at, kind: "snapshot", id: id}), do: {DateTime.to_unix(at), 0, id}
  defp sort_key(%{at: at, id: id}), do: {DateTime.to_unix(at), 1, id}

  defp audit_event(row) do
    diff = diff_rows(row.details)

    %{
      id: "audit-#{row.id}",
      at: to_utc(row.inserted_at),
      kind: kind_for(row.action),
      action: row.action,
      who: who(row.user),
      text: headline(row, diff),
      diff: diff,
      snapshot_id: nil
    }
  end

  # `AuditLive.describe/1` inlines the changed fields into its sentence, which
  # is right for the dense audit table but duplicates the diff block here —
  # and its list formatting is cruder than the diff rows'. When there IS a
  # diff to render, use a short headline and let the diff carry the detail.
  defp headline(row, []), do: AuditLive.describe(row)

  defp headline(%{action: action, details: details}, diff),
    do: short_headline(action, details || %{}, length(diff))

  defp short_headline("tournament.settings_updated", _details, n),
    do: "Updated tournament settings — #{field_count(n)} changed."

  defp short_headline("player.updated", details, n) do
    case details["player_name"] do
      name when is_binary(name) and name != "" ->
        "Updated #{name} — #{field_count(n)} changed."

      _ ->
        "Updated a player — #{field_count(n)} changed."
    end
  end

  defp short_headline(action, _details, n), do: "#{action} — #{field_count(n)} changed."

  defp field_count(1), do: "1 field"
  defp field_count(n), do: "#{n} fields"

  defp snapshot_event(snapshot) do
    %{
      id: "snapshot-#{snapshot.id}",
      at: to_utc(snapshot.inserted_at),
      kind: "snapshot",
      action: snapshot.trigger,
      who: who(snapshot.user),
      text: snapshot.summary || "Restore point saved.",
      diff: [],
      snapshot_id: snapshot.id
    }
  end

  # `details["changed_fields"]` is `%{"field" => [before, after]}` — written
  # by `SettingsSupport.log_settings_change/3` and the player-update handler.
  # Anything else (an action whose details aren't a field diff) renders as
  # prose only, via `describe/1`.
  defp diff_rows(%{"changed_fields" => map}) when is_map(map) and map_size(map) > 0 do
    map
    |> Enum.map(fn
      {field, [before, after_value]} -> %{field: field, before: before, after: after_value}
      {field, other} -> %{field: field, before: nil, after: other}
    end)
    |> Enum.sort_by(& &1.field)
  end

  defp diff_rows(_details), do: []

  defp kind_for(action) do
    prefix = action |> to_string() |> String.split(".") |> hd()
    Map.get(@kinds, prefix, "tournament")
  end

  defp who(%{email: email}) when is_binary(email), do: email
  defp who(_), do: "System"

  defp filter_entries(entries, "all"), do: entries

  defp filter_entries(entries, kind),
    do: Enum.filter(entries, &(&1.kind == kind))

  # Groups the already-sorted stream into `{date, entries}` pairs, preserving
  # order. `Enum.chunk_by/2` rather than `group_by` precisely because the
  # latter loses ordering.
  defp group_by_day(entries) do
    entries
    |> Enum.chunk_by(&DateTime.to_date(&1.at))
    |> Enum.map(fn [first | _] = chunk -> {DateTime.to_date(first.at), chunk} end)
  end

  ## ---------- formatting ----------

  defp day_label(date) do
    today = Date.utc_today()

    case Date.diff(today, date) do
      0 -> "Today"
      1 -> "Yesterday"
      _ -> Calendar.strftime(date, "%A %-d %B %Y")
    end
  end

  defp time_label(at), do: Calendar.strftime(at, "%H:%M")

  # Field names come straight from the schema; humanise them rather than
  # showing `points_win` to an arbiter.
  defp field_label(field) do
    field |> to_string() |> String.replace("_", " ")
  end

  defp value_label(nil), do: {:empty, "not set"}
  defp value_label(""), do: {:empty, "blank"}
  defp value_label(true), do: {:value, "on"}
  defp value_label(false), do: {:value, "off"}
  defp value_label(v) when is_list(v), do: {:value, Enum.join(v, ", ")}
  defp value_label(v) when is_map(v), do: {:value, inspect(v)}
  defp value_label(v), do: {:value, to_string(v)}

  @filters [
    {"all", "Everything"},
    {"pairings", "Pairings"},
    {"players", "Players"},
    {"settings", "Settings"},
    {"standings", "Standings"},
    {"snapshot", "Restore points"}
  ]

  defp filters, do: @filters

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      tournament={@tournament}
      active="audit"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">History</p>
        </div>
      </div>

      <AuditLive.subnav tournament={@tournament} active={:history} />

      <div class="card">
        <h2>How the standings moved</h2>

        <p class="hint" style="margin-top: 0">
          Each line is one player, from round to round. Lines crossing means one overtook the
          other. Rank 1 is the top row.
        </p>

        <p :if={is_nil(@bump)} class="tl-empty" style="padding-left: 0">
          Nothing to plot yet — this appears once a round has been paired and scored.
        </p>

        <p :if={@bump && @bump.too_many} class="tl-empty" style="padding-left: 0">
          {@bump.too_many} players is too many to read as a bump chart — it would be a hairball.
          The <.link navigate={~p"/t/#{@tournament.id}/standings"}>Standings</.link>
          page has the same data as a table.
        </p>

        <div :if={@bump && is_nil(@bump.too_many)} class="chart-scroll">
          <svg
            class="chart"
            viewBox={"0 0 #{@bump.width} #{@bump.height}"}
            width={@bump.width}
            height={@bump.height}
            role="img"
            aria-label="Standings position by round"
          >
            <%!-- Round gridlines, behind everything. --%>
            <g class="chart-grid">
              <line
                :for={tick <- @bump.ticks}
                x1={tick.x}
                y1={12}
                x2={tick.x}
                y2={@bump.height - 12}
              />
            </g>

            <g class="chart-axis">
              <text :for={tick <- @bump.ticks} x={tick.x} y={10} text-anchor="middle">
                {tick.label}
              </text>
              <text :for={tick <- @bump.rank_ticks} x={14} y={tick.y + 4} text-anchor="end">
                {tick.label}
              </text>
            </g>

            <g :for={line <- @bump.lines}>
              <polyline
                points={line.d}
                fill="none"
                stroke={"hsl(#{line.hue} 70% 50%)"}
                stroke-width="2.5"
                stroke-linejoin="round"
                stroke-linecap="round"
                opacity="0.9"
              />
              <circle
                :for={dot <- line.dots}
                cx={dot.cx}
                cy={dot.cy}
                r="4"
                fill={"hsl(#{line.hue} 70% 50%)"}
              >
                <title>
                  {line.name} — round {dot.round}: rank {dot.rank}, {round1(dot.points)} pts
                </title>
              </circle>
              <text
                class="chart-label"
                x={line.label_x}
                y={line.label_y + 4}
                fill={"hsl(#{line.hue} 70% 42%)"}
              >
                {line.name}
              </text>
            </g>
          </svg>
        </div>
      </div>

      <div class="card">
        <h2>Who played whom</h2>

        <p class="hint" style="margin-top: 0">
          Every player who has played a game, with a line for each meeting. A thicker line means
          they met more than once. Hover a line to see which rounds.
        </p>

        <p :if={is_nil(@network)} class="tl-empty" style="padding-left: 0">
          No games played yet.
        </p>

        <p :if={@network && @network.too_many} class="tl-empty" style="padding-left: 0">
          {@network.too_many} players is past the point where this graph tells you anything —
          every node would touch every other. The
          <.link navigate={~p"/t/#{@tournament.id}/pairings"}>Pairings</.link>
          page lists the games per round.
        </p>

        <div :if={@network && is_nil(@network.too_many)} class="chart-centre">
          <svg
            class="chart net"
            viewBox={"0 0 #{@network.size} #{@network.size}"}
            width={@network.size}
            height={@network.size}
            role="img"
            aria-label="Network of who played whom"
          >
            <g class="net-edges">
              <line
                :for={edge <- @network.edges}
                x1={edge.x1}
                y1={edge.y1}
                x2={edge.x2}
                y2={edge.y2}
                stroke-width={1 + (edge.count - 1) * 1.6}
              >
                <title>
                  {edge.a_name} vs {edge.b_name} — round {Enum.join(edge.rounds, ", ")}
                </title>
              </line>
            </g>

            <g :for={node <- @network.nodes}>
              <circle class="net-node" cx={node.x} cy={node.y} r={node.r}>
                <title>{node.name} — {node.games} game(s)</title>
              </circle>
              <text
                class="chart-label net-label"
                x={node.label_x}
                y={node.label_y + 3}
                text-anchor={node.anchor}
              >
                {node.name}
              </text>
            </g>
          </svg>
        </div>
      </div>

      <div class="card">
        <h2>What happened</h2>

        <p class="hint" style="margin-top: 0">
          Every change to this tournament, newest first, with the restore points
          <span class="tl-inline-diamond"></span>
          saved automatically before anything irreversible. {@event_count} change(s) and {@snapshot_count} restore point(s).
        </p>

        <div class="round-picker" style="flex-wrap: wrap; margin-bottom: 4px">
          <button
            :for={{key, label} <- filters()}
            type="button"
            class={["pe-btn", "filter-picker", @filter == key && "active"]}
            phx-click="filter"
            phx-value-kind={key}
          >
            {label}
          </button>
        </div>

        <p :if={@entries == []} class="tl-empty">
          Nothing here yet<%= if @filter != "all" do %>
            for this filter
          <% end %>.
        </p>

        <div :for={{date, day_entries} <- @days}>
          <div class="tl-day">{day_label(date)}</div>

          <ul class="tl">
            <li :for={entry <- day_entries} class="tl-item" data-kind={entry.kind} id={entry.id}>
              <span class="tl-dot"></span>

              <div class="tl-meta">
                <span class="tl-time">{time_label(entry.at)}</span>
                <span class="tl-who">{entry.who}</span>
                <span class="tl-tag">{entry.kind}</span>
              </div>

              <div class="tl-text">{entry.text}</div>

              <div :if={entry.diff != []} class="tl-diff">
                <div :for={row <- entry.diff} class="tl-diff-row">
                  <span class="tl-diff-field">{field_label(row.field)}</span>
                  <.diff_value value={row.before} side="before" />
                  <span class="tl-arrow" aria-label="changed to">→</span>
                  <.diff_value value={row.after} side="after" />
                </div>
              </div>
            </li>
          </ul>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :value, :any, required: true
  attr :side, :string, required: true

  defp diff_value(assigns) do
    {tone, text} = value_label(assigns.value)
    assigns = assign(assigns, tone: tone, text: text)

    ~H"""
    <span class={["tl-val", @side, @tone == :empty && "empty"]}>{@text}</span>
    """
  end
end
