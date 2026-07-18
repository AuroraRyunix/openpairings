defmodule PairingsEngineWeb.SettingsFideLive do
  @moduledoc """
  The "FIDE" settings page (`/t/:id/settings/fide`) — the tournament's
  FIDE-report identifiers (the "ID of Tournament" and "Code of event" used on
  the IT3 / FA1 / IA1 / IT4 forms), the `fide_homologated` tickbox, and the
  per-round FIDE-ID-range editor (SWAR's "this FIDE tournament ID applies to
  rounds X-Y" model — see `PairingsEngine.Tournaments.Tournament`'s
  `fide_id_ranges` schema doc and `PairingsEngine.TrfExport.applicable_fide_id/2`,
  the consumer at export time). The officials and arbiter details that feed
  those same report forms live on the Norms tab.
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport

  alias PairingsEngine.Tournaments

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     socket
     |> attach_dirty_tracker()
     |> assign(
       tournament: tournament,
       page_title: "#{tournament.name} · Settings",
       rows: tournament.fide_id_ranges || [],
       note: nil,
       error: nil,
       dirty: false,
       stale: false
     )}
  end

  @impl true
  def handle_info({:tournament_changed, _id, _hint}, %{assigns: %{dirty: true}} = socket) do
    handle_stale_check(socket)
  end

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
        {:noreply,
         assign(socket,
           tournament: tournament,
           rows: tournament.fide_id_ranges || [],
           stale: false
         )}
    end
  end

  # Keeps `rows` (the in-progress range editor state) in sync with every
  # keystroke, so "Add row"/"Remove row" — which only touch `rows` directly,
  # not the raw form params — never clobber edits the arbiter already typed
  # into other rows. Nothing is persisted here; only "save" writes to the DB.
  @impl true
  def handle_event("validate", %{"tournament" => params}, socket) do
    {:noreply, assign(socket, rows: parse_rows_param(params["fide_id_ranges"]))}
  end

  def handle_event("add_range", _params, socket) do
    row = %{"fide_tournament_id" => "", "from_round" => "", "to_round" => ""}
    {:noreply, assign(socket, rows: socket.assigns.rows ++ [row])}
  end

  def handle_event("remove_range", %{"index" => index}, socket) do
    index = String.to_integer(index)
    {:noreply, assign(socket, rows: List.delete_at(socket.assigns.rows, index))}
  end

  def handle_event("save", %{"tournament" => params}, socket) do
    params =
      params
      |> Map.take(["fide_tournament_id", "event_code", "fide_homologated", "fide_id_ranges"])
      |> Map.update("fide_id_ranges", [], &parse_rows_param/1)

    base = Tournaments.get_tournament!(socket.assigns.tournament.id)

    case Tournaments.update_tournament(base, params) do
      {:ok, tournament} ->
        log_settings_change(socket, base, tournament)

        {:noreply,
         assign(socket,
           tournament: tournament,
           rows: tournament.fide_id_ranges || [],
           note: "Saved.",
           error: nil,
           dirty: false,
           stale: false
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, error: error_text(changeset), note: nil)}
    end
  end

  # The "fide_id_ranges" form param arrives as a map indexed by string
  # position ("0", "1", ...) rather than a list — standard HTML nested-form
  # shape for `tournament[fide_id_ranges][0][fide_tournament_id]` etc. Sorts
  # numerically back into row order. `nil` (no rows at all, e.g. every row
  # removed) yields an empty list.
  defp parse_rows_param(nil), do: []

  defp parse_rows_param(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {k, _v} -> String.to_integer(k) end)
    |> Enum.map(fn {_k, v} -> v end)
  end

  defp parse_rows_param(_), do: []

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      tournament={@tournament}
      active="settings"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">Settings — FIDE</p>
        </div>
        <span class={["badge", @tournament.status == "setup" && "muted"]}>{@tournament.status}</span>
      </div>

      <.settings_subnav tournament={@tournament} active={:fide} />

      <.stale_banner stale={@stale} />

      <form id="fide-settings-form" phx-submit="save" phx-change="validate">
        <div class="card">
          <h2>FIDE report identifiers</h2>

          <p class="hint" style="margin-top: 0">
            The tournament's own FIDE identifiers, used to fill the IT3 / FA1 / IA1 / IT4 report
            forms on the <.link navigate={~p"/t/#{@tournament.id}/norms"}>Norms</.link>
            tab. The officials, arbiters and pairing-system details for those reports live on the
            Norms tab too.
          </p>

          <.setting_group>
            <.setting_toggle
              name="tournament[fide_homologated]"
              label="This tournament is FIDE-homologated (rated/reportable)"
              checked={@tournament.fide_homologated}
            />

            <.setting_field label="FIDE tournament ID (tournament-wide default)">
              <input name="tournament[fide_tournament_id]" value={@tournament.fide_tournament_id} />
            </.setting_field>

            <.setting_field label="FIDE event code">
              <input name="tournament[event_code]" value={@tournament.event_code} />
            </.setting_field>
          </.setting_group>

          <p class="hint" style="margin-bottom: 0">
            The FIDE tournament ID above is used whenever no per-round range below unambiguously
            covers the exported rounds (no ranges configured, the export spans more than one range,
            or matches none) — see the ranges below for splitting one event's report across
            differently-rated sections.
          </p>
        </div>

        <div class="card">
          <h2>Per-round FIDE-ID ranges</h2>
          <p class="hint" style="margin-top: 0">
            For splitting one event's FIDE report across rated sections — e.g. FIDE ID 89495 for
            rounds 1-3, a different ID for rounds 4-9. When exporting a TRF whose selected rounds
            fall entirely inside one range below, that range's ID is used instead of the
            tournament-wide default above. Ranges may not overlap.
          </p>

          <div :if={@rows != []} class="card-table-wrap">
            <table class="pe-table">
              <thead>
                <tr>
                  <th>FIDE tournament ID</th>
                  <th>From round</th>
                  <th>To round</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{row, i} <- Enum.with_index(@rows)}>
                  <td>
                    <input
                      class="pe-input"
                      name={"tournament[fide_id_ranges][#{i}][fide_tournament_id]"}
                      value={row["fide_tournament_id"]}
                    />
                  </td>
                  <td>
                    <input
                      type="number"
                      min="1"
                      class="pe-input"
                      style="width: 6rem"
                      name={"tournament[fide_id_ranges][#{i}][from_round]"}
                      value={row["from_round"]}
                    />
                  </td>
                  <td>
                    <input
                      type="number"
                      min="1"
                      class="pe-input"
                      style="width: 6rem"
                      name={"tournament[fide_id_ranges][#{i}][to_round]"}
                      value={row["to_round"]}
                    />
                  </td>
                  <td style="text-align: right">
                    <button
                      type="button"
                      class="pe-btn danger-link"
                      phx-click="remove_range"
                      phx-value-index={i}
                    >
                      Remove
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <p :if={@rows == []} class="hint">
            No per-round ranges configured — every export uses the tournament-wide default ID above.
          </p>

          <div class="actions">
            <button type="button" class="pe-btn" phx-click="add_range">Add range</button>
          </div>
        </div>

        <div class="actions">
          <button type="submit" class="pe-btn primary">Save FIDE settings</button>
          <span :if={@note} class="ok-note" style="align-self: center">{@note}</span>
          <span :if={@error} class="error-note" style="align-self: center">{@error}</span>
        </div>
      </form>
    </Layouts.app>
    """
  end
end
