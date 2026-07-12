defmodule PairingsEngineWeb.NormsLive do
  @moduledoc """
  The "Norms" tab: lets the tournament's owner download the official FIDE
  report/norm `.xlsx` forms (IT3, FA1, IA1, IT4), generated on demand from
  the tournament's data by `PairingsEngine.Norms.Forms`.

  The actual `.xlsx` bytes are produced by `PairingsEngineWeb.NormsController`
  (plain `GET` downloads, not LiveView) — this page is just the picker UI:

    * IT3 needs no extra input, so it's a single download link.
    * FA1/IA1 need an arbiter norm candidate's name/FIDE ID/federation, which
      isn't tracked anywhere else in the app (the candidate needn't even be
      a tournament player) — collected via a plain `GET` form, submitted
      straight to the controller with no LiveView round-trip.
    * IT4 lists every player, with a small modal to set that player's
      title-norm judgment (`norm_data` on `PairingsEngine.Tournaments.Player`)
      — only players with a non-blank claimed title are included when IT4 is
      generated.
  """

  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Tournaments
  alias PairingsEngine.Tournaments.Player

  @norm_titles ~w(GM IM FM CM WGM WIM WFM WCM)

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
       page_title: "#{tournament.name} · Norms",
       editing_norm_player: nil,
       norm_form: %{},
       norm_error: nil,
       norm_titles: @norm_titles
     )
     |> assign_players()}
  end

  @impl true
  def handle_info({:tournament_changed, _tournament_id, _hint}, socket) do
    case Tournaments.get_authorized_tournament(socket.assigns.current_scope, socket.assigns.tournament.id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "This tournament was deleted.")
         |> push_navigate(to: ~p"/")}

      tournament ->
        {:noreply, socket |> assign(tournament: tournament) |> assign_players()}
    end
  end

  defp assign_players(socket) do
    assign(socket, :players, Tournaments.list_players(socket.assigns.tournament.id))
  end

  @impl true
  def handle_event("edit_norm", %{"id" => id}, socket) do
    player = Tournaments.get_player!(id)
    {:noreply, assign(socket, editing_norm_player: player, norm_form: norm_form(player), norm_error: nil)}
  end

  def handle_event("close_norm", _params, socket) do
    {:noreply, assign(socket, editing_norm_player: nil, norm_form: %{}, norm_error: nil)}
  end

  def handle_event("save_norm", %{"player" => params}, socket) do
    case Tournaments.update_player(socket.assigns.editing_norm_player, params) do
      {:ok, _player} ->
        {:noreply,
         socket
         |> assign(editing_norm_player: nil, norm_form: %{}, norm_error: nil)
         |> assign_players()}

      {:error, changeset} ->
        {:noreply, assign(socket, norm_error: error_text(changeset), norm_form: params)}
    end
  end

  defp norm_form(%Player{norm_data: data}) do
    d = data || %{}

    %{
      "norm_data" => %{
        "title_claimed" => Map.get(d, "title_claimed", ""),
        "norm_description" => Map.get(d, "norm_description", ""),
        "medal_percent" => Map.get(d, "medal_percent", ""),
        "event_group" => Map.get(d, "event_group", ""),
        "fed_participating" => Map.get(d, "fed_participating", ""),
        "fed_members" => Map.get(d, "fed_members", ""),
        "remarks" => Map.get(d, "remarks", "")
      }
    }
  end

  defp error_text(changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end

  defp it4_candidates(players) do
    Enum.filter(players, fn p -> not blank?(Map.get(p.norm_data || %{}, "title_claimed")) end)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp claimed_title(player), do: Map.get(player.norm_data || %{}, "title_claimed", "")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} tournament={@tournament} active="norms">
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">Norms &amp; FIDE reports</p>
        </div>
      </div>

      <p class="hint">
        Fill in the officials, arbiters and pairing-system details on the
        <.link navigate={~p"/t/#{@tournament.id}/settings"}>Settings</.link>
        page first — every report below is generated straight from that data plus the player list.
      </p>

      <div class="card">
        <h2>IT3 — Tournament Report Form</h2>
        <p class="hint" style="margin-top: 0">
          The whole-tournament report: identity, officials, pairing system, and rated/titled player
          counts by federation. Always available.
        </p>
        <div class="actions">
          <a class="pe-btn primary" href={~p"/t/#{@tournament.id}/norms/it3"}>Download IT3</a>
        </div>
      </div>

      <div class="card">
        <h2>FA1 / IA1 — Arbiter norm report</h2>
        <p class="hint" style="margin-top: 0">
          For an arbiter earning a norm at this tournament. The candidate needn't be a registered
          player, so fill in their details below — nothing here is saved.
        </p>
        <form method="get" action={~p"/t/#{@tournament.id}/norms/fa1"}>
          <div class="form-grid">
            <label class="field">
              <span>Last name</span>
              <input name="candidate[last_name]" />
            </label>
            <label class="field">
              <span>First name</span>
              <input name="candidate[first_name]" />
            </label>
            <label class="field">
              <span>FIDE ID</span>
              <input name="candidate[fide_id]" />
            </label>
            <label class="field">
              <span>Federation</span>
              <input name="candidate[federation]" placeholder="BEL" />
            </label>
          </div>
          <div class="actions">
            <button type="submit" formaction={~p"/t/#{@tournament.id}/norms/fa1"} class="pe-btn primary">
              Download FA1 (FIDE Arbiter)
            </button>
            <button type="submit" formaction={~p"/t/#{@tournament.id}/norms/ia1"} class="pe-btn primary">
              Download IA1 (International Arbiter)
            </button>
          </div>
        </form>
      </div>

      <div class="card">
        <h2>IT4 — Title/Norm report</h2>
        <p class="hint" style="margin-top: 0">
          Lists every player with a claimed title norm (set below). Up to 40 candidates per file —
          a tournament with more needs a second IT4 download for the rest.
        </p>

        <p :if={it4_candidates(@players) == []} class="hint">
          No players have a claimed title yet — set one below to include a player.
        </p>

        <div :if={it4_candidates(@players) != []} class="card-table-wrap">
          <table class="pe-table">
            <thead>
              <tr>
                <th>Candidate</th>
                <th>Claiming</th>
                <th>Norm</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={p <- it4_candidates(@players)}>
                <td>{p.name}</td>
                <td>{claimed_title(p)}</td>
                <td>{Map.get(p.norm_data || %{}, "norm_description", "")}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="actions">
          <a class="pe-btn primary" href={~p"/t/#{@tournament.id}/norms/it4"}>Download IT4</a>
        </div>
      </div>

      <div class="card table-card">
        <h2 style="padding: 16px 16px 0">Players — title-norm judgment</h2>
        <p class="hint" style="padding: 0 16px">
          Set the claimed title, norm text, medal/%, event group, federation counts and remarks for
          any player being reported on IT4.
        </p>
        <table class="pe-table">
          <thead>
            <tr>
              <th>Name</th>
              <th>Federation</th>
              <th>Claimed title</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={p <- @players}>
              <td>{p.name}</td>
              <td>{p.federation}</td>
              <td>{if claimed_title(p) == "", do: "—", else: claimed_title(p)}</td>
              <td style="text-align: right">
                <button class="pe-btn" phx-click="edit_norm" phx-value-id={p.id}>Edit norm data</button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.norm_edit_modal
        :if={@editing_norm_player}
        player={@editing_norm_player}
        form={@norm_form}
        error={@norm_error}
        norm_titles={@norm_titles}
      />
    </Layouts.app>
    """
  end

  attr :player, :map, required: true
  attr :form, :map, required: true
  attr :error, :string, default: nil
  attr :norm_titles, :list, required: true

  defp norm_edit_modal(assigns) do
    ~H"""
    <div class="modal-overlay" phx-click="close_norm" phx-window-keydown="close_norm" phx-key="escape">
      <form class="modal-card" phx-submit="save_norm" onclick="event.stopPropagation()">
        <h2>Title-norm judgment — {@player.name}</h2>

        <div class="form-grid">
          <label class="field">
            <span>Title claimed</span>
            <select name="player[norm_data][title_claimed]">
              <option value="" selected={@form["norm_data"]["title_claimed"] == ""}>— none —</option>
              <option
                :for={t <- @norm_titles}
                value={t}
                selected={@form["norm_data"]["title_claimed"] == t}
              >
                {t}
              </option>
            </select>
          </label>
          <label class="field">
            <span>Norm (e.g. "IM norm")</span>
            <input
              name="player[norm_data][norm_description]"
              value={@form["norm_data"]["norm_description"]}
            />
          </label>
          <label class="field">
            <span>Medal / %</span>
            <input name="player[norm_data][medal_percent]" value={@form["norm_data"]["medal_percent"]} />
          </label>
          <label class="field">
            <span>Event / group (e.g. "U20, Women")</span>
            <input name="player[norm_data][event_group]" value={@form["norm_data"]["event_group"]} />
          </label>
          <label class="field">
            <span>Federations participating</span>
            <input
              type="number"
              name="player[norm_data][fed_participating]"
              value={@form["norm_data"]["fed_participating"]}
            />
          </label>
          <label class="field">
            <span>Federations eligible (members)</span>
            <input
              type="number"
              name="player[norm_data][fed_members]"
              value={@form["norm_data"]["fed_members"]}
            />
          </label>
          <label class="field" style="grid-column: 1 / -1">
            <span>Remarks</span>
            <input name="player[norm_data][remarks]" value={@form["norm_data"]["remarks"]} />
          </label>
        </div>

        <p :if={@error} class="error-note">{@error}</p>
        <div class="actions">
          <button type="submit" class="pe-btn primary">Save</button>
          <button type="button" class="pe-btn" phx-click="close_norm">Cancel</button>
        </div>
      </form>
    </div>
    """
  end
end
