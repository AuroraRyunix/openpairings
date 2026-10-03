defmodule PairingsEngineWeb.TeamSheetsLive do
  @moduledoc """
  The team tables beside the Standings page: the team cross table, the match
  result sheets, the rosters and the board prizes. One page, four tabs
  (`live_action`), each with its print button; the paper comes from
  `PairingsEngineWeb.TeamPrintController`, the numbers from
  `PairingsEngine.TeamSheets`, which reads `TeamStandings` and scores nothing
  itself. Read-only. A tournament that is not paired as teams is sent back to
  Standings.
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{Standings, TeamSheets, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  import PairingsEngine.TeamSheets, only: [points_text: 1]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if Tournament.paired_as_teams?(tournament) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(
          PairingsEngine.PubSub,
          Tournaments.tournament_topic(tournament.id)
        )
      end

      {:ok,
       socket
       |> assign(
         tournament: tournament,
         page_title: "#{tournament.name} · #{gettext("Team tables")}",
         round: nil,
         min_games: 1
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("This is not a team tournament."))
       |> push_navigate(to: ~p"/t/#{tournament.id}/standings")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    rounds_paired = Standings.rounds_paired(socket.assigns.tournament.id)

    round =
      case Integer.parse(params["round"] || "") do
        {n, ""} when n >= 1 and n <= rounds_paired -> n
        _ -> max(rounds_paired, 1)
      end

    min_games =
      case Integer.parse(params["min_games"] || "") do
        {n, ""} when n >= 1 -> n
        _ -> 1
      end

    {:noreply, socket |> assign(round: round, min_games: min_games) |> load()}
  end

  @impl true
  def handle_info({:tournament_changed, _tournament_id, _hint}, socket) do
    case Tournaments.get_authorized_tournament(
           socket.assigns.current_scope,
           socket.assigns.tournament.id
         ) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("This tournament was deleted."))
         |> push_navigate(to: ~p"/")}

      tournament ->
        {:noreply, socket |> assign(tournament: tournament) |> load()}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # Only the active tab's data is worked out.
  defp load(socket) do
    t = socket.assigns.tournament
    teams = t.id |> Tournaments.list_teams() |> Map.new(&{&1.id, &1})
    rounds_paired = Standings.rounds_paired(t.id)
    base = assign(socket, teams_by_id: teams, rounds_paired: rounds_paired)

    case socket.assigns.live_action do
      :cross_table ->
        assign(base, cross: TeamSheets.cross_table(t))

      :rosters ->
        assign(base, rosters: TeamSheets.rosters(t))

      :board_prizes ->
        assign(base, prizes: TeamSheets.board_prizes(t, min_games: socket.assigns.min_games))

      :match_sheets ->
        round = socket.assigns.round || max(rounds_paired, 1)

        sheets =
          case TeamSheets.match_sheets(t, round) do
            {:ok, data} -> data.sheets
            :error -> []
          end

        assign(base, sheets: sheets)
    end
  end

  ## ---------- render ----------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      update_notice={assigns[:update_notice]}
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
      tournament={@tournament}
      active="standings"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">{gettext("Team tables")}</p>
        </div>
        <div class="actions" style="margin: 0">
          <a
            :if={@rounds_paired > 0 or @live_action == :rosters}
            id="team-sheets-print"
            class="pe-btn"
            href={print_href(@live_action, @tournament, @round, @min_games)}
            target="_blank"
          >
            {gettext("Print")}
          </a>
        </div>
      </div>

      <.subnav tournament={@tournament} active={@live_action} />

      <div
        :if={@rounds_paired == 0 and @live_action != :rosters}
        id="team-sheets-empty"
        class="card empty"
      >
        <p>
          <strong>{gettext("No round has been paired yet.")}</strong>
          {gettext("These tables fill in as the rounds are paired.")}
        </p>
      </div>

      <.cross_table :if={@live_action == :cross_table and @rounds_paired > 0} cross={@cross} />
      <.rosters :if={@live_action == :rosters} rosters={@rosters} />
      <.board_prizes
        :if={@live_action == :board_prizes and @rounds_paired > 0}
        prizes={@prizes}
        teams_by_id={@teams_by_id}
        min_games={@min_games}
        tournament={@tournament}
      />
      <.match_sheets
        :if={@live_action == :match_sheets and @rounds_paired > 0}
        sheets={@sheets}
        round={@round}
        rounds_paired={@rounds_paired}
        tournament={@tournament}
      />
    </Layouts.app>
    """
  end

  defp print_href(:cross_table, t, _round, _min), do: ~p"/t/#{t.id}/print/team-crosstable"

  defp print_href(:match_sheets, t, round, _min),
    do: ~p"/t/#{t.id}/print/team-match-sheets?round=#{round || 1}"

  defp print_href(:rosters, t, _round, _min), do: ~p"/t/#{t.id}/print/team-rosters"

  defp print_href(:board_prizes, t, _round, min_games),
    do: ~p"/t/#{t.id}/print/board-prizes?min_games=#{min_games}"

  attr :tournament, :map, required: true
  attr :active, :atom, required: true

  defp subnav(assigns) do
    ~H"""
    <div id="team-sheets-nav" class="round-picker" style="flex-wrap: wrap; margin-bottom: 12px">
      <.link
        navigate={~p"/t/#{@tournament.id}/standings"}
        id="team-sheets-tab-standings"
        class="pe-btn filter-picker"
      >
        {gettext("Standings")}
      </.link>
      <.link
        navigate={~p"/t/#{@tournament.id}/team-sheets"}
        id="team-sheets-tab-cross-table"
        class={["pe-btn", "filter-picker", @active == :cross_table && "active"]}
      >
        {gettext("Cross table")}
      </.link>
      <.link
        navigate={~p"/t/#{@tournament.id}/team-sheets/match-sheets"}
        id="team-sheets-tab-match-sheets"
        class={["pe-btn", "filter-picker", @active == :match_sheets && "active"]}
      >
        {gettext("Match sheets")}
      </.link>
      <.link
        navigate={~p"/t/#{@tournament.id}/team-sheets/rosters"}
        id="team-sheets-tab-rosters"
        class={["pe-btn", "filter-picker", @active == :rosters && "active"]}
      >
        {gettext("Rosters")}
      </.link>
      <.link
        navigate={~p"/t/#{@tournament.id}/team-sheets/board-prizes"}
        id="team-sheets-tab-board-prizes"
        class={["pe-btn", "filter-picker", @active == :board_prizes && "active"]}
      >
        {gettext("Board prizes")}
      </.link>
    </div>
    """
  end

  ## ---------- cross table ----------

  attr :cross, :map, required: true

  defp cross_table(%{cross: %{kind: :round_robin}} = assigns) do
    ~H"""
    <div id="team-cross-table" class="card table-card">
      <table class="pe-table team-cross">
        <caption class="sr-only">{gettext("Team cross table")}</caption>
        <thead>
          <tr>
            <th scope="col" class="num">{gettext("No.")}</th>
            <th scope="col">{gettext("Team")}</th>
            <th :for={col <- @cross.teams} scope="col" class="num" title={col.team.name}>
              {col.number}
            </th>
            <th scope="col" class="num">MP</th>
            <th scope="col" class="num">GP</th>
            <th scope="col" class="num">{gettext("Rank")}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @cross.teams} id={"team-cross-row-#{row.team.id}"}>
            <td class="num">{row.number}</td>
            <td><strong>{row.team.name}</strong></td>
            <td
              :for={col <- @cross.teams}
              id={"team-cross-cell-#{row.team.id}-#{col.team.id}"}
              class={["num", col.team.id == row.team.id && "team-cross-diag"]}
            >
              <span :if={col.team.id != row.team.id}>{rr_cell(Map.get(row.cells, col.team.id, []))}</span>
            </td>
            <td class="num"><strong>{format_total(row.mp)}</strong></td>
            <td class="num"><strong>{format_total(row.gp)}</strong></td>
            <td class="num">{row.rank}</td>
          </tr>
        </tbody>
      </table>
    </div>
    <p class="hint">
      {gettext(
        "Each cell is the game points the row team scored against the column team; a dot is a match not yet played."
      )}
    </p>
    """
  end

  defp cross_table(%{cross: %{kind: :swiss}} = assigns) do
    ~H"""
    <div id="team-cross-table" class="card table-card">
      <table class="pe-table team-cross">
        <caption class="sr-only">{gettext("Team cross table")}</caption>
        <thead>
          <tr>
            <th scope="col" class="num">{gettext("Rank")}</th>
            <th scope="col" class="num">{gettext("No.")}</th>
            <th scope="col">{gettext("Team")}</th>
            <th :for={r <- 1..max(@cross.rounds, 1)} scope="col" class="num">R{r}</th>
            <th scope="col" class="num">MP</th>
            <th scope="col" class="num">GP</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @cross.rows} id={"team-cross-row-#{row.team.id}"}>
            <td class="num">{row.rank}</td>
            <td class="num">{row.number}</td>
            <td><strong>{row.team.name}</strong></td>
            <td
              :for={{cell, r} <- Enum.with_index(row.rounds, 1)}
              id={"team-cross-cell-#{row.team.id}-r#{r}"}
              class="num"
            >
              <.swiss_cell cell={cell} />
            </td>
            <td class="num"><strong>{format_total(row.mp)}</strong></td>
            <td class="num"><strong>{format_total(row.gp)}</strong></td>
          </tr>
        </tbody>
      </table>
    </div>
    <p class="hint">
      {gettext(
        "Per round: the opponent's number and the colour of board 1 (w or b), the game points of the match, and the team's running match points."
      )}
    </p>
    """
  end

  attr :cell, :map, default: nil

  defp swiss_cell(%{cell: nil} = assigns), do: ~H""

  defp swiss_cell(%{cell: %{bye?: true}} = assigns) do
    ~H"""
    <div><strong>{gettext("bye")}</strong></div>
    <small class="hint">MP {format_total(@cell.mp_total)}</small>
    """
  end

  defp swiss_cell(assigns) do
    ~H"""
    <div>
      <strong>{@cell.opponent_number} {if @cell.colour == :white, do: "w", else: "b"}</strong>
    </div>
    <div :if={@cell.gp}>{points_text(@cell.gp)}-{points_text(@cell.opp_gp)}</div>
    <small :if={@cell.mp} class="hint">MP {format_total(@cell.mp_total)}</small>
    """
  end

  defp rr_cell([]), do: "·"

  defp rr_cell(meetings) do
    meetings
    |> Enum.sort_by(& &1.round)
    |> Enum.map_join(" / ", fn c -> if c.gp, do: points_text(c.gp), else: "·" end)
  end

  defp format_total(nil), do: "-"
  defp format_total(v), do: points_text(v * 1.0)

  ## ---------- rosters ----------

  attr :rosters, :list, required: true

  defp rosters(assigns) do
    ~H"""
    <div :if={@rosters == []} class="card empty">
      <p>
        <strong>{gettext("No teams yet.")}</strong>
      </p>
    </div>

    <div :for={r <- @rosters} id={"roster-#{r.team.id}"} class="card table-card">
      <h2 style="margin: 12px 12px 0">
        {r.number}. {r.team.name}
        <small :if={r.team.captain != ""} class="hint">
          · {gettext("Captain: %{name}", name: r.team.captain)}
        </small>
      </h2>
      <table class="pe-table">
        <thead>
          <tr>
            <th scope="col" class="num">{gettext("Bd")}</th>
            <th scope="col">{gettext("Title")}</th>
            <th scope="col">{gettext("Name")}</th>
            <th scope="col" class="num">Elo</th>
            <th scope="col" class="num">FIDE ID</th>
            <th scope="col">{gettext("Fed.")}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={%{board: k, player: p} <- r.players}>
            <td class="num">{k}</td>
            <td>{p.title}</td>
            <td>
              <strong>{p.name}</strong>
              <span :if={p.status != "active"} class="hint">({p.status})</span>
            </td>
            <td class="num">{rating(p)}</td>
            <td class="num">{p.fide_id}</td>
            <td>{p.federation}</td>
          </tr>
          <tr :if={r.players == []}>
            <td colspan="6" class="hint">{gettext("No players on this team yet.")}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp rating(player) do
    case Player.rating(player) do
      0 -> ""
      n -> n
    end
  end

  ## ---------- board prizes ----------

  attr :prizes, :list, required: true
  attr :teams_by_id, :map, required: true
  attr :min_games, :integer, required: true
  attr :tournament, :map, required: true

  defp board_prizes(assigns) do
    ~H"""
    <form
      id="board-prizes-filter"
      method="get"
      action={~p"/t/#{@tournament.id}/team-sheets/board-prizes"}
      class="card"
      style="margin-bottom: 12px; display: flex; align-items: center; gap: 10px; flex-wrap: wrap"
    >
      <label for="board-prizes-min-games" class="set-label" style="margin: 0">
        {gettext("Minimum games")}
      </label>
      <input
        id="board-prizes-min-games"
        type="number"
        name="min_games"
        min="1"
        value={@min_games}
        style="width: 80px"
      />
      <button type="submit" class="pe-btn">{gettext("Apply")}</button>
    </form>

    <div :if={@prizes == []} id="board-prizes-empty" class="card empty">
      <p><strong>{gettext("No board results yet.")}</strong></p>
    </div>

    <div :for={b <- @prizes} id={"board-prize-#{b.board}"} class="card table-card">
      <h2 style="margin: 12px 12px 0">{gettext("Board %{n}", n: b.board)}</h2>
      <table class="pe-table">
        <thead>
          <tr>
            <th scope="col" class="num">#</th>
            <th scope="col">{gettext("Name")}</th>
            <th scope="col">{gettext("Team")}</th>
            <th scope="col" class="num">{gettext("Games")}</th>
            <th scope="col" class="num">Pts</th>
            <th scope="col" class="num">%</th>
            <th scope="col" class="num" title={gettext("Performance rating over games played")}>
              {gettext("Perf")}
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :for={%{rank: rank, stat: s} <- b.rows}>
            <td class="num">{rank}</td>
            <td><strong>{s.player.name}</strong></td>
            <td>{team_name(@teams_by_id, s.team_id)}</td>
            <td class="num">{s.games}</td>
            <td class="num">{points_text(s.points)}</td>
            <td class="num">{if s.percentage, do: s.percentage, else: "-"}</td>
            <td class="num">{s.performance || "-"}</td>
          </tr>
        </tbody>
      </table>
    </div>

    <p class="hint">
      {gettext(
        "Ranked by percentage, then points, then performance. A player is listed under the board they sat at most often."
      )}
    </p>
    """
  end

  defp team_name(teams, id) do
    case Map.get(teams, id) do
      nil -> "-"
      team -> team.name
    end
  end

  ## ---------- match sheets ----------

  attr :sheets, :list, required: true
  attr :round, :integer, required: true
  attr :rounds_paired, :integer, required: true
  attr :tournament, :map, required: true

  defp match_sheets(assigns) do
    ~H"""
    <div id="match-sheets-rounds" class="round-picker" style="margin-bottom: 12px">
      <.link
        :for={n <- 1..@rounds_paired}
        patch={~p"/t/#{@tournament.id}/team-sheets/match-sheets?round=#{n}"}
        id={"match-sheets-round-#{n}"}
        class={["pe-btn", n == @round && "active"]}
      >
        {n}
      </.link>
    </div>

    <div :if={@sheets == []} id="match-sheets-empty" class="card empty">
      <p><strong>{gettext("Round %{n} has no team matches", n: @round)}</strong></p>
    </div>

    <div :if={@sheets != []} id="match-sheets" class="card table-card">
      <table class="pe-table">
        <thead>
          <tr>
            <th scope="col" class="num">{gettext("Match")}</th>
            <th scope="col">{gettext("Teams")}</th>
            <th scope="col" class="num">{gettext("Score")}</th>
            <th scope="col"><span class="sr-only">{gettext("Actions")}</span></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={s <- @sheets} id={"match-sheet-row-#{s.match.match_id}"}>
            <td class="num">{s.number}</td>
            <td>
              <strong>{s.team_a.name}</strong> - <strong>{s.team_b.name}</strong>
            </td>
            <td class="num">
              <span :if={Enum.any?(s.rows, &(&1.result != ""))}>
                {points_text(s.match.gp_a)} - {points_text(s.match.gp_b)}
              </span>
            </td>
            <td style="text-align: right">
              <a
                id={"match-sheet-print-#{s.match.match_id}"}
                class="pe-btn"
                href={
                  ~p"/t/#{@tournament.id}/print/team-match-sheets?round=#{@round}&match=#{s.match.match_id}"
                }
                target="_blank"
              >
                {gettext("Print sheet")}
              </a>
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <p class="hint">
      {gettext(
        "One A4 sheet per match: both line-ups with colours and ratings, a box for each board's result, the match score, and lines for the captains and the arbiter. Results already entered are filled in. The Print button above prints every match of this round."
      )}
    </p>
    """
  end
end
