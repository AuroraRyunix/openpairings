defmodule PairingsEngineWeb.SettingsOptionsLive do
  @moduledoc """
  The "Options" settings page (`/t/:id/settings/options`) — everything about
  *how* the tournament is paired and scored: the pairing engine and its
  variants (RR cycles, RR/Swiss match format, pair-by-category — each locked
  once round 1 has been paired), the rating used for pairing, acceleration,
  the rate of play, custom scoring (points per win/draw/loss, the
  pairing-allocated bye value, and SWAR's "Pt ABSENT" genuine-absence
  scoring — also locked once round 1 has been paired), and the
  forbidden-pairing / club-federation exclusion rules.
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
       # interact with — one of `:pairing_system`, `:rr_cycles`,
       # `:rr_match_format`, `:swiss_match_format`, `:pair_by_category`, or nil.
       locked_hint: nil,
       forbidden_pairing_error: nil,
       club_exclusion_mode: tournament.club_exclusion,
       fed_exclusion_mode: tournament.fed_exclusion,
       exclusion_error: nil
     )
     |> assign_pairing_locks()
     |> assign_forbidden_pairings()}
  end

  # `pairing_system` locks once the tournament has paired its first round;
  # `rr_cycles` locks once the number of already-paired rounds reaches what
  # the current cycles setting implies a round robin needs. See the original
  # SettingsLive for the full rationale.
  defp assign_pairing_locks(socket) do
    tournament = socket.assigns.tournament
    paired = Pairing.paired_rounds_count(tournament.id)
    players = Tournaments.count_players(tournament.id)
    rr_base = max(players - 1, 1)
    rr_implied_limit = rr_base * tournament.rr_cycles

    assign(socket,
      paired_rounds: paired,
      pairing_system_locked?: paired > 0,
      rr_cycles_locked?: paired >= rr_implied_limit,
      rr_match_format_locked?: paired > 0,
      swiss_match_format_locked?: paired > 0,
      pair_by_category_locked?: paired > 0,
      # SWAR's "Pt ABSENT" scoring (abs_value/abs_jusque/abs_nbfois) — like
      # the pairing-shape controls above, locked once round 1 has been
      # paired. Unlike those, changing this after the fact wouldn't corrupt
      # any stored data (scores are computed live from these fields on
      # every standings read, never baked into a `byes` row) — it's locked
      # anyway because a tournament this far along is presumably still
      # being run under whatever absence rule it started with (most often
      # a SWAR import's own club-configured rule), and silently changing
      # who's owed points partway through would be confusing at best.
      abs_scoring_locked?: paired > 0
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

  # Self-clearing timer for the "locked" hint set by the "locked_hint" event —
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

  def handle_event("toggle_registration", _params, socket) do
    open? = !socket.assigns.tournament.registration_open

    case Tournaments.set_registration_open(socket.assigns.tournament, open?) do
      {:ok, tournament} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "registration.toggled", %{
          open: open?
        })

        note =
          if open?,
            do: "Registration is open — anyone with the link can enter.",
            else: "Registration is closed."

        {:noreply, socket |> assign(tournament: tournament) |> put_flash(:info, note)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not change registration")}
    end
  end

  def handle_event("locked_hint", %{"field" => field}, socket) do
    field = String.to_existing_atom(field)
    Process.send_after(self(), {:clear_locked_hint, field}, 3000)
    {:noreply, assign(socket, locked_hint: field)}
  end

  # `standard` and `rate_of_play` are tracked as their own assigns because the
  # "Rate of play" select's option list depends on which "Type" is picked.
  def handle_event("standard_change", %{"tournament" => %{"standard" => new_standard}}, socket) do
    list = RateOfPlay.list_for(new_standard)
    current = socket.assigns.rate_of_play
    new_rate = if current in list, do: current, else: ""

    {:noreply, assign(socket, standard: new_standard, rate_of_play: new_rate)}
  end

  def handle_event("save", %{"tournament" => params}, socket) do
    params =
      params
      |> apply_rate_of_play_override()
      |> strip_locked_pairing_fields(socket.assigns)

    base = Tournaments.get_tournament!(socket.assigns.tournament.id)

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
           dirty: false,
           stale: false
         )
         |> assign_pairing_locks()}

      {:error, changeset} ->
        {:noreply, assign(socket, error: error_text(changeset), note: nil)}
    end
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

      {:error, _reason} ->
        {:noreply, socket}
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
  defp strip_locked_pairing_fields(params, assigns) do
    params
    |> maybe_drop_locked("pairing_system", assigns.pairing_system_locked?)
    |> maybe_drop_locked("rr_cycles", assigns.rr_cycles_locked?)
    |> maybe_drop_locked("rr_match_format", assigns.rr_match_format_locked?)
    |> maybe_drop_locked("swiss_match_format", assigns.swiss_match_format_locked?)
    |> maybe_drop_locked("pair_by_category", assigns.pair_by_category_locked?)
    |> maybe_drop_locked("abs_value", assigns.abs_scoring_locked?)
    |> maybe_drop_locked("abs_jusque", assigns.abs_scoring_locked?)
    |> maybe_drop_locked("abs_nbfois", assigns.abs_scoring_locked?)
  end

  defp maybe_drop_locked(params, _key, false), do: params
  defp maybe_drop_locked(params, key, true), do: Map.delete(params, key)

  # Player ratings are looked up per-cadence (`PairingsEngine.Fide.
  # rating_for_tempo/2` — Standard/Rapid/Blitz), so a saved change to
  # `standard` silently leaves every already-registered player's stored
  # `fide_rating` at whatever cadence was in effect when they were last
  # looked up or refreshed. Nothing re-fetches it automatically (that would
  # mean a settings save silently rewriting player data) — just flag it so
  # the arbiter knows to re-run the refresh from the Players page.
  defp save_note(%{standard: same}, %{standard: same}), do: "Saved."

  defp save_note(_before, tournament) do
    "Saved. Tempo changed to #{RateOfPlay.standard_options() |> Map.new() |> Map.get(tournament.standard, tournament.standard)} " <>
      "— FIDE ratings shown are still whichever cadence was last looked up; " <>
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

  # locked_overlay/1 + locked_hint_message/1 now live in SettingsSupport —
  # <.setting_toggle> needs them too.

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

          <p class="subtitle" style="margin: 0">Settings - Options</p>
        </div>
        <span class={["badge", @tournament.status == "setup" && "muted"]}>{@tournament.status}</span>
      </div>
      <.settings_subnav tournament={@tournament} active={:options} />
      <.stale_banner stale={@stale} />
      <div class="card">
        <h2>Registration form</h2>

        <p class="subtitle" style="margin: 0 0 8px">
          A public page where players enter themselves, finding their own name on the
          FIDE list. Everyone who signs up arrives marked <strong>not yet arrived</strong> —
          they are not paired until you confirm them on the Players page.
        </p>

        <p :if={!@tournament.public_pages_enabled} class="subtitle" style="margin: 0 0 8px">
          <strong>Public pages are switched off</strong>, so the form will not open even
          if you turn it on here. Enable them under Settings → Tournament first.
        </p>

        <div class="actions" style="margin: 0">
          <button
            type="button"
            class={["pe-btn", @tournament.registration_open && "primary"]}
            phx-click="toggle_registration"
            data-confirm={
              if @tournament.registration_open,
                do: "Close the form? Nobody will be able to register until you open it again.",
                else: nil
            }
          >
            {if @tournament.registration_open, do: "Close the form", else: "Open up"}
          </button>

          <a
            :if={@tournament.registration_open && @tournament.public_pages_enabled}
            class="pe-btn"
            href={~p"/p/#{@tournament.public_slug}/register"}
            target="_blank"
            title="No login needed - share this link"
          >
            Registration link
          </a>
        </div>
      </div>

      <form phx-submit="save">
        <div class="card">
          <h2>Options</h2>

          <.setting_group>
            <.setting_field label="Pairing system">
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

            <.setting_field label="Cycles">
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
              label="Match format (immediate 2-game rematch, reversed colours)"
              checked={@tournament.rr_match_format}
              disabled={@rr_match_format_locked?}
              field={:rr_match_format}
              locked?={@rr_match_format_locked?}
              locked_hint={@locked_hint}
            />
            <.setting_field label="Keizer top value (blank = automatic)">
              <input
                type="number"
                name="tournament[keizer_top_value]"
                value={@tournament.keizer_top_value}
                min="1"
              />
            </.setting_field>

            <.setting_field label="Pair by">
              <select name="tournament[rating_type]">
                <option value="fide" selected={@tournament.rating_type == "fide"}>FIDE rating</option>

                <option value="national" selected={@tournament.rating_type == "national"}>
                  National rating
                </option>
              </select>
            </.setting_field>

            <.setting_field
              label="Acceleration"
              hint="Swiss only - round robin and Keizer ignore this setting"
            >
              <select name="tournament[acceleration]">
                <option value="none" selected={@tournament.acceleration == "none"}>None</option>

                <option value="baku" selected={@tournament.acceleration == "baku"}>
                  Baku acceleration (FIDE C.04.7)
                </option>
              </select>
            </.setting_field>

            <.setting_toggle
              name="tournament[swiss_match_format]"
              label="Match format (immediate 2-game rematch, reversed colours)"
              hint="Swiss only - requires an even number of rounds (each match is 2 rounds)"
              checked={@tournament.swiss_match_format}
              disabled={@swiss_match_format_locked?}
              field={:swiss_match_format}
              locked?={@swiss_match_format_locked?}
              locked_hint={@locked_hint}
            />
            <%!-- Folded in from its own one-checkbox "Categories" card: it gates
                  pair_by_category below, so it belongs next to it. --%>
            <.setting_toggle
              name="tournament[categories_enabled]"
              label="Enable the Categories tab (category groups + extra points)"
              checked={@tournament.categories_enabled}
            />
            <.setting_toggle
              name="tournament[pair_by_category]"
              label="Pair each category independently"
              hint="Swiss only - each category gets its own independent pairings and byes within one combined round"
              checked={@tournament.pair_by_category}
              disabled={@pair_by_category_locked? or not @tournament.categories_enabled}
              field={:pair_by_category}
              locked?={@pair_by_category_locked?}
              locked_hint={@locked_hint}
            >
              <span
                :if={not @tournament.categories_enabled and not @pair_by_category_locked?}
                class="hint"
              >
                enable categories first
              </span>
            </.setting_toggle>

            <.setting_field label="Type">
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

            <.setting_field label="Rate of play" required>
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

            <.setting_field label="Other rate of play (overrides the select above)">
              <input
                type="text"
                name="tournament[rate_of_play_other]"
                value=""
                placeholder="e.g. 40 min + 10 sec/move"
              />
            </.setting_field>
          </.setting_group>
        </div>

        <div class="card">
          <h2>Scoring</h2>

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

            <.setting_field
              label="Points for a genuine absence (SWAR's 'Pt ABSENT')"
              hint="Blank = not applicable — an absence then scores the same as an ordinary loss"
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
              label="...pays through round (inclusive)"
              hint="Blank = no round cutoff"
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
              label="...for up to this many absences (cumulative)"
              hint="Blank = no count cap — every genuine absence pays, no matter how many"
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

            <.setting_toggle
              name="tournament[absent_counts_as_vur]"
              label="Treat a genuine absence as a voluntary unplayed round for tiebreaks"
              hint="Off (FIDE default) = an absence always counts at its award value above. On = a trailing absence is downgraded to a draw for opponents' Buchholz/SB, same as a requested bye — FIDE's own C.07 has no 'absent' concept, so this stays opt-in."
              checked={@tournament.absent_counts_as_vur}
            />
          </.setting_group>
        </div>

        <div class="actions">
          <button type="submit" class="pe-btn primary">Save settings</button>
          <span :if={@note} class="ok-note" style="align-self: center">{@note}</span>
          <span :if={@error} class="error-note" style="align-self: center">{@error}</span>
        </div>
      </form>

      <div class="card">
        <h2>Forbidden pairings</h2>

        <p class="hint" style="margin-top: 0">
          Two players who must never be paired against each other. Applies to Swiss pairing
          (a JaVaFo "XXP" rule) and to Keizer; a round robin's fixed schedule ignores this by design.
        </p>

        <form id="add-forbidden-pairing-form" phx-submit="add_forbidden_pairing">
          <.setting_group>
            <.setting_field label="Player A">
              <select name="player_a_id" class="pe-select">
                <option :for={p <- @forbidden_pairing_players} value={p.id}>{p.name}</option>
              </select>
            </.setting_field>

            <.setting_field label="Player B">
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
                <th>Pair</th>

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
                    Remove
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <p :if={@forbidden_pairings == []} class="hint" style="margin-bottom: 0">
          No forbidden pairings yet.
        </p>

        <h3 style="margin-top: 24px">Club / federation exclusions</h3>

        <p class="hint" style="margin-top: 0">
          Automatically forbid pairing any two players who share a club or federation, instead of
          listing every pair by hand. Applies to Swiss (JaVaFo "XXP" rules, same as above) and to
          Keizer; a round robin's fixed schedule ignores this by design.
        </p>

        <form id="exclusion-rules-form" phx-submit="save_exclusions">
          <.setting_group>
            <.setting_field label="Clubs">
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

            <.setting_field :if={@club_exclusion_mode == "listed"} label="Clubs (comma-separated)">
              <input
                type="text"
                name="tournament[club_exclusion_list]"
                value={@tournament.club_exclusion_list}
                placeholder="e.g. Chess Club A, Chess Club B"
              />
            </.setting_field>

            <.setting_field label="Federations">
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
              label="Federations (comma-separated)"
            >
              <input
                type="text"
                name="tournament[fed_exclusion_list]"
                value={@tournament.fed_exclusion_list}
                placeholder="e.g. BEL, NED"
              />
            </.setting_field>
          </.setting_group>

          <p class="hint" style="margin-bottom: 0">
            {@excluded_pair_count} pair(s) currently excluded by these rules.
          </p>

          <p :if={@exclusion_error} class="error-note">{@exclusion_error}</p>

          <div class="actions">
            <button type="submit" class="pe-btn primary">Save exclusion rules</button>
          </div>
        </form>
      </div>
    </Layouts.app>
    """
  end
end
