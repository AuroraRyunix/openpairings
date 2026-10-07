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

  Each team shows its rating (`Tournaments.team_rating/3`, by the
  tournament's `team_rating_method`), which can be typed in by hand
  (`teams.rating_override`), and the rounds it sits out as a team
  (`Tournaments.set_team_absent/4`).
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport, only: [error_text: 1]

  alias PairingsEngine.{Audit, Plugins, TeamStandings, Tournaments}
  alias PairingsEngine.Pairing, as: Engine
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
      colours_locked?: :team_board_colours in Tournaments.locked_fields(t),
      roster_locked?: Tournaments.roster_locked?(t),
      roster_warning?: Tournaments.roster_change_warning?(t),
      seated: Tournaments.seated_player_ids(t.id),
      deletable: teams |> Enum.filter(&Tournaments.team_deletable?/1) |> MapSet.new(& &1.id),
      withdraw_from: withdraw_defaults(t, teams),
      writable?: Tournaments.ensure_writable(t) == :ok,
      ratings:
        Map.new(teams, fn team ->
          roster = Tournaments.sort_roster(Map.get(rosters, team.id, []))
          {team.id, Tournaments.team_rating_display(t, team, roster)}
        end),
      paired: Engine.paired_rounds_count(t.id),
      # What a plugin can put on each team's roster from its own data
      # (`PairingsEngine.Plugins.roster_candidates/3`); empty without one.
      roster_sources:
        if(Plugins.any?(),
          do:
            Map.new(teams, fn team ->
              {team.id, Plugins.roster_candidates(socket.assigns.current_scope, t, team)}
            end),
          else: %{}
        )
    )
  end

  # The round a withdrawal starts from by default, per team: the first round
  # its match has no complete result in, else the next round to pair - never
  # past the last round. Only worked out once round 1 is paired.
  defp withdraw_defaults(t, teams) do
    if Tournaments.teams_frozen?(t.id) and Tournament.paired_as_teams?(t) do
      matches = TeamStandings.matches(t)
      next = min(Engine.paired_rounds_count(t.id) + 1, t.rounds_count)

      Map.new(teams, fn team ->
        open =
          matches
          |> Enum.filter(&(team.id in [&1.team_a_id, &1.team_b_id] and not &1.scored?))
          |> Enum.map(& &1.round)
          |> Enum.min(fn -> next end)

        {team.id, min(open, next)}
      end)
    else
      %{}
    end
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
           Tournaments.update_team(
             team,
             Map.take(params, ~w(name short_name captain rating_override))
           ) do
      Audit.log(socket.assigns.tournament.id, socket.assigns.current_scope, "team.updated", %{
        team_name: updated.name,
        previous_name: team.name,
        rating_override: updated.rating_override
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

  def handle_event(
        "set_team_absent",
        %{"team_id" => id, "round" => round, "absent" => absent},
        socket
      ) do
    t = socket.assigns.tournament
    absent? = absent == "true"

    with %Team{} = team <- team(socket, id),
         {number, ""} <- Integer.parse(to_string(round)),
         {:ok, _} <- Tournaments.set_team_absent(t, team, number, absent?) do
      Audit.log(t.id, socket.assigns.current_scope, "team.absence_changed", %{
        team_name: team.name,
        round: number,
        absent: absent?
      })

      note =
        if absent?,
          do: gettext("%{team} is absent in round %{round}.", team: team.name, round: number),
          else: gettext("%{team} plays round %{round}.", team: team.name, round: number)

      {:noreply, socket |> ok(note) |> load()}
    else
      nil -> {:noreply, socket}
      {:error, reason} -> {:noreply, fail(socket, reason)}
      _ -> {:noreply, fail(socket, :bad_round)}
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

  def handle_event("fill_roster", %{"team_id" => team_id, "source" => source}, socket) do
    t = socket.assigns.tournament

    with %Team{} = team <- team(socket, team_id),
         {plugin, label, candidates} <-
           socket.assigns.current_scope
           |> Plugins.roster_candidates(t, team)
           |> Enum.find(fn {plugin, _label, _} -> plugin.id() == source end),
         {:ok, added} <- Plugins.add_to_roster(t, team, candidates) do
      Audit.log(t.id, socket.assigns.current_scope, "team.roster_filled", %{
        team_name: team.name,
        source: plugin.name(),
        count: added
      })

      {:noreply,
       socket
       |> ok(
         ngettext(
           "%{count} player from %{source} added to %{team}.",
           "%{count} players from %{source} added to %{team}.",
           added,
           source: label,
           team: team.name
         )
       )
       |> load()}
    else
      nil -> {:noreply, load(socket)}
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

  def handle_event("save_boards", %{"tournament" => params}, socket) when is_map(params) do
    base = socket.assigns.tournament
    attrs = Map.take(params, ~w(team_boards team_board_colours))

    case Tournaments.update_tournament(base, attrs) do
      {:ok, tournament} ->
        changed =
          for field <- [:team_boards, :team_board_colours],
              Map.get(base, field) != Map.get(tournament, field),
              into: %{},
              do: {Atom.to_string(field), [Map.get(base, field), Map.get(tournament, field)]}

        if changed != %{} do
          Audit.log(tournament.id, socket.assigns.current_scope, "tournament.settings_updated", %{
            changed_fields: changed
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

  # A team withdraws from round `from` on: every player withdrawn, its later
  # matches already paired forfeited to the opponents
  # (`Tournaments.withdraw_team/3`). A restore point first, as for any
  # action that rewrites several results at once.
  def handle_event("withdraw_team", %{"team_id" => id, "from_round" => from}, socket) do
    t = socket.assigns.tournament

    with %Team{} = team <- team(socket, id),
         {from, ""} <- Integer.parse(to_string(from)) do
      PairingsEngine.Snapshots.capture(t, "team.withdrawn", socket.assigns.current_scope,
        summary: "Before withdrawing #{team.name}"
      )

      case Tournaments.withdraw_team(t, team, from) do
        {:ok, %{forfeited: forfeited}} ->
          Audit.log(t.id, socket.assigns.current_scope, "team.withdrawn", %{
            team_name: team.name,
            from_round: from,
            matches_forfeited: length(forfeited)
          })

          {:noreply,
           socket
           |> ok(gettext("%{team} withdrawn from round %{round}.", team: team.name, round: from))
           |> load()}

        {:error, reason} ->
          {:noreply, fail(socket, reason)}
      end
    else
      nil -> {:noreply, socket}
      _ -> {:noreply, fail(socket, :bad_round)}
    end
  end

  def handle_event("reinstate_team", %{"team_id" => id}, socket) do
    t = socket.assigns.tournament

    with %Team{} = team <- team(socket, id),
         {:ok, _} <- Tournaments.reinstate_team(t, team) do
      Audit.log(t.id, socket.assigns.current_scope, "team.reinstated", %{team_name: team.name})

      {:noreply,
       socket |> ok(gettext("%{team} is back in the event.", team: team.name)) |> load()}
    else
      nil -> {:noreply, socket}
      {:error, reason} -> {:noreply, fail(socket, reason)}
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
        "This team is in the round-robin schedule, which was drawn over every team when round 1 was paired. Unpair every round on the Pairings page before deleting it, or withdraw it instead."
      )

  defp refusal(:team_played),
    do:
      gettext(
        "This team is in a match already paired, so deleting it would leave that match without a team. Withdraw it instead, or unpair the rounds it is in first."
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

  defp roster_confirm,
    do:
      gettext(
        "Round 1 is paired. Change the roster anyway? Rounds paired from now on use the new order; the TRF report lists one board order per team."
      )

  defp team_rating_method_text("first_boards"),
    do:
      gettext(
        "Team rating: the average rating of the players on its first boards, in board order (Settings - Options - Teams)."
      )

  defp team_rating_method_text("roster"),
    do:
      gettext(
        "Team rating: the average rating of every player on its roster (Settings - Options - Teams)."
      )

  defp team_rating_method_text("manual"),
    do: gettext("Team rating: typed in for each team, under Rename (Settings - Options - Teams).")

  defp team_rating_method_text(_olympiad),
    do:
      gettext(
        "Team rating: the average rating of its highest-rated players, one per board, as at the Chess Olympiad; the next player's rating, then the name, break a tie (Settings - Options - Teams). A rating typed in for a team is used instead."
      )

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
          <p class="subtitle" style="margin: 0">
            {gettext("Teams")} <PairingsEngineWeb.Components.ManualLink.manual_link topic={:teams} />
          </p>
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
        <div
          :if={
            !Tournament.paired_as_teams?(@tournament) and @tournament.type == "team-swiss" and
              @tournament.pairing_system == "swiss"
          }
          class="card"
        >
          <h2>{gettext("This team Swiss pairs player by player")}</h2>
          <p class="hint">
            {gettext(
              "Its rounds were paired player by player before team pairing (FIDE C.04.6) was available, so it carries on that way: switching mid-event would pair teams from a history the team rules never saw. Unpair every round and it pairs team against team from round 1."
            )}
          </p>
        </div>

        <div
          :if={
            !Tournament.paired_as_teams?(@tournament) and
              !(@tournament.type == "team-swiss" and @tournament.pairing_system == "swiss")
          }
          class="card"
        >
          <h2>{gettext("Not paired by team")}</h2>
          <p class="hint">
            {gettext(
              "Teams and board orders can be set up here, but this tournament pairs players one by one. A team round robin or a team Swiss pairs team against team."
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
            <label class="field">
              <span>{gettext("Board colours")}</span>
              <select
                id="team-board-colours"
                name="tournament[team_board_colours]"
                disabled={@colours_locked? or !@writable?}
              >
                <option value="fide" selected={@tournament.team_board_colours == "fide"}>
                  {gettext("FIDE: the team named first has White on the odd boards")}
                </option>
                <option value="home" selected={@tournament.team_board_colours == "home"}>
                  {gettext("League: the home team has White on the odd boards")}
                </option>
              </select>
            </label>
            <p class="hint">
              {gettext(
                "Board 1 of the first-named team plays White, and colours alternate down the boards - the rule of FIDE team events. With league colours the first-named team is the home team, and home and away can be swapped on a match's page before it starts. Match points for a won, drawn and lost match are set under Settings - Scoring."
              )}
            </p>
            <button
              :if={!(@boards_locked? and @colours_locked?) and @writable?}
              type="submit"
              class="pe-btn primary"
            >
              {gettext("Save match settings")}
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

        <div :if={@roster_locked?} id="roster-locked-note" class="card">
          <h2>{gettext("Rosters are fixed")}</h2>
          <p class="hint">
            {gettext(
              "FIDE mode: round 1 is paired, so each team's board order is fixed, as FIDE team events require. Players cannot move up or down, change team or leave a team they have played for. A new player can still be added at the bottom of a team, as a reserve."
            )}
          </p>
        </div>

        <div :if={@roster_warning?} id="roster-change-warning" class="card" role="note">
          <h2 class="pe-modal-warn">{gettext("Round 1 is paired")}</h2>
          <p class="hint">
            {gettext(
              "Rosters and board orders can still change, because this tournament is not in FIDE mode - but FIDE team events fix them before the start. A change affects the line-ups of rounds paired from now on; rounds already played keep who played for whom. The TRF report lists one board order per team, so a reordered team's earlier rounds may not rebuild as matches when the file is imported again."
            )}
          </p>
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
                  "The order below becomes the teams' pairing numbers when round 1 is paired. Set it by your competition's rules with the arrows, or order the teams by rating. Teams nobody has moved by hand are ordered by rating when round 1 is paired."
                )}
          </p>
          <p id="team-rating-method" class="hint">
            {team_rating_method_text(@tournament.team_rating_method)}
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
          <p id={"team-rating-#{team.id}"} class="hint">
            <%= case @ratings[team.id] do %>
              <% nil -> %>
                {gettext("Team rating: none")}
              <% rating -> %>
                {gettext("Team rating: %{rating}", rating: rating)}
            <% end %>
            <span :if={is_integer(team.rating_override)}>
              {gettext("(typed in)")}
            </span>
          </p>

          <div
            :if={
              @writable? and Tournament.paired_as_teams?(@tournament) and
                @paired < @tournament.rounds_count
            }
            id={"team-absence-#{team.id}"}
            class="actions"
            role="group"
            aria-label={gettext("Rounds %{team} sits out", team: team.name)}
          >
            <span class="hint">{gettext("Absent as a team in round:")}</span>
            <button
              :for={r <- (@paired + 1)..@tournament.rounds_count//1}
              id={"team-absent-#{team.id}-#{r}"}
              type="button"
              class="pe-btn"
              phx-click="set_team_absent"
              phx-value-team_id={team.id}
              phx-value-round={r}
              phx-value-absent={to_string(!Team.absent_in?(team, r))}
              aria-pressed={to_string(Team.absent_in?(team, r))}
              aria-label={gettext("%{team} absent in round %{round}", team: team.name, round: r)}
            >
              {r}
            </button>
          </div>
          <%!-- The buttons above are coloured for every round still to pair;
                this line only lists the absences in rounds already paired,
                which have no button any more. --%>
          <p
            :if={
              past_absences(team, @paired, @writable? and Tournament.paired_as_teams?(@tournament)) !=
                []
            }
            id={"team-absent-rounds-#{team.id}"}
            class="hint"
          >
            {gettext("Absent in rounds: %{rounds}",
              rounds:
                Enum.join(
                  past_absences(
                    team,
                    @paired,
                    @writable? and Tournament.paired_as_teams?(@tournament)
                  ),
                  ", "
                )
            )}
          </p>

          <div :if={team.withdrawn_from_round} id={"team-withdrawn-#{team.id}"} class="actions">
            <span class="badge">
              {gettext("Withdrawn from round %{round}", round: team.withdrawn_from_round)}
            </span>
            <button
              :if={@writable?}
              id={"reinstate-team-#{team.id}"}
              type="button"
              class="pe-btn"
              phx-click="reinstate_team"
              phx-value-team_id={team.id}
              data-confirm={
                gettext(
                  "Bring %{team} back into the event? Its players are no longer withdrawn, and the forfeits the withdrawal gave its later matches are withdrawn.",
                  team: team.name
                )
              }
            >
              {gettext("Reinstate")}
            </button>
          </div>

          <form
            :if={
              @writable? and is_nil(team.withdrawn_from_round) and
                Map.has_key?(@withdraw_from, team.id)
            }
            id={"withdraw-team-#{team.id}"}
            phx-submit="withdraw_team"
            class="actions"
          >
            <input type="hidden" name="team_id" value={team.id} />
            <label class="field" style="margin: 0">
              <span>{gettext("Withdraw %{team} from round", team: team.name)}</span>
              <select name="from_round">
                <option
                  :for={r <- 1..@tournament.rounds_count//1}
                  value={r}
                  selected={r == @withdraw_from[team.id]}
                >
                  {r}
                </option>
              </select>
            </label>
            <button
              type="submit"
              class="pe-btn danger"
              data-confirm={
                gettext(
                  "Withdraw %{team}? All its players are withdrawn, and its matches already paired from that round on are forfeited to the opponents.",
                  team: team.name
                )
              }
            >
              {gettext("Withdraw team")}
            </button>
          </form>

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
            <%!-- Offered on every team. One that has played (or a round robin's
                 scheduled team) cannot go: its click skips the confirmation
                 and the status line says why, and what to do instead. --%>
            <button
              id={"delete-team-#{team.id}"}
              type="button"
              class="pe-btn danger"
              phx-click="delete_team"
              phx-value-team_id={team.id}
              data-confirm={
                MapSet.member?(@deletable, team.id) &&
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
              <label class="field">
                <span>{gettext("Team rating (blank: worked out from the players)")}</span>
                <input
                  type="number"
                  min="0"
                  max="3999"
                  id={"team-rating-override-#{team.id}"}
                  name="team[rating_override]"
                  value={team.rating_override}
                />
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
                    :if={!@roster_locked?}
                    type="button"
                    class="pe-btn"
                    phx-click="move_player"
                    phx-value-player_id={player.id}
                    phx-value-direction="up"
                    data-confirm={@roster_warning? && roster_confirm()}
                    disabled={board == 1}
                    aria-label={gettext("Move %{player} to a higher board", player: player.name)}
                  >
                    ↑
                  </button>
                  <button
                    :if={!@roster_locked?}
                    type="button"
                    class="pe-btn"
                    phx-click="move_player"
                    phx-value-player_id={player.id}
                    phx-value-direction="down"
                    data-confirm={@roster_warning? && roster_confirm()}
                    disabled={board == length(roster)}
                    aria-label={gettext("Move %{player} to a lower board", player: player.name)}
                  >
                    ↓
                  </button>
                  <button
                    :if={!@roster_locked? or !MapSet.member?(@seated, player.id)}
                    type="button"
                    class="pe-btn"
                    phx-click="remove_player"
                    phx-value-player_id={player.id}
                    data-confirm={@roster_warning? && roster_confirm()}
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

          <div
            :for={{plugin, label, candidates} <- Map.get(@roster_sources, team.id, [])}
            :if={@writable?}
            id={"roster-source-#{plugin.id()}-#{team.id}"}
            class="actions"
          >
            <button
              type="button"
              class="pe-btn"
              phx-click="fill_roster"
              phx-value-team_id={team.id}
              phx-value-source={plugin.id()}
              data-confirm={@roster_warning? && roster_confirm()}
            >
              {ngettext(
                "Add %{count} player from %{source}",
                "Add %{count} players from %{source}",
                length(candidates),
                source: label
              )}
            </button>
            <span class="hint">
              {gettext("At the bottom of the roster, in the order %{source} gives.", source: label)}
            </span>
          </div>
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

  # The absences the "Absent in rounds" line lists: all of them when the round
  # buttons are not shown (read-only, or not paired as teams), otherwise only
  # those in rounds already paired - the buttons show the rest, coloured.
  defp past_absences(team, paired, buttons_shown?) do
    rounds = team.absent_rounds || []
    if buttons_shown?, do: Enum.filter(rounds, &(&1 <= paired)), else: rounds
  end
end
