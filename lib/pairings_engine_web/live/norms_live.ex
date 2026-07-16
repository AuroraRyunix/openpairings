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
    * "Combined report (festival)" lets a Belgian-federation arbiter running
      several category groups as one festival (each its own `Tournament`
      row) pick other tournaments to merge into one IT3/FA1/IA1, plus a
      "master" tournament supplying the shared header/schedule fields (see
      `PairingsEngine.Norms.Combine`). This card only *builds the link* —
      the selection lives in `@combine_selected`/`@combine_master` and is
      passed to `PairingsEngineWeb.NormsController` as `combine`/`master`
      query params; nothing here is saved.
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
       norm_titles: @norm_titles,
       other_tournaments: other_tournaments(socket.assigns.current_scope, tournament.id),
       combine_selected: MapSet.new(),
       combine_master: to_string(tournament.id)
     )
     |> assign_players()}
  end

  # Every *other* tournament the current user can access (owner or accepted
  # collaborator — same scoping `Tournaments.list_tournaments/1` already
  # gives the tournament list page), for the "Combined report (festival)"
  # card's checkbox picker. The current tournament itself is excluded here
  # since it's always implicitly part of the combined set (see
  # `combine_ids/3`).
  defp other_tournaments(scope, tournament_id) do
    scope
    |> Tournaments.list_tournaments()
    |> Enum.reject(fn {t, _player_count, _owner?} -> t.id == tournament_id end)
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

  ## ---------- Combined report (festival) picker ----------

  def handle_event("toggle_combine_tournament", %{"id" => id}, socket) do
    selected = socket.assigns.combine_selected

    {selected, master} =
      if MapSet.member?(selected, id) do
        deselected = MapSet.delete(selected, id)
        # Deselecting the current master falls back to the tournament
        # itself, which is always part of the combined set.
        master =
          if socket.assigns.combine_master == id,
            do: to_string(socket.assigns.tournament.id),
            else: socket.assigns.combine_master

        {deselected, master}
      else
        {MapSet.put(selected, id), socket.assigns.combine_master}
      end

    {:noreply, assign(socket, combine_selected: selected, combine_master: master)}
  end

  def handle_event("set_combine_master", %{"master" => id}, socket) do
    {:noreply, assign(socket, :combine_master, id)}
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

  ## ---------- Combined report (festival) helpers (render-only; the two
  ## handle_event clauses that drive @combine_selected/@combine_master live
  ## up by save_norm, grouped with the rest of handle_event/3) ----------

  # `[current tournament id | selected companion ids]`, always leading with
  # the current tournament — the order used both for the master picker's
  # options and for the `combine=` query param, since `NormsController`
  # resolves `master` to an index into this same order.
  defp combine_ids(tournament, other_tournaments, combine_selected) do
    companions =
      other_tournaments
      |> Enum.map(fn {t, _count, _owner?} -> to_string(t.id) end)
      |> Enum.filter(&MapSet.member?(combine_selected, &1))

    [to_string(tournament.id) | companions]
  end

  # `{id, name}` pairs for the master picker: the current tournament plus
  # whichever companions are currently checked (a tournament can only be
  # picked as master once it's part of the combined set).
  defp combine_master_options(tournament, other_tournaments, combine_selected) do
    companions =
      other_tournaments
      |> Enum.filter(fn {t, _count, _owner?} -> MapSet.member?(combine_selected, to_string(t.id)) end)
      |> Enum.map(fn {t, _count, _owner?} -> {to_string(t.id), t.name} end)

    [{to_string(tournament.id), tournament.name} | companions]
  end

  defp combine_href(base_path, ids, master) do
    base_path <> "?" <> URI.encode_query(%{"combine" => Enum.join(ids, ","), "master" => master})
  end

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
        <h2>Combined report (festival)</h2>
        <p class="hint" style="margin-top: 0">
          Running several category groups as separate tournaments? Pick the others below to
          generate one combined IT3/FA1/IA1 for the whole festival — the master tournament
          supplies the shared header/schedule fields, and gives the combined report its name.
        </p>

        <p :if={@other_tournaments == []} class="hint">
          You have no other tournaments to combine this one with.
        </p>

        <div :if={@other_tournaments != []}>
          <div style="display: flex; flex-direction: column; gap: .4rem; margin-bottom: 1rem">
            <label
              :for={{t, _count, _owner?} <- @other_tournaments}
              style="display: flex; gap: .5rem; align-items: center; font-weight: 400"
            >
              <input
                type="checkbox"
                checked={MapSet.member?(@combine_selected, to_string(t.id))}
                phx-click="toggle_combine_tournament"
                phx-value-id={t.id}
                style="width: auto"
              /> <span>{t.name}</span>
            </label>
          </div>

          <p :if={MapSet.size(@combine_selected) == 0} class="hint">
            Select at least one tournament above to enable the combined downloads.
          </p>

          <div :if={MapSet.size(@combine_selected) > 0}>
            <form id="combine-master-form" phx-change="set_combine_master">
              <label class="field" style="max-width: 360px">
                <span>Master tournament (header/schedule/name)</span>
                <select name="master">
                  <option
                    :for={
                      {id, name} <-
                        combine_master_options(@tournament, @other_tournaments, @combine_selected)
                    }
                    value={id}
                    selected={id == @combine_master}
                  >
                    {name}
                  </option>
                </select>
              </label>
            </form>

            <div class="actions">
              <a
                class="pe-btn primary"
                href={
                  combine_href(
                    ~p"/t/#{@tournament.id}/norms/it3",
                    combine_ids(@tournament, @other_tournaments, @combine_selected),
                    @combine_master
                  )
                }
              >
                Download combined IT3
              </a>
            </div>

            <form method="get" action={~p"/t/#{@tournament.id}/norms/fa1"}>
              <input
                type="hidden"
                name="combine"
                value={Enum.join(combine_ids(@tournament, @other_tournaments, @combine_selected), ",")}
              />
              <input type="hidden" name="master" value={@combine_master} />
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
                <button
                  type="submit"
                  formaction={~p"/t/#{@tournament.id}/norms/fa1"}
                  class="pe-btn primary"
                >
                  Download combined FA1 (FIDE Arbiter)
                </button>
                <button
                  type="submit"
                  formaction={~p"/t/#{@tournament.id}/norms/ia1"}
                  class="pe-btn primary"
                >
                  Download combined IA1 (International Arbiter)
                </button>
              </div>
            </form>
          </div>
        </div>
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
    <div class="modal-overlay" phx-window-keydown="close_norm" phx-key="escape">
      <form class="modal-card" phx-submit="save_norm" phx-click-away="close_norm">
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
