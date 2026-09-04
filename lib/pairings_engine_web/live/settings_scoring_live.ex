defmodule PairingsEngineWeb.SettingsScoringLive do
  @moduledoc """
  The "Scoring" settings page (`/t/:id/settings/scoring`) - how many points
  a win/draw/loss/pairing-allocated bye is worth, plus SWAR's "Pt ABSENT"
  genuine-absence rule (`abs_value`/`abs_jusque`/`abs_nbfois` - locked once
  round 1 has been paired) and the FIDE-vs-SWAR tiebreak treatment of a
  round a player sat out (`absent_counts_as_vur`). Split out of the combined
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
       # Deliberately unlocked for THIS save only - see `assign_abs_scoring_lock/1`
       # and the "unlock_field" event below. Never persisted, and reset back
       # to empty the moment a save using it lands (same rule as the
       # pairing-shape locks on `SettingsOptionsLive`).
       unlocked_fields: MapSet.new(),
       # Live preview of the "voluntary unplayed round" checkbox, tracked
       # independently of the saved value so the warning below it appears
       # (or disappears) the instant it's toggled - before "Save settings"
       # is even clicked. See the "vur_toggle" handler.
       vur_checked: tournament.absent_counts_as_vur
     )
     |> assign_abs_scoring_lock()}
  end

  # Locked once round 1 has been paired - same rationale as the
  # pairing-shape controls on the Options page: changing who's owed points
  # partway through a tournament would be confusing at best, even though
  # (unlike those controls) it wouldn't corrupt any stored data - scores
  # are computed live from these fields on every standings read, never
  # baked into a `byes` row.
  # `abs_scoring` is a single UI concept standing in for three real fields
  # (`abs_value`/`abs_jusque`/`abs_nbfois` - see `@abs_scoring_fields`
  # below), so an "Unlock" here has to unlock all three at once, not just
  # whichever one happens to be first: the trio was never meant to be set
  # independently (a value with no cutoff round is nonsensical on its own).
  @abs_scoring_fields ~w(abs_value abs_jusque abs_nbfois)a

  defp assign_abs_scoring_lock(socket) do
    locked? =
      :abs_value in Tournaments.locked_fields(socket.assigns.tournament) and
        :abs_scoring not in socket.assigns.unlocked_fields

    assign(socket, abs_scoring_locked?: locked?)
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

  @impl true
  # Guarded on the one field this page's `locked_overlay/1` sends - see the
  # same guard in `SettingsOptionsLive` for why an unguarded
  # `String.to_existing_atom/1` on a param is a self-inflicted crash.
  @locked_fields ~w(abs_scoring)

  def handle_event("locked_hint", %{"field" => field}, socket)
      when field in @locked_fields do
    {:noreply, assign(socket, locked_hint: String.to_existing_atom(field))}
  end

  def handle_event("locked_hint", _params, socket), do: {:noreply, socket}

  # Same allowlist, same reasoning as `SettingsOptionsLive`'s "unlock_field"
  # clause: this is a UI convenience, not the security boundary -
  # `Tournaments.ensure_unlocked/3` refuses the actual write regardless of
  # what reaches it here.
  def handle_event("unlock_field", %{"field" => field}, socket)
      when field in @locked_fields do
    field = String.to_existing_atom(field)

    {:noreply,
     socket
     |> update(:unlocked_fields, &MapSet.put(&1, field))
     |> assign_abs_scoring_lock()}
  end

  def handle_event("unlock_field", _params, socket), do: {:noreply, socket}

  # Toggling the checkbox flips a live preview of its state (see the
  # `vur_checked` assign) so the warning box below it shows/hides
  # immediately - it has no effect on the saved tournament until "Save
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

    # `unlocked_fields` holds the UI-level `:abs_scoring` key, not the three
    # real schema fields it stands for - see `@abs_scoring_fields`. Read
    # from the socket, never from `params`: same "a crafted save must not
    # slip a locked field through" reasoning as `SettingsOptionsLive`.
    unlock_fields =
      if :abs_scoring in socket.assigns.unlocked_fields, do: @abs_scoring_fields, else: []

    case Tournaments.update_tournament(base, params, unlock: unlock_fields) do
      {:ok, tournament} ->
        log_settings_change(socket, base, tournament)
        log_unlocked_field_changes(socket, base, tournament, unlock_fields)

        {:noreply,
         assign(socket,
           tournament: tournament,
           vur_checked: tournament.absent_counts_as_vur,
           note: "Saved.",
           error: nil,
           dirty: false,
           stale: false,
           unlocked_fields: MapSet.new()
         )
         |> assign_abs_scoring_lock()}

      {:error, changeset} ->
        {:noreply, assign(socket, error: error_text(changeset), note: nil)}
    end
  end

  defp maybe_drop_locked(params, _key, false), do: params
  defp maybe_drop_locked(params, key, true), do: Map.delete(params, key)

  defp abs_scoring_warning,
    do:
      gettext(
        "Standings and tiebreaks are computed live from these values on every read, not baked into a stored row. Changing them doesn't just apply going forward - every already-recorded absence, in every already-paired round, is instantly rescored under the new values, and published standings can move."
      )

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
      tournament={@tournament}
      active="settings"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">{gettext("Settings - Scoring")}</p>
        </div>
      </div>

      <.settings_subnav tournament={@tournament} active={:scoring} />

      <.stale_banner stale={@stale} />

      <form id="scoring-settings-form" phx-submit="save">
        <div class="card">
          <h2>{gettext("Points")}</h2>

          <.setting_group>
            <.setting_field label={gettext("Points for a win")}>
              <input
                type="number"
                step="0.5"
                name="tournament[points_win]"
                value={@tournament.points_win}
              />
            </.setting_field>

            <.setting_field label={gettext("Points for a draw")}>
              <input
                type="number"
                step="0.5"
                name="tournament[points_draw]"
                value={@tournament.points_draw}
              />
            </.setting_field>

            <.setting_field label={gettext("Points for a loss")}>
              <input
                type="number"
                step="0.5"
                name="tournament[points_loss]"
                value={@tournament.points_loss}
              />
            </.setting_field>

            <.setting_field label={gettext("Pairing-allocated bye worth")}>
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
          <h2>{gettext("Byes and absences")}</h2>

          <p class="subtitle" style="margin: 0 0 8px">
            {gettext(
              "What a round a player sits out is worth, and how many of them are paid. This covers every absence the pairing knows about, whether the player asked for a specific round off or is marked absent outright - those are the same event, because the only way you know before pairing is that they told you. Somebody who was paired and then didn't turn up is a forfeit on their board, not this. A pairing-allocated bye - the odd player out when the field is uneven - has its own value above."
            )}
          </p>

          <p class="subtitle" style="margin: 0 0 8px">
            {gettext(
              "FIDE's default is zero. Most opens pay half a point for the first one or two, which is what the two limits below are for. SWAR calls this option \"Pt ABSENT\"."
            )}
          </p>

          <.setting_group>
            <.setting_field
              label={gettext("Points for a round sat out")}
              hint={
                gettext(
                  "Leave blank if this doesn't apply - a round sat out then scores the same as an ordinary loss, same as before this was set."
                )
              }
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
              <.locked_hint_message
                field={:abs_scoring}
                locked_hint={@locked_hint}
                warning={abs_scoring_warning()}
              />
            </.setting_field>

            <.setting_field
              label={gettext("Last round this still applies to")}
              hint={
                gettext(
                  "After this round (inclusive of it), a round sat out scores an ordinary loss instead, no matter how many are left. Leave blank so it applies for the whole tournament, with no cutoff round."
                )
              }
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
              <.locked_hint_message
                field={:abs_scoring}
                locked_hint={@locked_hint}
                warning={abs_scoring_warning()}
              />
            </.setting_field>

            <.setting_field
              label={gettext("Cap: only a player's first N rounds sat out are paid")}
              hint={
                gettext(
                  "Counting this round, once a player has sat out this many rounds, any further one scores an ordinary loss instead. Leave blank so every one pays, no matter how many the player racks up."
                )
              }
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
              <.locked_hint_message
                field={:abs_scoring}
                locked_hint={@locked_hint}
                warning={abs_scoring_warning()}
              />
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
                {gettext("Treat a round sat out as a voluntary unplayed round for tiebreaks")}
                <span class="hint">
                  {gettext(
                    "On (the default) = a trailing one is downgraded to a draw for opponents' Buchholz/SB, which is what C.07 does with a voluntarily unplayed round. Off = it always counts at its award value above, same as a forfeit loss."
                  )}
                </span>
              </span>
            </label>

            <%!-- Fires on CHANGE, not on state. It used to fire whenever the
                  box was ticked, which was the same thing while the default
                  was off - and would now shout at every arbiter opening a
                  fresh tournament about a setting they never touched. What
                  is actually dangerous is moving it mid-event. --%>
            <div :if={@vur_checked != @tournament.absent_counts_as_vur} class="setting-warning">
              <strong>{gettext("⚠ This changes FIDE tiebreak results, not just scoring.")}</strong>
              {gettext(
                "Saving this recomputes Buchholz/Sonneborn-Berger for every opponent of every player who has sat a round out, across the whole tournament, immediately. The default is on because every absence the pairing knows about was announced - you only find out before the round is paired because the player told you - and an announced absence is exactly what C.07 means by a voluntarily unplayed round. Turning it off treats those rounds like forfeit losses instead. Either is defensible; changing it mid-tournament moves published standings."
              )}
            </div>
          </.setting_group>
        </div>

        <div class="actions form-actions">
          <button type="submit" class="pe-btn primary">{gettext("Save settings")}</button>
          <span :if={@note} class="ok-note" style="align-self: center">{@note}</span>
          <span :if={@error} class="error-note" style="align-self: center">{@error}</span>
        </div>
      </form>
    </Layouts.app>
    """
  end
end
