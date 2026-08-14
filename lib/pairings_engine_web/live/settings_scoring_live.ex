defmodule PairingsEngineWeb.SettingsScoringLive do
  @moduledoc """
  The "Scoring" settings page (`/t/:id/settings/scoring`) — how many points
  a win/draw/loss/pairing-allocated bye is worth, plus SWAR's "Pt ABSENT"
  genuine-absence rule (`abs_value`/`abs_jusque`/`abs_nbfois` — locked once
  round 1 has been paired) and the FIDE-vs-SWAR tiebreak treatment of a
  genuine absence (`absent_counts_as_vur`). Split out of the combined
  Options page into its own focused Settings sub-page, since it's a
  distinct concern from *how the tournament is paired* (Options).
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
       page_title: "#{tournament.name} · Scoring",
       note: nil,
       error: nil,
       dirty: false,
       stale: false,
       locked_hint: nil,
       # Live preview of the "voluntary unplayed round" checkbox, tracked
       # independently of the saved value so the warning below it appears
       # (or disappears) the instant it's toggled — before "Save settings"
       # is even clicked. See the "vur_toggle" handler.
       vur_checked: tournament.absent_counts_as_vur
     )
     |> assign_abs_scoring_lock()}
  end

  # Locked once round 1 has been paired — same rationale as the
  # pairing-shape controls on the Options page: changing who's owed points
  # partway through a tournament would be confusing at best, even though
  # (unlike those controls) it wouldn't corrupt any stored data — scores
  # are computed live from these fields on every standings read, never
  # baked into a `byes` row.
  defp assign_abs_scoring_lock(socket) do
    locked = Tournaments.locked_fields(socket.assigns.tournament)
    assign(socket, abs_scoring_locked?: :abs_value in locked)
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
         socket
         |> assign(
           tournament: tournament,
           stale: false,
           vur_checked: tournament.absent_counts_as_vur
         )
         |> assign_abs_scoring_lock()}
    end
  end

  def handle_info({:clear_locked_hint, field}, socket) do
    if socket.assigns.locked_hint == field do
      {:noreply, assign(socket, locked_hint: nil)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("locked_hint", %{"field" => field}, socket) do
    field = String.to_existing_atom(field)
    Process.send_after(self(), {:clear_locked_hint, field}, 3000)
    {:noreply, assign(socket, locked_hint: field)}
  end

  # Toggling the checkbox flips a live preview of its state (see the
  # `vur_checked` assign) so the warning box below it shows/hides
  # immediately — it has no effect on the saved tournament until "Save
  # settings" is actually submitted.
  def handle_event("vur_toggle", _params, socket) do
    {:noreply, assign(socket, vur_checked: !socket.assigns.vur_checked)}
  end

  def handle_event("save", %{"tournament" => params}, socket) do
    params =
      params
      |> Map.take(~w(points_win points_draw points_loss bye_value abs_value abs_jusque abs_nbfois
        absent_counts_as_vur))
      |> maybe_drop_locked("abs_value", socket.assigns.abs_scoring_locked?)
      |> maybe_drop_locked("abs_jusque", socket.assigns.abs_scoring_locked?)
      |> maybe_drop_locked("abs_nbfois", socket.assigns.abs_scoring_locked?)

    base = Tournaments.get_tournament!(socket.assigns.tournament.id)

    case Tournaments.update_tournament(base, params) do
      {:ok, tournament} ->
        log_settings_change(socket, base, tournament)

        {:noreply,
         assign(socket,
           tournament: tournament,
           vur_checked: tournament.absent_counts_as_vur,
           note: "Saved.",
           error: nil,
           dirty: false,
           stale: false
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, error: error_text(changeset), note: nil)}
    end
  end

  defp maybe_drop_locked(params, _key, false), do: params
  defp maybe_drop_locked(params, key, true), do: Map.delete(params, key)

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
          <p class="subtitle" style="margin: 0">Settings - Scoring</p>
        </div>
      </div>

      <.settings_subnav tournament={@tournament} active={:scoring} />

      <.stale_banner stale={@stale} />

      <form phx-submit="save">
        <div class="card">
          <h2>Points</h2>

          <.setting_group>
            <.setting_field label="Points for a win">
              <input
                type="number"
                step="0.5"
                name="tournament[points_win]"
                value={@tournament.points_win}
              />
            </.setting_field>

            <.setting_field label="Points for a draw">
              <input
                type="number"
                step="0.5"
                name="tournament[points_draw]"
                value={@tournament.points_draw}
              />
            </.setting_field>

            <.setting_field label="Points for a loss">
              <input
                type="number"
                step="0.5"
                name="tournament[points_loss]"
                value={@tournament.points_loss}
              />
            </.setting_field>

            <.setting_field label="Pairing-allocated bye worth">
              <input
                type="number"
                step="0.5"
                name="tournament[bye_value]"
                value={@tournament.bye_value}
              />
            </.setting_field>
          </.setting_group>
        </div>

        <div class="card">
          <h2>Genuine absences</h2>

          <p class="subtitle" style="margin: 0 0 8px">
            A "genuine absence" is a plain no-show — a player marked absent for a round without
            requesting a bye, and without it being scored as a forfeit. It's distinct from a
            requested half/zero-point bye and from a forfeit loss, which are configured
            elsewhere. SWAR calls this option "Pt ABSENT".
          </p>

          <.setting_group>
            <.setting_field
              label="Points awarded for a genuine absence"
              hint="Leave blank if this doesn't apply — a genuine absence then scores the same as an ordinary loss, same as before this was set."
            >
              <div class="locked-wrap">
                <input
                  type="number"
                  step="0.5"
                  min="0"
                  name="tournament[abs_value]"
                  value={@tournament.abs_value}
                  disabled={@abs_scoring_locked?}
                /> <.locked_overlay field={:abs_scoring} locked?={@abs_scoring_locked?} />
              </div>
              <.locked_hint_message field={:abs_scoring} locked_hint={@locked_hint} />
            </.setting_field>

            <.setting_field
              label="Last round this still applies to"
              hint="After this round (inclusive of it), a genuine absence scores an ordinary loss instead, no matter how many are left. Leave blank so it applies for the whole tournament, with no cutoff round."
            >
              <div class="locked-wrap">
                <input
                  type="number"
                  step="1"
                  min="0"
                  name="tournament[abs_jusque]"
                  value={@tournament.abs_jusque}
                  disabled={@abs_scoring_locked?}
                /> <.locked_overlay field={:abs_scoring} locked?={@abs_scoring_locked?} />
              </div>
              <.locked_hint_message field={:abs_scoring} locked_hint={@locked_hint} />
            </.setting_field>

            <.setting_field
              label="Cap: only a player's first N genuine absences pay"
              hint="Counting this round, once a player has this many genuine absences, any further one scores an ordinary loss instead. Leave blank so every genuine absence pays, no matter how many the player racks up."
            >
              <div class="locked-wrap">
                <input
                  type="number"
                  step="1"
                  min="0"
                  name="tournament[abs_nbfois]"
                  value={@tournament.abs_nbfois}
                  disabled={@abs_scoring_locked?}
                /> <.locked_overlay field={:abs_scoring} locked?={@abs_scoring_locked?} />
              </div>
              <.locked_hint_message field={:abs_scoring} locked_hint={@locked_hint} />
            </.setting_field>

            <label class="set-toggle">
              <input type="hidden" name="tournament[absent_counts_as_vur]" value="false" />
              <input
                type="checkbox"
                name="tournament[absent_counts_as_vur]"
                value="true"
                checked={@vur_checked}
                phx-click="vur_toggle"
              />
              <span class="set-toggle-text">
                Treat a genuine absence as a voluntary unplayed round for tiebreaks
                <span class="hint">
                  Off (FIDE default) = a genuine absence always counts at its award value above,
                  same as a forfeit loss. On = a trailing one is instead downgraded to a draw for
                  opponents' Buchholz/SB, same as a requested bye.
                </span>
              </span>
            </label>

            <div :if={@vur_checked} class="setting-warning">
              <strong>⚠ This changes FIDE tiebreak results, not just scoring.</strong>
              FIDE's own C.07 tiebreak regulations have no "genuine absence" concept at all — this
              is a SWAR-historical convenience, not something a FIDE arbiter would expect by
              default. Turning it on retroactively recomputes Buchholz/Sonneborn-Berger for every
              opponent of every absent player, for the whole tournament, the moment you save. If
              this tournament is FIDE-rated or reported, leave this off unless you specifically
              intend this non-standard treatment.
            </div>
          </.setting_group>
        </div>

        <div class="actions form-actions">
          <button type="submit" class="pe-btn primary">Save settings</button>
          <span :if={@note} class="ok-note" style="align-self: center">{@note}</span>
          <span :if={@error} class="error-note" style="align-self: center">{@error}</span>
        </div>
      </form>
    </Layouts.app>
    """
  end
end
