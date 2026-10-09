defmodule PairingsEngineWeb.SettingsOptionsLive do
  @moduledoc """
  The "Options" settings page (`/t/:id/settings/options`) - everything about
  *how* the tournament is paired: the pairing system and its variants (RR
  cycles, RR/Swiss match format - each locked once round 1 has been
  paired), the Swiss engine that does the actual pairing, the rating used
  for pairing, acceleration and the rate of play. Forbidden pairings and
  pairing rules have their own page since 0.79.0
  (`PairingsEngineWeb.SettingsRestrictionsLive`). The public-pairings publish delay moved
  to `PairingsEngineWeb.SettingsResultsLive` on 2026-08-29, with the rest of
  this tournament's public existence.
  Scoring (points per win/draw/loss, byes, SWAR's "Pt ABSENT"
  genuine-absence rule) has its own page - see
  `PairingsEngineWeb.SettingsScoringLive`. Pair-by-category lives on
  `PairingsEngineWeb.CategoriesLive`, next to the categories-enabled switch
  it depends on.
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport

  alias PairingsEngine.{Tournaments, Pairing, RateOfPlay}
  alias PairingsEngine.Tournaments.Tournament

  @pairing_system_options for ps <- Tournament.pairing_systems(),
                              do: {ps, Tournament.pairing_system_label(ps)}
  @rr_cycles_options for c <- Tournament.rr_cycles_values(),
                         do: {c, Tournament.rr_cycles_label(c)}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     socket
     |> attach_dirty_tracker()
     |> attach_fide_gate()
     |> assign(
       tournament: tournament,
       page_title: "#{tournament.name} · Settings",
       standard: tournament.standard,
       rate_of_play: tournament.rate_of_play,
       note: nil,
       error: nil,
       dirty: false,
       stale: false,
       # Which locked pairing-shape control (if any) the user just tried to
       # interact with - one of `:pairing_system`, `:pairing_engine`,
       # `:rr_cycles`, `:rr_match_format`, `:swiss_match_format`, or nil.
       locked_hint: nil,
       # Fields the arbiter has deliberately unlocked for THIS save, via the
       # "Unlock" button on the locked-field warning - see
       # `assign_pairing_locks/1` and the "unlock_field" event below. Never
       # written to the database and never carried past one save: it resets
       # to empty here on every mount (so leaving the page re-locks
       # everything) and again after `save_settings/4` succeeds (so a field
       # just saved goes right back to frozen, same as any other locked
       # field once round 1 is paired).
       unlocked_fields: MapSet.new(),
       # Holds the pending settings params while the "switching engine"
       # dialog is up; nil when no dialog is showing.
       engine_confirm: nil,
       # Which subject's form the pending dialog came from, so a confirmed
       # save reports back beside the button that was pressed.
       engine_confirm_section: nil,
       # Which subject's save produced the current `note`/`error`. Each card
       # saves on its own, so the feedback has to say WHICH one saved rather
       # than appearing once at the foot of the page.
       saved_section: nil
     )
     |> assign_pairing_locks()}
  end

  # Which pairing-shape settings are frozen. The rule itself lives in
  # `Tournaments.locked_fields/1`, which is also what refuses the write - so
  # what this page disables and what the context accepts cannot drift apart.
  # (They previously could: the lock was enforced *only* here, and any other
  # caller went straight through.)
  #
  # A field the arbiter has deliberately unlocked (`unlocked_fields`) is
  # subtracted here, so it renders enabled - `Tournaments.locked_fields/1`
  # itself doesn't know about the unlock and keeps naming the field frozen
  # (correctly: it goes right back to frozen the moment this save lands).
  defp assign_pairing_locks(socket) do
    tournament = socket.assigns.tournament

    # FIDE mode's locks are not opened by Unlock (`Tournaments.fide_locked_fields/1`),
    # so they are added back after the unlocked ones are taken out.
    fide_locked = Tournaments.fide_locked_fields(tournament)

    locked =
      tournament
      |> Tournaments.locked_fields()
      |> MapSet.new()
      |> MapSet.difference(socket.assigns.unlocked_fields)
      |> MapSet.union(MapSet.new(fide_locked))

    assign(socket,
      fide_locked: fide_locked,
      acceleration_locked?: :acceleration in fide_locked,
      paired_rounds: Pairing.paired_rounds_count(tournament.id),
      pairing_system_locked?: :pairing_system in locked,
      pairing_engine_locked?: :pairing_engine in locked,
      rr_cycles_locked?: :rr_cycles in locked,
      rr_reverse_last_two_locked?: :rr_reverse_last_two in locked,
      rr_match_format_locked?: :rr_match_format in locked,
      swiss_match_format_locked?: :swiss_match_format in locked,
      initial_colour_locked?: :initial_colour in locked,
      rating_method_locked?: :rating_method in locked,
      initial_order_tiebreak_locked?: :initial_order_tiebreak in locked,
      round_one_paired?: Tournaments.round_one_paired?(tournament.id),
      team_lineups_locked?: :team_lineups in locked
    )
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
           standard: tournament.standard,
           rate_of_play: tournament.rate_of_play,
           stale: false
         )
         |> assign_pairing_locks()}
    end
  end

  @impl true
  ## ---------- Public self-registration ----------

  # Guarded on the fields this page's own `locked_overlay/1` calls actually
  # send. `String.to_existing_atom/1` on an unguarded param is a crafted
  # event away from an `ArgumentError` that takes the sender's socket down
  # with it, and the atom table is not the caller's to grow either.
  @locked_fields ~w(pairing_system pairing_engine rr_cycles rr_reverse_last_two rr_match_format swiss_match_format initial_colour rating_method initial_order_tiebreak)

  def handle_event("locked_hint", %{"field" => field}, socket)
      when field in @locked_fields do
    {:noreply, assign(socket, locked_hint: String.to_existing_atom(field))}
  end

  def handle_event("locked_hint", _params, socket), do: {:noreply, socket}

  # Same allowlist, same reason: `unlock_field` is the "Unlock" button inside
  # `locked_hint_message/1`, which only ever names a field this page already
  # offered a locked_hint for. This is a UI convenience, not the security
  # boundary - `Tournaments.ensure_unlocked/3` is the one that actually
  # matters, and refuses regardless of what reaches it here (see its doc).
  def handle_event("unlock_field", %{"field" => field}, socket)
      when field in @locked_fields do
    field = String.to_existing_atom(field)

    {:noreply,
     socket
     |> update(:unlocked_fields, &MapSet.put(&1, field))
     |> assign_pairing_locks()}
  end

  def handle_event("unlock_field", _params, socket), do: {:noreply, socket}

  # `standard` and `rate_of_play` are tracked as their own assigns because the
  # "Rate of play" select's option list depends on which "Type" is picked.
  def handle_event("standard_change", %{"tournament" => %{"standard" => new_standard}}, socket) do
    list = RateOfPlay.list_for(new_standard)
    current = socket.assigns.rate_of_play
    new_rate = if current in list, do: current, else: ""

    {:noreply, assign(socket, standard: new_standard, rate_of_play: new_rate)}
  end

  def handle_event("save", %{"tournament" => params} = payload, socket) do
    # Each card is its own form and posts the subject it belongs to. Defaults
    # to "pairing" for a hand-built event with no section (tests do this).
    section = Map.get(payload, "section", "pairing")

    params =
      params
      |> apply_rate_of_play_override()
      |> strip_locked_pairing_fields(socket.assigns)

    base = Tournaments.get_tournament!(socket.assigns.tournament.id)

    with :proceed <- fide_gate(socket, "save", payload, base, params) do
      # Switching the engine is the one setting on this page that changes who
      # computes the pairings, so it asks first rather than saving silently
      # with an explanation buried in a hint the arbiter has already scrolled
      # past.
      #
      # The direction reversed on 2026-08-25. It used to guard the way IN to
      # Ainalrami, when JaVaFo was the default and the endorsed one. Now the
      # choice that deserves a second look is the way OUT: JaVaFo implements
      # C.04.3 as it stood until 31 January 2026 and has not been updated for
      # the edition effective 1 February 2026, so selecting it means pairing a
      # 2026 tournament by superseded rules.
      if switching_to_javafo?(base, params) do
        {:noreply, assign(socket, engine_confirm: params, engine_confirm_section: section)}
      else
        save_settings(socket, base, params, section)
      end
    end
  end

  def handle_event("confirm_engine", _params, socket) do
    case socket.assigns.engine_confirm do
      nil ->
        {:noreply, socket}

      params ->
        base = Tournaments.get_tournament!(socket.assigns.tournament.id)
        section = socket.assigns.engine_confirm_section || "pairing"

        save_settings(
          assign(socket, engine_confirm: nil, engine_confirm_section: nil),
          base,
          params,
          section
        )
    end
  end

  def handle_event("cancel_engine", _params, socket) do
    {:noreply, assign(socket, engine_confirm: nil)}
  end

  ## ---------- helpers ----------

  # Server-side enforcement of the locks: drop any submitted value for a
  # locked field regardless of the HTML `disabled` attribute.
  # Only when it is actually a CHANGE. Re-saving the page with JaVaFo
  # already selected must not re-prompt, or every unrelated edit on a
  # tournament already using it drags the dialog back up.
  defp switching_to_javafo?(base, params) do
    params["pairing_engine"] == "javafo" and base.pairing_engine != "javafo"
  end

  defp save_settings(socket, base, params, section) do
    # The fields deliberately unlocked FOR THIS SAVE - read from the
    # LiveView's own socket, never from `params`, so a crafted "save" event
    # can carry any locked field it likes and still be refused by
    # `Tournaments.ensure_unlocked/3`: only a field this process itself put
    # in `unlocked_fields` (via a real "unlock_field" event) ever reaches
    # the `unlock:` option below.
    unlock_fields = MapSet.to_list(socket.assigns.unlocked_fields)

    case Tournaments.update_tournament(base, params, unlock: unlock_fields) do
      {:ok, tournament} ->
        log_settings_change(socket, base, tournament)
        log_unlocked_field_changes(socket, base, tournament, unlock_fields)
        log_compliance_departures(socket, base, tournament)

        {:noreply,
         socket
         |> assign(
           tournament: tournament,
           standard: tournament.standard,
           rate_of_play: tournament.rate_of_play,
           note: save_note(base, tournament),
           error: nil,
           saved_section: section,
           dirty: false,
           stale: false,
           # Landed - the field is exactly as frozen as any other locked
           # field once round 1 is paired, so the unlock doesn't outlive
           # the save that used it.
           unlocked_fields: MapSet.new()
         )
         |> assign_pairing_locks()}

      {:error, changeset} ->
        {:noreply,
         assign(socket, error: error_text(changeset), note: nil, saved_section: section)}
    end
  end

  attr :section, :string, required: true
  attr :note, :string, default: nil
  attr :error, :string, default: nil
  attr :saved, :string, default: nil

  # One save button per subject, with that subject's own feedback beside it.
  # A single button under everything meant scrolling the whole page to save a
  # single select, and a bare "Saved." at the foot said nothing about WHICH
  # of the settings above it had just been written.
  defp section_actions(assigns) do
    ~H"""
    <div class="actions form-actions">
      <button type="submit" class="pe-btn primary">{gettext("Save")}</button>
      <span :if={@note && @saved == @section} class="ok-note" style="align-self: center">
        {@note}
      </span>

      <span :if={@error && @saved == @section} class="error-note" style="align-self: center">
        {@error}
      </span>
    </div>
    """
  end

  # `assigns.*_locked?` already factor in a deliberate "Unlock" click (see
  # `assign_pairing_locks/1`), so a field the arbiter unlocked this session
  # passes straight through here - it's `save_settings/4`'s `unlock:` option
  # to `Tournaments.update_tournament/3`, not this strip, that has to name it
  # again for the write to actually go through.
  defp strip_locked_pairing_fields(params, assigns) do
    params
    |> maybe_drop_locked("pairing_system", assigns.pairing_system_locked?)
    |> maybe_drop_locked("pairing_engine", assigns.pairing_engine_locked?)
    |> maybe_drop_locked("rr_cycles", assigns.rr_cycles_locked?)
    |> maybe_drop_locked("rr_reverse_last_two", assigns.rr_reverse_last_two_locked?)
    |> maybe_drop_locked("rr_match_format", assigns.rr_match_format_locked?)
    |> maybe_drop_locked("swiss_match_format", assigns.swiss_match_format_locked?)
    |> maybe_drop_locked("initial_colour", assigns.initial_colour_locked?)
    |> maybe_drop_locked("rating_method", assigns.rating_method_locked?)
    |> maybe_drop_locked("initial_order_tiebreak", assigns.initial_order_tiebreak_locked?)
    |> maybe_drop_locked("team_lineups", assigns.team_lineups_locked?)
    |> maybe_drop_locked("round_one_absentees_late", assigns.round_one_paired?)
  end

  defp maybe_drop_locked(params, _key, false), do: params
  defp maybe_drop_locked(params, key, true), do: Map.delete(params, key)

  # Player ratings are looked up per-cadence (`PairingsEngine.Fide.
  # rating_for_tempo/2` - Standard/Rapid/Blitz), so a saved change to
  # `standard` silently leaves every already-registered player's stored
  # `fide_rating` at whatever cadence was in effect when they were last
  # looked up or refreshed. Nothing re-fetches it automatically (that would
  # mean a settings save silently rewriting player data) - just flag it so
  # the arbiter knows to re-run the refresh from the Players page.
  defp save_note(%{standard: same}, %{standard: same}), do: "Saved."

  defp save_note(_before, tournament) do
    "Saved. Tempo changed to #{RateOfPlay.standard_options() |> Map.new() |> Map.get(tournament.standard, tournament.standard)} " <>
      "- FIDE ratings shown are still whichever cadence was last looked up; " <>
      "refresh them from the Players page to pick up the new one."
  end

  defp apply_rate_of_play_override(params) do
    case String.trim(Map.get(params, "rate_of_play_other", "")) do
      "" -> params
      other -> Map.put(params, "rate_of_play", other)
    end
  end

  defp rate_of_play_select_options(standard, current),
    do: RateOfPlay.select_options(standard, current)

  defp standard_options, do: RateOfPlay.standard_options()
  defp pairing_system_options, do: @pairing_system_options
  defp rr_cycles_options, do: @rr_cycles_options

  # locked_overlay/1 + locked_hint_message/1 now live in SettingsSupport -
  # <.setting_toggle> needs them too.
  #
  # Each of these is its own function (rather than one shared sentence)
  # because `locked_hint_message/1` requires a specific `warning` and each
  # field breaks a different thing - see `Tournaments.locked_fields/1`'s
  # moduledoc for the reasoning each one is paraphrasing.
  # Where the way out of a FIDE-mode lock is, for `locked_hint_message/1`;
  # nil keeps its ordinary Unlock button.
  defp fide_path(tournament, fide_locked, field) do
    if field in fide_locked, do: ~p"/t/#{tournament.id}/settings/fide"
  end

  defp pairing_system_warning,
    do:
      gettext(
        "Swiss, round robin and Keizer decide colours, floats, repeats and what round comes next in completely different ways. Rounds already paired were paired under the current system; switching now doesn't repair them to match - it leaves what's already on the board decided by one system while everything from here on is judged by another."
      )

  defp pairing_engine_warning,
    do:
      gettext(
        "JaVaFo and Ainalrami are two independent implementations of the pairing rules. A round already on the board was decided by whichever engine was configured at the time; switching now hands the new engine a history it did not produce, so every colour, float and rematch judgement from here on is made against a bracket shape the other engine chose."
      )

  # TRF26 record 172's codes, with what each means.
  defp rating_method_label("FIDE"), do: gettext("FIDE rating only (FIDE)")
  defp rating_method_label("NRO"), do: gettext("National rating only (NRO)")

  defp rating_method_label("FIDON"),
    do: gettext("FIDE rating, else national (FIDON)")

  defp rating_method_label("NIDOF"),
    do: gettext("National rating, else FIDE (NIDOF)")

  defp rating_method_label("HBFN"),
    do: gettext("Highest of FIDE, national and manual (HBFN)")

  defp rating_method_label("OTHER"), do: gettext("Manual rating per player (OTHER)")

  defp initial_order_tiebreak_label("name"), do: gettext("Alphabetically")
  defp initial_order_tiebreak_label("fide_id"), do: gettext("FIDE ID, lowest first")
  defp initial_order_tiebreak_label("age_older"), do: gettext("Oldest first")
  defp initial_order_tiebreak_label("age_younger"), do: gettext("Youngest first")

  defp late_entry_numbering_label("after"), do: gettext("After the field (leaves FIDE mode)")

  defp late_entry_numbering_label("end"),
    do: gettext("After the field (kept from before By rating was the default)")

  defp late_entry_numbering_label("rating"), do: gettext("By rating (FIDE)")

  defp rating_method_warning,
    do:
      gettext(
        "Round 1's pairing numbers were given by this setting. Changing it now renumbers nobody already numbered; it changes where a later late entrant is placed and, for the rating method, the rating the tie-breaks read."
      )

  defp initial_colour_warning,
    do:
      gettext(
        "The initial colour decided who had White on every board of round 1, and on every later board where both players had yet to play. Changing it now doesn't recolour those boards; it tells the engine a different starting colour than the one the boards already on the board were paired with."
      )

  defp rr_cycles_warning,
    do:
      gettext(
        "This decides how long the round-robin schedule is supposed to run for. Rounds already paired came from the schedule the current setting implies; changing it now doesn't rewrite what already happened, so the cycle count and the rounds actually on the board can end up disagreeing about how long this tournament is."
      )

  defp rr_reverse_last_two_warning,
    do:
      gettext(
        "This decides which pairing the second-to-last round of the first cycle gets. That round is already paired, so changing it now would make the rest of the schedule disagree with the rounds on the board."
      )

  defp rr_match_format_warning,
    do:
      gettext(
        "Match format pairs round N and N+1 as one immediate two-game rematch - round N+1 is a fixed, colour-reversed mirror of round N, not an independent pairing. Turning this on or off after rounds already exist changes what future rounds mean without changing what already happened, so a round already on the board can stop matching what the schedule now says it should have been."
      )

  defp swiss_match_format_warning,
    do:
      gettext(
        "Match format pairs round N and N+1 as one immediate two-game rematch - the second leg is inserted as an exact colour-reversed mirror of the first, with no independent pairing decision behind it. Turning this on or off after rounds already exist changes what future rounds mean without changing what already happened, so a round already on the board can stop matching what the schedule now says it should have been."
      )

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
      active="settings"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>

          <p class="subtitle" style="margin: 0">{gettext("Settings - Options")}</p>
        </div>
        <span class={["badge", @tournament.status == "setup" && "muted"]}>{@tournament.status}</span>
      </div>
      <.settings_subnav tournament={@tournament} active={:options} />
      <.stale_banner stale={@stale} />
      <.fide_exit_dialog
        id="fide-gate"
        step={@fide_gate && @fide_gate.step}
        reasons={(@fide_gate && @fide_gate.reasons) || []}
      /> <.compliance_notice tournament={@tournament} />
      <form id="pairing-settings-form" phx-submit="save">
        <input type="hidden" name="section" value="pairing" />
        <div class="card">
          <h2>{gettext("Pairing")}</h2>

          <.setting_group>
            <.setting_field label={gettext("Pairing system")}>
              <div class="locked-wrap">
                <select name="tournament[pairing_system]" disabled={@pairing_system_locked?}>
                  <option
                    :for={{val, label} <- pairing_system_options()}
                    value={val}
                    selected={@tournament.pairing_system == val}
                  >
                    {label}
                  </option>
                </select>
                <.locked_overlay field={:pairing_system} locked?={@pairing_system_locked?} />
              </div>

              <.locked_hint_message
                field={:pairing_system}
                locked_hint={@locked_hint}
                warning={pairing_system_warning()}
                fide_path={fide_path(@tournament, @fide_locked, :pairing_system)}
              />
            </.setting_field>

            <.setting_field
              label={gettext("Swiss engine")}
              hint={
                gettext(
                  "Swiss only - round robin and Keizer compute their own pairings and never consult this."
                )
              }
            >
              <div class="locked-wrap">
                <select name="tournament[pairing_engine]" disabled={@pairing_engine_locked?}>
                  <option value="javafo" selected={@tournament.pairing_engine == "javafo"}>
                    {gettext("JaVaFo - external, implements the 2017 rules")}
                  </option>

                  <option value="ainalrami" selected={@tournament.pairing_engine == "ainalrami"}>
                    {gettext("Ainalrami - built in, implements the 2026 rules (default)")}
                  </option>
                </select>
                <.locked_overlay field={:pairing_engine} locked?={@pairing_engine_locked?} />
              </div>

              <.locked_hint_message
                field={:pairing_engine}
                locked_hint={@locked_hint}
                warning={pairing_engine_warning()}
              />
              <span class="hint">
                <.rich_text text={
                  gettext(
                    "%[engine] is the default. It is built into the app - no Java, nothing to install - and it implements C.04.3 as it stands from %[date], the current edition."
                  )
                }>
                  <:part name="engine"><strong>Ainalrami</strong></:part>

                  <:part name="date"><strong>{gettext("1 February 2026")}</strong></:part>
                </.rich_text>
              </span>

              <span class="hint">
                <.rich_text text={
                  gettext(
                    "%[engine] is the external engine this app paired with first. It implements the %[edition] of the same rules and has not been updated for the current one, so the two disagree on roughly 4% of rounds - that gap is the size of the rules change, not a fault in either."
                  )
                }>
                  <:part name="engine"><strong>JaVaFo</strong></:part>

                  <:part name="edition"><strong>{gettext("2017 edition")}</strong></:part>
                </.rich_text>
              </span>

              <span class="hint">
                <.rich_text text={
                  gettext(
                    "Ainalrami is checked against bbpPairings, an independent implementation of the same 2026 rules, by replaying whole generated tournaments and diffing every board: %[pairings], with two disagreements that are both defects in bbpPairings. A third implementation agrees with it on both. Forbidden pairings, club and federation exclusions and acceleration are all supported; any TRF extension it does not implement makes it refuse the round and say so, rather than quietly ignoring a rule you set."
                  )
                }>
                  <:part name="pairings">
                    <strong>{gettext("2.5 billion individual pairings")}</strong>
                  </:part>
                </.rich_text>
              </span>

              <span :if={@tournament.fide_homologated} class="error-note">
                <.rich_text text={
                  gettext(
                    "This tournament is marked %[flag] (Settings → FIDE). Both engines are allowed, and the choice is which edition of the rules its boards follow: Ainalrami pairs by the one in force since 1 February 2026, JaVaFo by the 2017 one it was last built for. Neither is a settled paperwork position - it is yours to make."
                  )
                }>
                  <:part name="flag"><strong>{gettext("FIDE-homologated")}</strong></:part>
                </.rich_text>
              </span>
            </.setting_field>

            <.setting_field
              label={gettext("Initial colour")}
              hint={
                gettext(
                  "Swiss only. FIDE draws it by lot before round 1, and it decides who has White on round 1's boards. Left on drawn by lot, it is drawn when round 1 is paired and then kept."
                )
              }
            >
              <div class="locked-wrap">
                <select
                  id="initial-colour-select"
                  name="tournament[initial_colour]"
                  disabled={@initial_colour_locked?}
                >
                  <option
                    :for={value <- Tournament.initial_colours()}
                    value={value}
                    selected={@tournament.initial_colour == value}
                  >
                    {initial_colour_label(value)}
                  </option>
                </select>
                <.locked_overlay field={:initial_colour} locked?={@initial_colour_locked?} />
              </div>

              <.locked_hint_message
                field={:initial_colour}
                locked_hint={@locked_hint}
                warning={initial_colour_warning()}
              />
              <span :if={initial_colour_status(@tournament)} id="initial-colour-status" class="hint">
                {initial_colour_status(@tournament)}
              </span>
            </.setting_field>

            <.setting_field
              label={gettext("Tournament rating")}
              hint={
                gettext(
                  "The rating that ranks the players and so gives them their pairing numbers, and that the rating-based tie-breaks read. A manual rating is typed per player on the Players page."
                )
              }
            >
              <div class="locked-wrap">
                <select
                  id="rating-method-select"
                  name="tournament[rating_method]"
                  disabled={@rating_method_locked?}
                >
                  <option
                    :for={value <- Tournament.rating_methods()}
                    value={value}
                    selected={@tournament.rating_method == value}
                  >
                    {rating_method_label(value)}
                  </option>
                </select>
                <.locked_overlay field={:rating_method} locked?={@rating_method_locked?} />
              </div>

              <.locked_hint_message
                field={:rating_method}
                locked_hint={@locked_hint}
                warning={rating_method_warning()}
              />
            </.setting_field>

            <.setting_field
              label={gettext("Equal rating and title")}
              hint={
                gettext(
                  "How players level on rating and FIDE title are ordered for their pairing numbers. FIDE orders them alphabetically unless the tournament announced another rule."
                )
              }
            >
              <div class="locked-wrap">
                <select
                  id="initial-order-tiebreak-select"
                  name="tournament[initial_order_tiebreak]"
                  disabled={@initial_order_tiebreak_locked?}
                >
                  <option
                    :for={value <- Tournament.initial_order_tiebreaks()}
                    value={value}
                    selected={@tournament.initial_order_tiebreak == value}
                  >
                    {initial_order_tiebreak_label(value)}
                  </option>
                </select>

                <.locked_overlay
                  field={:initial_order_tiebreak}
                  locked?={@initial_order_tiebreak_locked?}
                />
              </div>

              <.locked_hint_message
                field={:initial_order_tiebreak}
                locked_hint={@locked_hint}
                warning={rating_method_warning()}
              />
            </.setting_field>

            <.setting_field
              label={gettext("Late entrants' pairing numbers")}
              hint={
                gettext(
                  "Swiss only. By rating, the default, a player who joins after numbers were given gets the number their rating earns and everybody below moves down one (FIDE C.04.2 2.4); the rounds already played keep their boards. After the field gives them the next free number instead, which the FIDE rules do not, so choosing it takes the tournament out of FIDE mode."
                )
              }
            >
              <select id="late-entry-numbering-select" name="tournament[late_entry_numbering]">
                <option
                  :for={value <- Tournament.late_entry_numbering_choices(@tournament)}
                  value={value}
                  selected={@tournament.late_entry_numbering == value}
                >
                  {late_entry_numbering_label(value)}
                </option>
              </select>
            </.setting_field>

            <.setting_toggle
              :if={
                @tournament.pairing_system == "swiss" and @tournament.acceleration != "baku" and
                  !Tournament.team?(@tournament)
              }
              name="tournament[round_one_absentees_late]"
              label={gettext("Players absent from round 1 are late entries (FIDE C.04.2 2.4)")}
              hint={
                gettext(
                  "They get no pairing number when round 1 is paired and are numbered when they arrive, by the setting above. On for every tournament created from version 0.79 on; off, the old way, for older and imported ones. Can be switched until round 1 is paired."
                )
              }
              checked={@tournament.round_one_absentees_late}
              disabled={@round_one_paired?}
            >
              <span
                :if={@round_one_paired?}
                id="round-one-absentees-late-locked"
                class="hint"
                style="display: block"
              >
                {gettext(
                  "Locked: round 1 is paired, and switching would renumber players in rounds already played."
                )}
              </span>
            </.setting_toggle>

            <.setting_field
              label={gettext("Cycles")}
              hint={
                gettext(
                  "Round robin only - a Swiss plays the number of rounds set under Settings - Tournament, and never pairs the same opponents twice."
                )
              }
            >
              <div class="locked-wrap">
                <select name="tournament[rr_cycles]" disabled={@rr_cycles_locked?}>
                  <option
                    :for={{val, label} <- rr_cycles_options()}
                    value={val}
                    selected={@tournament.rr_cycles == val}
                  >
                    {label}
                  </option>
                </select>
                <.locked_overlay field={:rr_cycles} locked?={@rr_cycles_locked?} />
              </div>

              <.locked_hint_message
                field={:rr_cycles}
                locked_hint={@locked_hint}
                warning={rr_cycles_warning()}
                fide_path={fide_path(@tournament, @fide_locked, :rr_cycles)}
              />
            </.setting_field>

            <.setting_toggle
              :if={
                @tournament.pairing_system == "round_robin" and @tournament.rr_cycles == 2 and
                  !Tournament.team?(@tournament)
              }
              name="tournament[rr_reverse_last_two]"
              label={
                gettext("Play the last two rounds of the first cycle in reverse order (FIDE C.05)")
              }
              hint={
                gettext(
                  "FIDE's recommendation for a double round robin: nobody then has the same colour three times running where the two cycles meet. Exported to the TRF as FIDE_DOUBLEROUNDROBIN."
                )
              }
              checked={@tournament.rr_reverse_last_two}
              disabled={@rr_reverse_last_two_locked?}
              field={:rr_reverse_last_two}
              locked?={@rr_reverse_last_two_locked?}
              locked_hint={@locked_hint}
              warning={rr_reverse_last_two_warning()}
            />
            <.setting_toggle
              name="tournament[rr_match_format]"
              label={
                gettext(
                  "Round robin match format (each pairing played twice in a row, colours reversed)"
                )
              }
              hint={gettext("Round robin only - Swiss has its own match format setting below")}
              checked={@tournament.rr_match_format}
              disabled={@rr_match_format_locked?}
              field={:rr_match_format}
              locked?={@rr_match_format_locked?}
              locked_hint={@locked_hint}
              warning={rr_match_format_warning()}
            />
            <.setting_field
              label={gettext("Keizer top value (blank = automatic)")}
              hint={gettext("Keizer only")}
            >
              <input
                type="number"
                name="tournament[keizer_top_value]"
                value={@tournament.keizer_top_value}
                min="1"
              />
            </.setting_field>

            <.setting_field
              label={gettext("Acceleration")}
              hint={gettext("Swiss only - round robin and Keizer ignore this setting")}
            >
              <select name="tournament[acceleration]" disabled={@acceleration_locked?}>
                <option value="none" selected={@tournament.acceleration == "none"}>
                  {gettext("None")}
                </option>

                <option value="baku" selected={@tournament.acceleration == "baku"}>
                  {gettext("Baku acceleration (FIDE C.04.7)")}
                </option>
              </select>

              <.fide_lock_note
                id="acceleration-fide-lock"
                tournament={@tournament}
                fide_locked={@fide_locked}
                fields={[:acceleration]}
              />
              <span
                :if={
                  @tournament.extra_points_mode == "acceleration" or @tournament.count_extra_points
                }
                id="acceleration-extra-points-hint"
                class="hint"
              >
                <.rich_text text={
                  gettext(
                    "This tournament's extra points go to the pairing (%[page]), so Baku cannot be added on top: the engine gets one set of virtual points per player. Switch extra points to handicap with counting off first."
                  )
                }>
                  <:part name="page">
                    <.link navigate={~p"/t/#{@tournament.id}/settings/extra-points"}>
                      {gettext("Extra points")}
                    </.link>
                  </:part>
                </.rich_text>
              </span>
            </.setting_field>

            <.setting_toggle
              name="tournament[swiss_match_format]"
              label={
                gettext("Swiss match format (each pairing played twice in a row, colours reversed)")
              }
              hint={
                gettext("Swiss only - requires an even number of rounds (each match is 2 rounds)")
              }
              checked={@tournament.swiss_match_format}
              disabled={@swiss_match_format_locked?}
              field={:swiss_match_format}
              locked?={@swiss_match_format_locked?}
              locked_hint={@locked_hint}
              warning={swiss_match_format_warning()}
            />
          </.setting_group>
        </div>
        <.section_actions section="pairing" note={@note} error={@error} saved={@saved_section} />
      </form>

      <form
        :if={Tournament.team?(@tournament)}
        id="team-settings-form"
        phx-submit="save"
      >
        <input type="hidden" name="section" value="teams" />
        <div class="card">
          <h2>{gettext("Teams")}</h2>

          <.setting_group>
            <.setting_field
              label={gettext("Line-ups")}
              hint={
                gettext(
                  "Required: a team plays only with players on its roster, and a board it cannot fill is the opponent's forfeit win. Optional: teams can be paired with no players entered - every match gets all its boards, a result goes on a board with nobody at it or on the match as one score, and a team sits a round out only when it is marked absent or withdrawn. Not FIDE-rated: a board without two players is not a game for the rating report."
                )
              }
            >
              <select
                id="team-lineups"
                name="tournament[team_lineups]"
                disabled={@team_lineups_locked?}
              >
                <option value="required" selected={@tournament.team_lineups == "required"}>
                  {gettext("Required (FIDE)")}
                </option>

                <option value="optional" selected={@tournament.team_lineups == "optional"}>
                  {gettext("Optional: pair teams without players")}
                </option>
              </select>

              <span :if={@team_lineups_locked?} class="hint">
                {gettext("Locked: round 1 has been paired.")}
              </span>
            </.setting_field>

            <.setting_field
              label={gettext("Team rating for the order of the teams")}
              hint={
                gettext(
                  "How the Teams page rates a team and orders the teams before round 1 (C.04.6 1.1.2 leaves this to the event's rules). A rating typed in for a team on the Teams page is always used instead."
                )
              }
            >
              <select id="team-rating-method" name="tournament[team_rating_method]">
                <option value="olympiad" selected={@tournament.team_rating_method == "olympiad"}>
                  {gettext("Olympiad: average of the highest-rated players, one per board (default)")}
                </option>

                <option
                  value="first_boards"
                  selected={@tournament.team_rating_method == "first_boards"}
                >
                  {gettext("Average of the first boards, in board order")}
                </option>

                <option value="roster" selected={@tournament.team_rating_method == "roster"}>
                  {gettext("Average of the whole roster")}
                </option>

                <option value="manual" selected={@tournament.team_rating_method == "manual"}>
                  {gettext("Typed in for each team")}
                </option>
              </select>
            </.setting_field>

            <.setting_field
              label={gettext("Rating of an unrated player")}
              hint={
                gettext(
                  "What a player without a rating, and a board nobody sits at, count as in a team's rating. 1400 is the FIDE rating floor (Rating Regulations 2024 Art. 7.1.4; the World University Team Championship regulations Art. 5.2.4 give unrated players 1400; the Olympiad Pairing Rules of 2012 Art. 7 gave them the floor). C.04.6 leaves it to the event's rules. Seeds already set never change by themselves."
                )
              }
            >
              <input
                id="team-unrated-rating"
                type="number"
                name="tournament[team_unrated_rating]"
                value={@tournament.team_unrated_rating}
                min="0"
                max="4000"
              />
            </.setting_field>
          </.setting_group>
        </div>
        <.section_actions section="teams" note={@note} error={@error} saved={@saved_section} />
      </form>

      <form id="play-settings-form" phx-submit="save">
        <input type="hidden" name="section" value="play" />
        <div class="card">
          <h2>{gettext("Tournament type & rate of play")}</h2>

          <.setting_group>
            <.setting_field label={gettext("Type")}>
              <select name="tournament[standard]" phx-change="standard_change">
                <option
                  :for={{val, label} <- standard_options()}
                  value={val}
                  selected={@standard == val}
                >
                  {label}
                </option>
              </select>
            </.setting_field>

            <.setting_field label={gettext("Rate of play")} required>
              <select name="tournament[rate_of_play]">
                <option
                  :for={opt <- rate_of_play_select_options(@standard, @rate_of_play)}
                  value={opt}
                  selected={opt == @rate_of_play}
                >
                  {if opt == "", do: "- none -", else: opt}
                </option>
              </select>
            </.setting_field>

            <.setting_field label={gettext("Other rate of play (overrides the select above)")}>
              <input
                type="text"
                name="tournament[rate_of_play_other]"
                value=""
                placeholder={gettext("e.g. 40 min + 10 sec/move")}
              />
            </.setting_field>
          </.setting_group>
        </div>
        <.section_actions section="play" note={@note} error={@error} saved={@saved_section} />
      </form>

      <div class="card" id="restrictions-moved">
        <h2>{gettext("Forbidden pairings")}</h2>

        <p class="hint" style="margin: 0">
          {gettext("Forbidden pairs, club and federation rules and the wishes have their own page:")}
          <.link navigate={~p"/t/#{@tournament.id}/settings/restrictions"}>
            {gettext("Forbidden pairings")}
          </.link>
        </p>
      </div>

      <div
        :if={@engine_confirm}
        class="modal-overlay"
        phx-window-keydown="cancel_engine"
        phx-key="escape"
      >
        <div
          class="modal-card"
          phx-click-away="cancel_engine"
          style="max-width: 640px"
          id="engine-confirm-dialog"
          role="dialog"
          aria-modal="true"
          aria-labelledby="engine-confirm-title"
          tabindex="-1"
          phx-hook="DialogFocus"
          data-dialog
        >
          <h2 id="engine-confirm-title">{gettext("Switch to JaVaFo?")}</h2>

          <p class="hint">
            <strong>{gettext("This pairs the tournament by superseded rules.")}</strong>
            <.rich_text text={
              gettext(
                "JaVaFo implements C.04.3 as it stood until %[date] and has not been updated for the edition effective 1 February 2026. It is a good engine; it is answering an older rulebook. The two disagree on roughly 4% of rounds, and that gap is the size of the rules change."
              )
            }>
              <:part name="date"><strong>{gettext("31 January 2026")}</strong></:part>
            </.rich_text>
          </p>

          <p class="hint">
            <.rich_text text={
              gettext(
                "There are real reasons to choose it. Most tournament software has shipped JaVaFo for years, so an arbiter reconciling this event against another program will find %[matching] boards - and a board that matches is a board nobody has to argue about."
              )
            }>
              <:part name="matching"><strong>{gettext("matching")}</strong></:part>
            </.rich_text>
          </p>

          <p class="hint">
            {gettext(
              "You can switch back at any time before round one is paired. Once a round exists the engine is locked, because changing pairing system mid-tournament is not something the regulations allow."
            )}
          </p>

          <p :if={@tournament.fide_homologated} class="error-note">
            <strong>{gettext("This tournament is FIDE-homologated.")}</strong>
            <.rich_text text={
              gettext(
                "That does not stop you, but it raises the stakes on the paragraph above: this event will be %[rated], and its boards will have been paired by the 2017 edition of the rules rather than the one in force. If a result is queried, that is the answer you will be giving."
              )
            }>
              <:part name="rated"><em>{gettext("submitted for rating")}</em></:part>
            </.rich_text>
          </p>

          <div class="actions">
            <button type="button" class="pe-btn primary" phx-click="confirm_engine">
              {gettext("Use JaVaFo")}
            </button>

            <button type="button" class="pe-btn" phx-click="cancel_engine">
              {gettext("Keep Ainalrami")}
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
