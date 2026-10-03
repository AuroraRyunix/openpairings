defmodule PairingsEngineWeb.MatchLive do
  @moduledoc """
  One team match (`/t/:id/pairings/:round/matches/:match`): the two
  line-ups, entered after the pairing is published, and - with league-style
  board colours - which team is at home. See docs/team-tournaments.md,
  "Line-ups".

  Each line-up is one select per board, board 1 first. It starts as the
  pairing seated it - the roster minus anyone unavailable that round - and
  can change until the first result of the match is entered
  (`PairingsEngine.TeamMatches.set_lineups/4`, which checks the roster's
  board order and rewrites the match's boards).

  With optional line-ups (`Tournament.team_lineups_optional?/1`) an empty
  seat is a player not entered rather than a forfeit, and a match nobody
  sits at can be decided by its score alone
  (`PairingsEngine.TeamMatches.set_match_score/4`).
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport, only: [error_text: 1]

  alias PairingsEngine.{Audit, Snapshots, TeamMatches, TeamRounds, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Team, Tournament}

  @impl true
  def mount(%{"id" => id, "round" => round, "match" => match_id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     socket
     |> assign(
       tournament: tournament,
       round_number: parse_int(round),
       match_id: parse_int(match_id),
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
        {:noreply, push_navigate(socket, to: ~p"/")}

      tournament ->
        {:noreply, socket |> assign(tournament: tournament) |> load()}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp parse_int(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp load(socket) do
    t = socket.assigns.tournament

    round =
      socket.assigns.round_number && Tournaments.get_round(t.id, socket.assigns.round_number)

    match =
      round &&
        round.id
        |> Tournaments.list_matches()
        |> Enum.find(&(&1.id == socket.assigns.match_id and not is_nil(&1.team_b_id)))

    if match do
      lineups = TeamMatches.lineups(t, match)

      assign(socket,
        match: match,
        page_title:
          gettext("%{name} · Match %{match}, round %{round}",
            name: t.name,
            match: match.board,
            round: socket.assigns.round_number
          ),
        roster_a: Tournaments.team_roster(t.id, match.team_a_id),
        roster_b: Tournaments.team_roster(t.id, match.team_b_id),
        lineups: lineups,
        open?: TeamMatches.lineup_open?(match),
        writable?: Tournaments.ensure_writable(t) == :ok,
        form: lineup_form(lineups),
        optional?: Tournament.team_lineups_optional?(t),
        unseated?: Enum.all?(lineups.a ++ lineups.b, &is_nil/1),
        score_form: to_form(%{"a" => "", "b" => ""}, as: :score)
      )
    else
      assign(socket, match: nil, page_title: gettext("Match not found"))
    end
  end

  defp lineup_form(%{a: a, b: b}) do
    side = fn ids ->
      ids
      |> Enum.with_index(1)
      |> Map.new(fn {id, k} -> {Integer.to_string(k), id && to_string(id)} end)
    end

    to_form(%{"a" => side.(a), "b" => side.(b)}, as: :lineup)
  end

  ## ---------- events ----------

  @impl true
  def handle_event("save_lineups", %{"lineup" => params}, socket) when is_map(params) do
    %{tournament: t} = socket.assigns
    per_match = max(t.team_boards || 1, 1)

    ids = fn side ->
      for k <- 1..per_match do
        params |> Map.get(side, %{}) |> Map.get(Integer.to_string(k)) |> parse_int()
      end
    end

    save(socket, ids.("a"), ids.("b"), gettext("Line-ups saved; the boards were rewritten."))
  end

  def handle_event("reset_lineups", _params, socket) do
    %{tournament: t, match: match, round_number: number} = socket.assigns

    save(
      socket,
      TeamMatches.default_lineup(t, match.team_a_id, number),
      TeamMatches.default_lineup(t, match.team_b_id, number),
      gettext("Line-ups set back to the rosters.")
    )
  end

  def handle_event("swap_home", _params, socket) do
    %{tournament: t, match: match, round_number: number} = socket.assigns

    case TeamMatches.swap_home(t, match) do
      {:ok, _} ->
        Audit.log(t.id, socket.assigns.current_scope, "pairing.match_home_swapped", %{
          round: number,
          match: match.board,
          home: team_name(match.team_b),
          away: team_name(match.team_a)
        })

        {:noreply,
         socket
         |> assign(note: gettext("%{team} is now the home team.", team: team_name(match.team_b)))
         |> assign(error: nil)
         |> load()}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason), note: nil)}
    end
  end

  def handle_event("set_match_score", %{"score" => %{"a" => a, "b" => b}}, socket) do
    %{tournament: t, match: match, round_number: number} = socket.assigns

    with {:ok, score_a} <- parse_score(a),
         {:ok, score_b} <- parse_score(b),
         _ =
           Snapshots.capture(t, "pairing.match_score_set", socket.assigns.current_scope,
             summary: "Before entering the score of match #{match.board} of round #{number}"
           ),
         {:ok, _} <- TeamMatches.set_match_score(t, match, score_a, score_b) do
      Audit.log(t.id, socket.assigns.current_scope, "pairing.match_score_set", %{
        round: number,
        match: match.board,
        team_a: team_name(match.team_a),
        team_b: team_name(match.team_b),
        score: "#{format_score(score_a)}-#{format_score(score_b)}"
      })

      {:noreply,
       socket
       |> assign(note: gettext("Match score saved; the boards carry it."), error: nil)
       |> load()}
    else
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason), note: nil)}
    end
  end

  def handle_event("clear_match_score", _params, socket) do
    %{tournament: t, match: match, round_number: number} = socket.assigns

    case TeamMatches.clear_match_score(t, match) do
      {:ok, _} ->
        Audit.log(t.id, socket.assigns.current_scope, "pairing.match_score_cleared", %{
          round: number,
          match: match.board,
          team_a: team_name(match.team_a),
          team_b: team_name(match.team_b),
          score: "#{format_score(match.match_score_a)}-#{format_score(match.match_score_b)}"
        })

        {:noreply,
         socket |> assign(note: gettext("Match score withdrawn."), error: nil) |> load()}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason), note: nil)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # "2.5", "2,5", "2½" and "2 1/2" all read as 2.5.
  defp parse_score(value) do
    text =
      value
      |> to_string()
      |> String.trim()
      |> String.replace(",", ".")
      |> String.replace(~r/\s*(½|1\/2)$/u, ".5")

    text = if String.starts_with?(text, "."), do: "0" <> text, else: text

    case Float.parse(text) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :bad_score}
    end
  end

  defp format_score(nil), do: "-"

  defp format_score(n) do
    whole = trunc(n)

    cond do
      n == whole -> Integer.to_string(whole)
      whole == 0 -> "½"
      true -> "#{whole}½"
    end
  end

  defp save(socket, lineup_a, lineup_b, success) do
    %{tournament: t, match: match, round_number: number, lineups: before} = socket.assigns

    Snapshots.capture(t, "pairing.lineup_changed", socket.assigns.current_scope,
      summary: "Before changing the line-ups of match #{match.board} of round #{number}"
    )

    case TeamMatches.set_lineups(t, match, lineup_a, lineup_b) do
      {:ok, _} ->
        names = player_names(socket)

        Audit.log(t.id, socket.assigns.current_scope, "pairing.lineup_changed", %{
          round: number,
          match: match.board,
          team_a: team_name(match.team_a),
          team_b: team_name(match.team_b),
          before_a: Enum.map(before.a, &Map.get(names, &1)),
          before_b: Enum.map(before.b, &Map.get(names, &1)),
          after_a: Enum.map(lineup_a, &Map.get(names, &1)),
          after_b: Enum.map(lineup_b, &Map.get(names, &1))
        })

        {:noreply, socket |> assign(note: success, error: nil) |> load()}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason), note: nil)}
    end
  end

  defp player_names(socket),
    do: Map.new(socket.assigns.roster_a ++ socket.assigns.roster_b, &{&1.id, &1.name})

  defp team_name(%Team{name: name}), do: name
  defp team_name(_), do: "-"

  # One option per roster player, in board order; one who cannot play this
  # round is listed - so the select shows who is missing - and refused on
  # save with the reason.
  defp options(roster, round_number, optional?) do
    [
      {if(optional?, do: gettext("(empty: not entered)"), else: gettext("(empty: forfeit)")), ""}
      | Enum.map(roster, fn p ->
          label =
            if TeamRounds.available?(p, round_number),
              do: "#{p.board_order}. #{p.name} (#{rating(p)})",
              else:
                gettext("%{order}. %{name} - cannot play this round",
                  order: p.board_order,
                  name: p.name
                )

          {label, to_string(p.id)}
        end)
    ]
  end

  defp rating(player) do
    case Player.rating(player) do
      0 -> "-"
      r -> r
    end
  end

  defp colour_label(k) do
    if TeamRounds.team_a_white?(k), do: gettext("White"), else: gettext("Black")
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
      active="pairings"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p :if={@match} class="subtitle" style="margin: 0">
            {gettext("Round %{round}, match %{match}: %{a} - %{b}",
              round: @round_number,
              match: @match.board,
              a: team_name(@match.team_a),
              b: team_name(@match.team_b)
            )}
          </p>
        </div>
        <.link
          navigate={
            if @round_number,
              do: ~p"/t/#{@tournament.id}/pairings?round=#{@round_number}",
              else: ~p"/t/#{@tournament.id}/pairings"
          }
          class="pe-btn"
        >
          {gettext("Back to the pairings")}
        </.link>
      </div>

      <p role="status" aria-live="polite" class={@note && "ok-note"}>{@note}</p>
      <p :if={@error} id="match-error" role="alert" class="error-note">{@error}</p>

      <div :if={is_nil(@match)} class="card">
        <h2>{gettext("Match not found")}</h2>
        <p class="hint">{gettext("This round has no such match.")}</p>
      </div>

      <%= if @match do %>
        <div
          :if={Tournament.home_and_away?(@tournament)}
          id="home-and-away"
          class="card"
        >
          <h2>{gettext("Home and away")}</h2>
          <p class="hint">
            {gettext(
              "%{home} is the home team and has White on the odd boards; %{away} has White on the even boards.",
              home: team_name(@match.team_a),
              away: team_name(@match.team_b)
            )}
          </p>
          <button
            :if={@open? and @writable?}
            id="swap-home"
            type="button"
            class="pe-btn"
            phx-click="swap_home"
            data-confirm={
              gettext("Make %{team} the home team? Every board's colours are swapped.",
                team: team_name(@match.team_b)
              )
            }
          >
            {gettext("Make %{team} the home team", team: team_name(@match.team_b))}
          </button>
        </div>

        <div :if={@optional?} id="match-score" class="card">
          <h2>{gettext("Match score")}</h2>
          <%= if TeamMatches.match_score?(@match) do %>
            <p id="match-score-set">
              {gettext("Decided by its score: %{a} %{score_a} - %{score_b} %{b}",
                a: team_name(@match.team_a),
                b: team_name(@match.team_b),
                score_a: format_score(@match.match_score_a),
                score_b: format_score(@match.match_score_b)
              )}
            </p>
            <p class="hint">
              {gettext(
                "Its boards carry the score as results - the winning team's wins on the top boards, the rest drawn - with no player on them, so no game goes to the rating report."
              )}
            </p>
            <button
              :if={@writable?}
              id="clear-match-score"
              type="button"
              class="pe-btn"
              phx-click="clear_match_score"
              data-confirm={gettext("Withdraw the match score? Its boards are blank again.")}
            >
              {gettext("Withdraw the match score")}
            </button>
          <% else %>
            <p class="hint">
              {gettext(
                "Only the result of the match is known? Enter it here, in boards (2.5 and 1.5 for 2½-1½). It is written onto the boards, which need no players. A match with players on its boards takes each board's result on the Pairings page instead."
              )}
            </p>
            <.form
              :if={@open? and @unseated? and @writable?}
              for={@score_form}
              id="match-score-form"
              phx-submit="set_match_score"
              class="actions"
            >
              <.input
                field={@score_form[:a]}
                type="text"
                inputmode="decimal"
                id="match-score-a"
                label={team_name(@match.team_a)}
                required
              />
              <.input
                field={@score_form[:b]}
                type="text"
                inputmode="decimal"
                id="match-score-b"
                label={team_name(@match.team_b)}
                required
              />
              <button type="submit" class="pe-btn primary" id="save-match-score">
                {gettext("Save match score")}
              </button>
            </.form>
            <p :if={!@unseated?} id="match-score-seated" class="hint">
              {gettext("Players sit at this match's boards, so its result goes on each board.")}
            </p>
            <p :if={@unseated? and !@open?} class="hint">
              {gettext("This match already has a result.")}
            </p>
          <% end %>
        </div>

        <div class="card">
          <h2>{gettext("Line-ups")}</h2>
          <p :if={!@optional?} class="hint">
            {gettext(
              "Who plays on which board. Each team plays in its roster's board order: players can be left out, and the players below them move up, but nobody plays above a player listed higher. A team short of players leaves its bottom boards empty, and the other team wins them by forfeit."
            )}
          </p>
          <p :if={@optional?} id="lineups-optional-hint" class="hint">
            {gettext(
              "Line-ups are optional in this tournament: a board may stay empty, and its result is entered on the Pairings page all the same. Players who are entered keep their roster's board order."
            )}
          </p>
          <p :if={!@open?} id="lineups-closed" class="hint">
            {gettext("This match has a result, so its line-ups can no longer change.")}
          </p>

          <.form for={@form} id="lineup-form" phx-submit="save_lineups">
            <table class="pe-table">
              <caption class="sr-only">{gettext("Line-ups by board")}</caption>
              <thead>
                <tr>
                  <th scope="col" class="num">{gettext("Board")}</th>
                  <th scope="col">{team_name(@match.team_a)}</th>
                  <th scope="col">{team_name(@match.team_b)}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={k <- 1..max(@tournament.team_boards || 1, 1)} id={"lineup-board-#{k}"}>
                  <td class="num">
                    {k}
                    <span class="hint">
                      ({gettext("%{colour} for %{team}",
                        colour: colour_label(k),
                        team: team_name(@match.team_a)
                      )})
                    </span>
                  </td>
                  <td>
                    <.input
                      type="select"
                      id={"lineup-a-#{k}"}
                      name={"lineup[a][#{k}]"}
                      value={@form.params["a"][Integer.to_string(k)]}
                      options={options(@roster_a, @round_number, @optional?)}
                      disabled={!@open? or !@writable?}
                      aria-label={
                        gettext("Board %{board} for %{team}",
                          board: k,
                          team: team_name(@match.team_a)
                        )
                      }
                    />
                  </td>
                  <td>
                    <.input
                      type="select"
                      id={"lineup-b-#{k}"}
                      name={"lineup[b][#{k}]"}
                      value={@form.params["b"][Integer.to_string(k)]}
                      options={options(@roster_b, @round_number, @optional?)}
                      disabled={!@open? or !@writable?}
                      aria-label={
                        gettext("Board %{board} for %{team}",
                          board: k,
                          team: team_name(@match.team_b)
                        )
                      }
                    />
                  </td>
                </tr>
              </tbody>
            </table>
            <div :if={@open? and @writable?} class="actions">
              <button type="submit" class="pe-btn primary" id="save-lineups">
                {gettext("Save line-ups")}
              </button>
              <button
                type="button"
                class="pe-btn"
                id="reset-lineups"
                phx-click="reset_lineups"
                data-confirm={gettext("Set both line-ups back to the rosters?")}
              >
                {gettext("Back to the rosters")}
              </button>
            </div>
          </.form>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
