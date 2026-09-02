defmodule PairingsEngineWeb.SettingsOptionsLive do
  @moduledoc """
  The "Options" settings page (`/t/:id/settings/options`) - everything about
  *how* the tournament is paired: the pairing system and its variants (RR
  cycles, RR/Swiss match format - each locked once round 1 has been
  paired), the Swiss engine that does the actual pairing, the rating used
  for pairing, acceleration, the rate of play, and the forbidden-pairing /
  club-federation exclusion rules. The public-pairings publish delay moved
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

  alias PairingsEngine.{Audit, Tournaments, Pairing, Exclusions, RateOfPlay}
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
       forbidden_pairing_error: nil,
       # Holds the pending settings params while the "switching engine"
       # dialog is up; nil when no dialog is showing.
       engine_confirm: nil,
       # Which subject's form the pending dialog came from, so a confirmed
       # save reports back beside the button that was pressed.
       engine_confirm_section: nil,
       # Which subject's save produced the current `note`/`error`. Each card
       # saves on its own, so the feedback has to say WHICH one saved rather
       # than appearing once at the foot of the page.
       saved_section: nil,
       club_exclusion_mode: tournament.club_exclusion,
       fed_exclusion_mode: tournament.fed_exclusion,
       exclusion_error: nil
     )
     |> assign_pairing_locks()
     |> assign_forbidden_pairings()}
  end

  # Which pairing-shape settings are frozen. The rule itself lives in
  # `Tournaments.locked_fields/1`, which is also what refuses the write - so
  # what this page disables and what the context accepts cannot drift apart.
  # (They previously could: the lock was enforced *only* here, and any other
  # caller went straight through.)
  defp assign_pairing_locks(socket) do
    tournament = socket.assigns.tournament
    locked = Tournaments.locked_fields(tournament)

    assign(socket,
      paired_rounds: Pairing.paired_rounds_count(tournament.id),
      pairing_system_locked?: :pairing_system in locked,
      pairing_engine_locked?: :pairing_engine in locked,
      rr_cycles_locked?: :rr_cycles in locked,
      rr_match_format_locked?: :rr_match_format in locked,
      swiss_match_format_locked?: :swiss_match_format in locked
    )
  end

  defp assign_forbidden_pairings(socket) do
    tournament = socket.assigns.tournament
    players = Tournaments.list_players(tournament.id) |> Enum.sort_by(& &1.name)

    assign(socket,
      forbidden_pairings: Tournaments.list_forbidden_pairings(tournament.id),
      forbidden_pairing_players: players,
      excluded_pair_count: Exclusions.excluded_pairs(tournament, players) |> MapSet.size()
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
           club_exclusion_mode: tournament.club_exclusion,
           fed_exclusion_mode: tournament.fed_exclusion,
           stale: false
         )
         |> assign_pairing_locks()
         |> assign_forbidden_pairings()}
    end
  end

  # Self-clearing timer for the "locked" hint set by the "locked_hint" event -
  # only clears if it's still showing the same field's message.
  def handle_info({:clear_locked_hint, field}, socket) do
    if socket.assigns.locked_hint == field do
      {:noreply, assign(socket, locked_hint: nil)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  ## ---------- Public self-registration ----------

  # Guarded on the fields this page's own `locked_overlay/1` calls actually
  # send. `String.to_existing_atom/1` on an unguarded param is a crafted
  # event away from an `ArgumentError` that takes the sender's socket down
  # with it, and the atom table is not the caller's to grow either.
  @locked_fields ~w(pairing_system pairing_engine rr_cycles rr_match_format swiss_match_format)

  def handle_event("locked_hint", %{"field" => field}, socket)
      when field in @locked_fields do
    field = String.to_existing_atom(field)
    Process.send_after(self(), {:clear_locked_hint, field}, 3000)
    {:noreply, assign(socket, locked_hint: field)}
  end

  def handle_event("locked_hint", _params, socket), do: {:noreply, socket}

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

    # Switching the engine is the one setting on this page that changes who
    # computes the pairings, so it asks first rather than saving silently
    # with an explanation buried in a hint the arbiter has already scrolled
    # past.
    #
    # The direction reversed on 2026-08-25. It used to guard the way IN to
    # Ainalrami, when JaVaFo was the default and the endorsed one. Now the
    # choice that deserves a second look is the way OUT: JaVaFo implements
    # C.04.3 as it stood in 2022 and has not been updated for the edition
    # effective 1 February 2026, so selecting it means pairing a 2026
    # tournament by superseded rules.
    if switching_to_javafo?(base, params) do
      {:noreply, assign(socket, engine_confirm: params, engine_confirm_section: section)}
    else
      save_settings(socket, base, params, section)
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

  ## ---------- Forbidden pairings ----------

  def handle_event("add_forbidden_pairing", %{"player_a_id" => a, "player_b_id" => b}, socket) do
    with {a_id, ""} <- Integer.parse(a),
         {b_id, ""} <- Integer.parse(b) do
      case Tournaments.add_forbidden_pairing(socket.assigns.tournament, a_id, b_id) do
        {:ok, forbidden_pairing} ->
          Audit.log(
            socket.assigns.tournament.id,
            socket.assigns.current_scope,
            "forbidden_pairing.added",
            %{
              player_a_id: forbidden_pairing.player_a_id,
              player_b_id: forbidden_pairing.player_b_id
            }
          )

          {:noreply,
           socket
           |> assign(forbidden_pairing_error: nil)
           |> assign_forbidden_pairings()}

        {:error, :same_player} ->
          {:noreply, assign(socket, forbidden_pairing_error: "Choose two different players")}

        {:error, :invalid_player} ->
          {:noreply,
           assign(socket, forbidden_pairing_error: "Choose two players from this tournament")}

        {:error, :already_forbidden} ->
          {:noreply, assign(socket, forbidden_pairing_error: "That pair is already forbidden")}

        {:error, :archived} ->
          {:noreply, assign(socket, forbidden_pairing_error: error_text(:archived))}

        {:error, _reason} ->
          {:noreply,
           assign(socket, forbidden_pairing_error: "Could not add that forbidden pairing")}
      end
    else
      _ -> {:noreply, assign(socket, forbidden_pairing_error: "Choose two players")}
    end
  end

  def handle_event("remove_forbidden_pairing", %{"id" => id}, socket) do
    case Tournaments.remove_forbidden_pairing(socket.assigns.tournament, id) do
      {:ok, forbidden_pairing} ->
        Audit.log(
          socket.assigns.tournament.id,
          socket.assigns.current_scope,
          "forbidden_pairing.removed",
          %{
            player_a_id: forbidden_pairing.player_a_id,
            player_b_id: forbidden_pairing.player_b_id
          }
        )

        {:noreply, assign_forbidden_pairings(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_text(reason))}
    end
  end

  ## ---------- Club/federation exclusions ----------

  def handle_event(
        "club_exclusion_mode_change",
        %{"tournament" => %{"club_exclusion" => mode}},
        socket
      ) do
    {:noreply, assign(socket, club_exclusion_mode: mode)}
  end

  def handle_event(
        "fed_exclusion_mode_change",
        %{"tournament" => %{"fed_exclusion" => mode}},
        socket
      ) do
    {:noreply, assign(socket, fed_exclusion_mode: mode)}
  end

  def handle_event("save_exclusions", %{"tournament" => params}, socket) do
    params =
      Map.take(params, [
        "club_exclusion",
        "club_exclusion_list",
        "fed_exclusion",
        "fed_exclusion_list"
      ])

    base = socket.assigns.tournament

    case Tournaments.update_tournament(base, params) do
      {:ok, tournament} ->
        log_settings_change(socket, base, tournament)

        {:noreply,
         socket
         |> assign(
           tournament: tournament,
           club_exclusion_mode: tournament.club_exclusion,
           fed_exclusion_mode: tournament.fed_exclusion,
           exclusion_error: nil
         )
         |> assign_forbidden_pairings()}

      {:error, changeset} ->
        {:noreply, assign(socket, exclusion_error: error_text(changeset))}
    end
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
    case Tournaments.update_tournament(base, params) do
      {:ok, tournament} ->
        log_settings_change(socket, base, tournament)

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
           stale: false
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

  defp strip_locked_pairing_fields(params, assigns) do
    params
    |> maybe_drop_locked("pairing_system", assigns.pairing_system_locked?)
    |> maybe_drop_locked("pairing_engine", assigns.pairing_engine_locked?)
    |> maybe_drop_locked("rr_cycles", assigns.rr_cycles_locked?)
    |> maybe_drop_locked("rr_match_format", assigns.rr_match_format_locked?)
    |> maybe_drop_locked("swiss_match_format", assigns.swiss_match_format_locked?)
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

          <p class="subtitle" style="margin: 0">{gettext("Settings - Options")}</p>
        </div>
        <span class={["badge", @tournament.status == "setup" && "muted"]}>{@tournament.status}</span>
      </div>
      <.settings_subnav tournament={@tournament} active={:options} />
      <.stale_banner stale={@stale} />
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
              <.locked_hint_message field={:pairing_system} locked_hint={@locked_hint} />
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
                    {gettext("JaVaFo - external, implements the 2022 rules")}
                  </option>

                  <option value="ainalrami" selected={@tournament.pairing_engine == "ainalrami"}>
                    {gettext("Ainalrami - built in, implements the 2026 rules (default)")}
                  </option>
                </select>
                <.locked_overlay field={:pairing_engine} locked?={@pairing_engine_locked?} />
              </div>
              <.locked_hint_message field={:pairing_engine} locked_hint={@locked_hint} />

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
                    "%[engine] is the external engine this app paired with first. It implements the %[edition] of the same rules and has not been updated for the current one, so the two disagree on roughly 4%% of rounds - that gap is the size of the rules change, not a fault in either."
                  )
                }>
                  <:part name="engine"><strong>JaVaFo</strong></:part>
                  <:part name="edition"><strong>{gettext("2022 edition")}</strong></:part>
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
                    "This tournament is marked %[flag] (Settings → FIDE). Both engines are allowed, and the choice is which edition of the rules its boards follow: Ainalrami pairs by the one in force since 1 February 2026, JaVaFo by the 2022 one it was last built for. Neither is a settled paperwork position - it is yours to make."
                  )
                }>
                  <:part name="flag"><strong>{gettext("FIDE-homologated")}</strong></:part>
                </.rich_text>
              </span>
            </.setting_field>

            <.setting_field label={gettext("Cycles")}>
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
              <.locked_hint_message field={:rr_cycles} locked_hint={@locked_hint} />
            </.setting_field>

            <.setting_toggle
              name="tournament[rr_match_format]"
              label={gettext("Match format (immediate 2-game rematch, reversed colours)")}
              checked={@tournament.rr_match_format}
              disabled={@rr_match_format_locked?}
              field={:rr_match_format}
              locked?={@rr_match_format_locked?}
              locked_hint={@locked_hint}
            />
            <.setting_field label={gettext("Keizer top value (blank = automatic)")}>
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
              <select name="tournament[acceleration]">
                <option value="none" selected={@tournament.acceleration == "none"}>
                  {gettext("None")}
                </option>

                <option value="baku" selected={@tournament.acceleration == "baku"}>
                  {gettext("Baku acceleration (FIDE C.04.7)")}
                </option>
              </select>
            </.setting_field>

            <.setting_toggle
              name="tournament[swiss_match_format]"
              label={gettext("Match format (immediate 2-game rematch, reversed colours)")}
              hint={
                gettext("Swiss only - requires an even number of rounds (each match is 2 rounds)")
              }
              checked={@tournament.swiss_match_format}
              disabled={@swiss_match_format_locked?}
              field={:swiss_match_format}
              locked?={@swiss_match_format_locked?}
              locked_hint={@locked_hint}
            />
          </.setting_group>
        </div>

        <.section_actions section="pairing" note={@note} error={@error} saved={@saved_section} />
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

      <div class="card">
        <h2>{gettext("Forbidden pairings")}</h2>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "Two players who must never be paired against each other. Applies to Swiss pairing (a TRF \"XXP\" rule) and to Keizer; a round robin's fixed schedule ignores this by design."
          )}
        </p>

        <form id="add-forbidden-pairing-form" phx-submit="add_forbidden_pairing">
          <.setting_group>
            <.setting_field label={gettext("Player A")}>
              <select name="player_a_id" class="pe-select">
                <option :for={p <- @forbidden_pairing_players} value={p.id}>{p.name}</option>
              </select>
            </.setting_field>

            <.setting_field label={gettext("Player B")}>
              <select name="player_b_id" class="pe-select">
                <option :for={p <- @forbidden_pairing_players} value={p.id}>{p.name}</option>
              </select>
            </.setting_field>
          </.setting_group>

          <p :if={@forbidden_pairing_error} class="error-note">{@forbidden_pairing_error}</p>

          <div class="actions">
            <button
              type="submit"
              class="pe-btn primary"
              disabled={length(@forbidden_pairing_players) < 2}
            >
              Add
            </button>
          </div>
        </form>

        <div :if={@forbidden_pairings != []} class="card-table-wrap" style="margin-top: 16px">
          <table class="pe-table">
            <thead>
              <tr>
                <th>{gettext("Pair")}</th>

                <th></th>
              </tr>
            </thead>

            <tbody>
              <tr :for={fp <- @forbidden_pairings}>
                <td>{fp.player_a.name} - {fp.player_b.name}</td>

                <td style="text-align: right">
                  <button
                    class="pe-btn danger-link"
                    phx-click="remove_forbidden_pairing"
                    phx-value-id={fp.id}
                  >
                    {gettext("Remove")}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <p :if={@forbidden_pairings == []} class="hint" style="margin-bottom: 0">
          {gettext("No forbidden pairings yet.")}
        </p>

        <h3 style="margin-top: 24px">{gettext("Club / federation exclusions")}</h3>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "Automatically forbid pairing any two players who share a club or federation, instead of listing every pair by hand. Applies to Swiss (TRF \"XXP\" rules, same as above) and to Keizer; a round robin's fixed schedule ignores this by design."
          )}
        </p>

        <form id="exclusion-rules-form" phx-submit="save_exclusions">
          <.setting_group>
            <.setting_field label={gettext("Clubs")}>
              <select
                name="tournament[club_exclusion]"
                class="pe-select"
                phx-change="club_exclusion_mode_change"
              >
                <option
                  :for={m <- Tournament.exclusion_modes()}
                  value={m}
                  selected={m == @club_exclusion_mode}
                >
                  {Tournament.exclusion_mode_label(m)}
                </option>
              </select>
            </.setting_field>

            <.setting_field
              :if={@club_exclusion_mode == "listed"}
              label={gettext("Clubs (comma-separated)")}
            >
              <input
                type="text"
                name="tournament[club_exclusion_list]"
                value={@tournament.club_exclusion_list}
                placeholder={gettext("e.g. Chess Club A, Chess Club B")}
              />
            </.setting_field>

            <.setting_field label={gettext("Federations")}>
              <select
                name="tournament[fed_exclusion]"
                class="pe-select"
                phx-change="fed_exclusion_mode_change"
              >
                <option
                  :for={m <- Tournament.exclusion_modes()}
                  value={m}
                  selected={m == @fed_exclusion_mode}
                >
                  {Tournament.exclusion_mode_label(m)}
                </option>
              </select>
            </.setting_field>

            <.setting_field
              :if={@fed_exclusion_mode == "listed"}
              label={gettext("Federations (comma-separated)")}
            >
              <input
                type="text"
                name="tournament[fed_exclusion_list]"
                value={@tournament.fed_exclusion_list}
                placeholder={gettext("e.g. BEL, NED")}
              />
            </.setting_field>
          </.setting_group>

          <p class="hint" style="margin-bottom: 0">
            {ngettext(
              "%{count} pair currently excluded by these rules.",
              "%{count} pairs currently excluded by these rules.",
              @excluded_pair_count
            )}
          </p>

          <p :if={@exclusion_error} class="error-note">{@exclusion_error}</p>

          <div class="actions">
            <button type="submit" class="pe-btn primary">{gettext("Save exclusion rules")}</button>
          </div>
        </form>
      </div>
      <div
        :if={@engine_confirm}
        class="modal-overlay"
        phx-window-keydown="cancel_engine"
        phx-key="escape"
      >
        <div class="modal-card" phx-click-away="cancel_engine" style="max-width: 640px">
          <h2>{gettext("Switch to JaVaFo?")}</h2>

          <p class="hint">
            <strong>{gettext("This pairs the tournament by superseded rules.")}</strong>
            <.rich_text text={
              gettext(
                "JaVaFo implements C.04.3 as it stood in %[edition] and has not been updated for the edition effective 1 February 2026. It is a good engine; it is answering an older rulebook. The two disagree on roughly 4%% of rounds, and that gap is the size of the rules change."
              )
            }>
              <:part name="edition"><strong>{gettext("2022")}</strong></:part>
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
                "That does not stop you, but it raises the stakes on the paragraph above: this event will be %[rated], and its boards will have been paired by the 2022 edition of the rules rather than the one in force. If a result is queried, that is the answer you will be giving."
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
