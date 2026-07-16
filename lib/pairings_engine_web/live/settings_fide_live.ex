defmodule PairingsEngineWeb.SettingsFideLive do
  @moduledoc """
  The "FIDE" settings page (`/t/:id/settings/fide`) — the tournament's
  FIDE-report identifiers (the "ID of Tournament" and "Code of event" used on
  the IT3 / FA1 / IA1 / IT4 forms). A deliberately minimal skeleton for now:
  a future wave adds the per-round FIDE-ID-range feature here. The officials
  and arbiter details that feed those same report forms live on the Norms
  tab.
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
        {:noreply, assign(socket, tournament: tournament, stale: false)}
    end
  end

  @impl true
  def handle_event("save", %{"tournament" => params}, socket) do
    params = Map.take(params, ["fide_tournament_id", "event_code"])
    base = Tournaments.get_tournament!(socket.assigns.tournament.id)

    case Tournaments.update_tournament(base, params) do
      {:ok, tournament} ->
        log_settings_change(socket, base, tournament)

        {:noreply,
         assign(socket,
           tournament: tournament,
           note: "Saved.",
           error: nil,
           dirty: false,
           stale: false
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, error: error_text(changeset), note: nil)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} tournament={@tournament} active="settings">
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">Settings — FIDE</p>
        </div>
        <span class={["badge", @tournament.status == "setup" && "muted"]}>{@tournament.status}</span>
      </div>

      <.settings_subnav tournament={@tournament} active={:fide} />

      <.stale_banner stale={@stale} />

      <form phx-submit="save">
        <div class="card">
          <h2>FIDE report identifiers</h2>

          <p class="hint" style="margin-top: 0">
            The tournament's own FIDE identifiers, used to fill the IT3 / FA1 / IA1 / IT4 report
            forms on the <.link navigate={~p"/t/#{@tournament.id}/norms"}>Norms</.link>
            tab. The officials, arbiters and pairing-system details for those reports live on the
            Norms tab too.
          </p>

          <div class="form-grid">
            <label class="field">
              <span>FIDE tournament ID</span>
              <input name="tournament[fide_tournament_id]" value={@tournament.fide_tournament_id} />
            </label>

            <label class="field">
              <span>FIDE event code</span>
              <input name="tournament[event_code]" value={@tournament.event_code} />
            </label>
          </div>

          <p class="hint" style="margin-bottom: 0">
            Per-round FIDE-ID ranges (for splitting one event's report across rated sections) are
            coming in a later update — this page will grow to hold them.
          </p>
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
