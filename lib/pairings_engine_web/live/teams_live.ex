defmodule PairingsEngineWeb.TeamsLive do
  @moduledoc """
  The Teams page (`/t/:id/teams`) of a team tournament: create, rename and
  delete teams, put players on a team, set the board order, and set the
  teams' seeding order before the draw is frozen. See
  `docs/team-tournaments.md`.

  Plain buttons rather than drag and drop, so every action is one keyboard
  press away and a screen reader announces what each does ("Move Anna to a
  higher board"). The result of every action is read out through the
  `role="status"` line at the top.
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport, only: [error_text: 1]

  alias PairingsEngine.{Audit, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Team, Tournament}

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
       page_title: gettext("%{name} · Teams", name: tournament.name),
       note: nil,
       error: nil
     )
     |> load()}
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
         |> put_flash(:error, gettext("This tournament was deleted."))
         |> push_navigate(to: ~p"/")}

      tournament ->
        {:noreply, socket |> assign(tournament: tournament) |> load()}
    end
  end

  defp load(socket) do
    t = socket.assigns.tournament
    teams = Tournaments.list_teams(t.id)
    players = Tournaments.list_players(t.id)
    rosters = players |> Enum.filter(& &1.team_id) |> Enum.group_by(& &1.team_id)

    assign(socket,
      teams: teams,
      rosters: Map.new(rosters, fn {id, ps} -> {id, Tournaments.sort_roster(ps)} end),
      unassigned: players |> Enum.reject(& &1.team_id) |> Enum.sort_by(& &1.name),
      frozen?: Tournaments.teams_frozen?(t.id),
      boards_locked?: :team_boards in Tournaments.locked_fields(t),
      writable?: Tournaments.ensure_writable(t) == :ok
    )
  end

  ## ---------- events ----------

  @impl true
  def handle_event("create_team", %{"team" => params}, socket) when is_map(params) do
    attrs = Map.take(params, ~w(name short_name captain))

    case Tournaments.create_team(socket.assigns.tournament, attrs) do
      {:ok, team} ->
        Audit.log(socket.assigns.tournament.id, socket.assigns.current_scope, "team.created", %{
          team_name: team.name
        })

        {:noreply, socket |> ok(gettext("Team %{name} added.", name: team.name)) |> load()}

      {:error, reason} ->
        {:noreply, fail(socket, reason)}
    end
  end

  def handle_event("update_team", %{"team_id" => id, "team" => params}, socket)
      when is_map(params) do
    with %Team{} = team <- team(socket, id),
         {:ok, updated} <-
           Tournaments.update_team(team, Map.take(params, ~w(name short_name captain))) do
      Audit.log(socket.assigns.tournament.id, socket.assigns.current_scope, "team.updated", %{
        team_name: updated.name,
        previous_name: team.name
      })

      {:noreply, socket |> ok(gettext("Team %{name} saved.", name: updated.name)) |> load()}
    else
      nil -> {:noreply, socket}
      {:error, reason} -> {:noreply, fail(socket, reason)}
    end
  end

  def handle_event("delete_team", %{"team_id" => id}, socket) do
    with %Team{} = team <- team(socket, id),
         {:ok, _} <- Tournaments.delete_team(team) do
      Audit.log(socket.assigns.tournament.id, socket.assigns.current_scope, "team.deleted", %{
        team_name: team.name
      })

      {:noreply, socket |> ok(gettext("Team %{name} deleted.", name: team.name)) |> load()}
    else
      nil -> {:noreply, socket}
      {:error, reason} -> {:noreply, fail(socket, reason)}
    end
  end

  def handle_event("move_team", %{"team_id" => id, "direction" => dir}, socket)
      when dir in ["up", "down"] do
    with %Team{} = team <- team(socket, id),
         {:ok, _} <- Tournaments.move_team(socket.assigns.tournament, team, direction(dir)) do
      Audit.log(
        socket.assigns.tournament.id,
        socket.assigns.current_scope,
        "team.seeding_changed",
        %{team_name: team.name, direction: dir}
      )

      {:noreply, socket |> ok(moved_team_note(team, dir)) |> load()}
    else
      nil -> {:noreply, socket}
      {:error, reason} -> {:noreply, fail(socket, reason)}
    end
  end

  def handle_event("seed_by_rating", _params, socket) do
    case Tournaments.seed_teams_by_rating(socket.assigns.tournament) do
      {:ok, _} ->
        Audit.log(
          socket.assigns.tournament.id,
          socket.assigns.current_scope,
          "team.seeding_changed",
          %{by_rating: true}
        )

        {:noreply, socket |> ok(gettext("Teams ordered by rating.")) |> load()}

      {:error, reason} ->
        {:noreply, fail(socket, reason)}
    end
  end

  def handle_event("add_player", %{"team_id" => team_id, "player_id" => player_id}, socket) do
    with %Team{} = team <- team(socket, team_id),
         %Player{} = player <- Tournaments.get_player(socket.assigns.tournament.id, player_id),
         {:ok, _} <- Tournaments.set_player_team(socket.assigns.tournament, player, team) do
      Audit.log(
        socket.assigns.tournament.id,
        socket.assigns.current_scope,
        "team.player_assigned",
        %{player_name: player.name, team_name: team.name}
      )

      {:noreply,
       socket
       |> ok(gettext("%{player} added to %{team}.", player: player.name, team: team.name))
       |> load()}
    else
      nil -> {:noreply, socket}
      {:error, reason} -> {:noreply, fail(socket, reason)}
    end
  end

  def handle_event("remove_player", %{"player_id" => player_id}, socket) do
    with %Player{team_id: team_id} = player when not is_nil(team_id) <-
           Tournaments.get_player(socket.assigns.tournament.id, player_id),
         team = Enum.find(socket.assigns.teams, &(&1.id == team_id)),
         {:ok, _} <- Tournaments.set_player_team(socket.assigns.tournament, player, nil) do
      Audit.log(
        socket.assigns.tournament.id,
        socket.assigns.current_scope,
        "team.player_removed",
        %{
          player_name: player.name,
          team_name: team && team.name
        }
      )

      {:noreply,
       socket |> ok(gettext("%{player} taken off the team.", player: player.name)) |> load()}
    else
      {:error, reason} -> {:noreply, fail(socket, reason)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("move_player", %{"player_id" => player_id, "direction" => dir}, socket)
      when dir in ["up", "down"] do
    with %Player{} = player <- Tournaments.get_player(socket.assigns.tournament.id, player_id),
         {:ok, _} <-
           Tournaments.move_player_board(socket.assigns.tournament, player, direction(dir)) do
      Audit.log(
        socket.assigns.tournament.id,
        socket.assigns.current_scope,
        "team.board_order_changed",
        %{player_name: player.name, direction: dir}
      )

      {:noreply, socket |> ok(moved_player_note(player, dir)) |> load()}
    else
      nil -> {:noreply, socket}
      {:error, reason} -> {:noreply, fail(socket, reason)}
    end
  end

  def handle_event("save_boards", %{"tournament" => %{"team_boards" => boards}}, socket) do
    base = socket.assigns.tournament

    case Tournaments.update_tournament(base, %{"team_boards" => boards}) do
      {:ok, tournament} ->
        if tournament.team_boards != base.team_boards do
          Audit.log(tournament.id, socket.assigns.current_scope, "tournament.settings_updated", %{
            changed_fields: %{"team_boards" => [base.team_boards, tournament.team_boards]}
          })
        end

        {:noreply,
         socket
         |> assign(tournament: tournament)
         |> ok(gettext("Boards per match saved."))
         |> load()}

      {:error, reason} ->
        {:noreply, fail(socket, reason)}
    end
  end

  # Anything else - a missing key, a crafted value - is a no-op, not a crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp team(socket, id), do: Tournaments.get_team(socket.assigns.tournament.id, id)

  defp direction("up"), do: :up
  defp direction("down"), do: :down

  defp ok(socket, note), do: assign(socket, note: note, error: nil)

  defp fail(socket, reason), do: assign(socket, error: refusal(reason), note: nil)

  defp refusal(:team_scheduled),
    do:
      gettext(
        "This team is in the schedule. Unpair every round on the Pairings page before deleting it."
      )

  defp refusal(:teams_frozen),
    do:
      gettext(
        "The teams' order became their pairing numbers when round 1 was paired, and the schedule was built from it. Unpair every round to change it."
      )

  defp refusal(:not_found), do: gettext("That team or player is not in this tournament.")

  defp refusal(:locked_after_pairing),
    do: gettext("Boards per match cannot change once round 1 is paired.")

  defp refusal(reason), do: error_text(reason)

  defp moved_team_note(team, "up"), do: gettext("%{team} moved up.", team: team.name)
  defp moved_team_note(team, "down"), do: gettext("%{team} moved down.", team: team.name)

  defp moved_player_note(player, "up"),
    do: gettext("%{player} moved to a higher board.", player: player.name)

  defp moved_player_note(player, "down"),
    do: gettext("%{player} moved to a lower board.", player: player.name)

  defp rating(player) do
    case Player.rating(player) do
      0 -> "-"
      r -> r
    end
  end

  ## ---------- rendering ----------

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
      active="teams"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">{gettext("Teams")}</p>
        </div>
      </div>

      <p role="status" aria-live="polite" class={@note && "ok-note"}>{@note}</p>
      <p :if={@error} role="alert" class="error-note">{@error}</p>

      <div :if={!Tournament.team?(@tournament)} class="card">
        <h2>{gettext("Not a team tournament")}</h2>
        <p class="hint">
          {gettext(
            "Teams are for team tournaments. This tournament pairs players individually; choose a team format when creating a tournament to use this page."
          )}
        </p>
      </div>

      <%= if Tournament.team?(@tournament) do %>
        <div :if={!Tournament.team_round_robin?(@tournament)} class="card">
          <h2>{gettext("Team Swiss is not paired by team yet")}</h2>
          <p class="hint">
            {gettext(
              "Teams and board orders can be set up here, but a team Swiss still pairs players one by one: the FIDE team Swiss system (C.04.6) is not wired in yet. A team round robin pairs team against team."
            )}
          </p>
        </div>

        <div class="card">
          <h2>{gettext("Matches")}</h2>
          <form id="team-boards-form" phx-submit="save_boards">
            <label class="field">
              <span>{gettext("Boards per match")}</span>
              <input
                type="number"
                min="1"
                max={Tournament.max_team_boards()}
                name="tournament[team_boards]"
                value={@tournament.team_boards}
                disabled={@boards_locked? or !@writable?}
              />
            </label>
            <p class="hint">
              {gettext(
                "Board 1 of the first-named team plays White, and colours alternate down the boards. Match points for a won, drawn and lost match are set under Settings - Scoring."
              )}
            </p>
            <button
              :if={!@boards_locked? and @writable?}
              type="submit"
              class="pe-btn primary"
            >
              {gettext("Save boards per match")}
            </button>
            <p :if={@boards_locked?} class="hint">
              {gettext("Locked: round 1 has been paired.")}
            </p>
          </form>
        </div>

        <div :if={@writable?} class="card">
          <h2>{gettext("Add a team")}</h2>
          <form id="create-team-form" phx-submit="create_team" class="form-grid">
            <label class="field">
              <span>{gettext("Team name")}</span>
              <input type="text" name="team[name]" required maxlength="100" />
            </label>
            <label class="field">
              <span>{gettext("Short name")}</span>
              <input type="text" name="team[short_name]" maxlength="12" />
            </label>
            <label class="field">
              <span>{gettext("Captain")}</span>
              <input type="text" name="team[captain]" maxlength="100" />
            </label>
            <div class="actions">
              <button type="submit" class="pe-btn primary">{gettext("Add team")}</button>
            </div>
          </form>
        </div>

        <div class="card">
          <h2>{gettext("Order of the teams")}</h2>
          <p class="hint">
            {if @frozen?,
              do:
                gettext(
                  "Frozen: the order below became the teams' pairing numbers when round 1 was paired."
                ),
              else:
                gettext(
                  "The order below becomes the teams' pairing numbers when round 1 is paired. Set it by your competition's rules, or order the teams by the average rating of their first boards."
                )}
          </p>
          <button
            :if={!@frozen? and @writable? and length(@teams) > 1}
            type="button"
            class="pe-btn"
            phx-click="seed_by_rating"
          >
            {gettext("Order by rating")}
          </button>
          <p :if={@teams == []} class="hint">{gettext("No teams yet.")}</p>
        </div>

        <section
          :for={{team, index} <- Enum.with_index(@teams, 1)}
          id={"team-#{team.id}"}
          class="card"
          aria-labelledby={"team-heading-#{team.id}"}
        >
          <h2 id={"team-heading-#{team.id}"}>
            {team.pairing_number || index}. {team.name}
            <span :if={team.short_name != ""} class="hint">({team.short_name})</span>
          </h2>
          <p :if={team.captain != ""} class="hint">
            {gettext("Captain: %{name}", name: team.captain)}
          </p>

          <div :if={@writable?} class="actions">
            <button
              :if={!@frozen?}
              type="button"
              class="pe-btn"
              phx-click="move_team"
              phx-value-team_id={team.id}
              phx-value-direction="up"
              disabled={index == 1}
              aria-label={gettext("Move %{team} up the order", team: team.name)}
            >
              ↑
            </button>
            <button
              :if={!@frozen?}
              type="button"
              class="pe-btn"
              phx-click="move_team"
              phx-value-team_id={team.id}
              phx-value-direction="down"
              disabled={index == length(@teams)}
              aria-label={gettext("Move %{team} down the order", team: team.name)}
            >
              ↓
            </button>
            <button
              :if={is_nil(team.pairing_number)}
              type="button"
              class="pe-btn danger"
              phx-click="delete_team"
              phx-value-team_id={team.id}
              data-confirm={
                gettext("Delete %{team}? Its players stay in the tournament.", team: team.name)
              }
              aria-label={gettext("Delete %{team}", team: team.name)}
            >
              {gettext("Delete")}
            </button>
          </div>

          <details :if={@writable?}>
            <summary>
              {gettext("Rename")}<span class="sr-only">{gettext(" %{team}", team: team.name)}</span>
            </summary>
            <form
              id={"edit-team-#{team.id}"}
              phx-submit="update_team"
              class="form-grid"
            >
              <input type="hidden" name="team_id" value={team.id} />
              <label class="field">
                <span>{gettext("Team name")}</span>
                <input type="text" name="team[name]" value={team.name} required maxlength="100" />
              </label>
              <label class="field">
                <span>{gettext("Short name")}</span>
                <input type="text" name="team[short_name]" value={team.short_name} maxlength="12" />
              </label>
              <label class="field">
                <span>{gettext("Captain")}</span>
                <input type="text" name="team[captain]" value={team.captain} maxlength="100" />
              </label>
              <div class="actions">
                <button type="submit" class="pe-btn primary">{gettext("Save team")}</button>
              </div>
            </form>
          </details>

          <% roster = Map.get(@rosters, team.id, []) %>
          <p :if={roster == []} class="hint">{gettext("No players on this team yet.")}</p>
          <table :if={roster != []} class="pe-table">
            <caption class="sr-only">{gettext("Board order of %{team}", team: team.name)}</caption>
            <thead>
              <tr>
                <th scope="col" class="num">{gettext("Board")}</th>
                <th scope="col">{gettext("Name")}</th>
                <th scope="col" class="num">Elo</th>
                <th :if={@writable?} scope="col">
                  <span class="sr-only">{gettext("Actions")}</span>
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{player, board} <- Enum.with_index(roster, 1)}>
                <td class="num">{board}</td>
                <td>
                  <strong>{player.name}</strong>
                  <span :if={board > @tournament.team_boards} class="hint">
                    {gettext("reserve")}
                  </span>
                </td>
                <td class="num">{rating(player)}</td>
                <td :if={@writable?} style="text-align: right; white-space: nowrap">
                  <button
                    type="button"
                    class="pe-btn"
                    phx-click="move_player"
                    phx-value-player_id={player.id}
                    phx-value-direction="up"
                    disabled={board == 1}
                    aria-label={gettext("Move %{player} to a higher board", player: player.name)}
                  >
                    ↑
                  </button>
                  <button
                    type="button"
                    class="pe-btn"
                    phx-click="move_player"
                    phx-value-player_id={player.id}
                    phx-value-direction="down"
                    disabled={board == length(roster)}
                    aria-label={gettext("Move %{player} to a lower board", player: player.name)}
                  >
                    ↓
                  </button>
                  <button
                    type="button"
                    class="pe-btn"
                    phx-click="remove_player"
                    phx-value-player_id={player.id}
                    aria-label={
                      gettext("Take %{player} off %{team}", player: player.name, team: team.name)
                    }
                  >
                    {gettext("Remove")}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>

          <form
            :if={@writable? and @unassigned != []}
            id={"add-player-#{team.id}"}
            phx-submit="add_player"
            class="actions"
          >
            <input type="hidden" name="team_id" value={team.id} />
            <label class="field" style="margin: 0">
              <span>{gettext("Add a player to %{team}", team: team.name)}</span>
              <select name="player_id">
                <option :for={p <- @unassigned} value={p.id}>{p.name} ({rating(p)})</option>
              </select>
            </label>
            <button type="submit" class="pe-btn">{gettext("Add player")}</button>
          </form>
        </section>

        <div :if={@unassigned != [] and @teams != []} class="card">
          <h2>{gettext("Players without a team")}</h2>
          <p class="hint">
            {gettext("These players are not on any team and are not paired in a team match.")}
          </p>
          <ul>
            <li :for={p <- @unassigned}>{p.name}</li>
          </ul>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
