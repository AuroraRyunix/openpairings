defmodule PairingsEngineWeb.SettingsNormsLive do
  @moduledoc """
  Settings, Officials & norms (`/t/:id/settings/norms`): who ran the event
  and what kind of event the title regulations see it as.

    * **Officials** - chief arbiter, organizer, person responsible for
      pairings, the ranked deputies, any further arbiters, the e-mail
      addresses FIDE's report template insists on, and the IT3/IT4 extras
      (special remarks, IT4 event type, pairings web link). Stored on the
      tournament (`chief_arbiter`, `organizer`, and the `officials` map) and
      read by the IT3 / FA1 / IA1 / IT4 forms the Norms page downloads.
      Every named official needs a FIDE ID: FIDE bounces a report without
      one, so the save refuses rather than storing something unusable.
    * **Title norms** - `norm_event_type`, the B.01 event kind that grants
      fewer games (1.4.1 (b)) or lifts the federation mix (1.4.3 (a)-(c)).
      Beside it, what the field says about 1.4.3 (d), the big-Swiss clause,
      which needs no setting (`PairingsEngine.Norms.TitleNorms.big_swiss/1`).

  The officials used to live on the Norms page, where nobody looking for
  "chief arbiter" thought to look. Nothing on this page is advanced, so it
  has no switch.
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport
  import PairingsEngineWeb.Components.ArbiterCombo

  alias PairingsEngine.Norms.{Forms, TitleNorms}
  alias PairingsEngine.Tournaments
  alias PairingsEngine.Tournaments.Tournament
  alias PairingsEngineWeb.Live.ArbiterCombo

  # Officials fields not on the Tournament schema directly - nested under
  # tournament[officials][KEY] and stored in the :officials map (see
  # PairingsEngine.Tournaments.Tournament for the recognised keys).
  @officials_fields [
    {"organizer_email", "Organizer e-mail", "text"},
    {"chief_arbiter_email", "Chief arbiter e-mail", "text"}
  ]

  # FIDE's own printed Certificaat only ranks 2 deputies by name ("1st/2nd
  # Deputy Chief Arbiter"); anyone after that prints as a plain, unranked
  # "Arbiter" row no matter how many there are, so only 2 ranked slots are
  # offered - everyone past that goes through "+ Add arbiter", which reuses
  # the template's own 2 spare rows before it ever has to grow the sheet
  # (see `PairingsEngine.Norms.ItThreeExpand`).
  @deputy_fields [
    {1, "1st deputy arbiter"},
    {2, "2nd deputy arbiter"}
  ]

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
       # The row as last read or saved. `tournament` carries officials picked
       # or added and not yet saved, so it cannot be what a change from
       # elsewhere is measured against.
       loaded: tournament,
       page_title: "#{tournament.name} · Settings · " <> gettext("Officials & norms"),
       officials_note: nil,
       officials_error: nil,
       norm_note: nil,
       norm_error: nil,
       dirty: false,
       # Unsaved edits in the officials form. The page-wide `dirty` is set by
       # every event; saving the event type must not clear it while officials
       # typed beside it are still unsaved.
       officials_dirty: false,
       stale: false,
       arbiter_search: nil
     )
     |> assign_big_swiss()}
  end

  # What the field says about B.01 1.4.3 (d). Reads the standings, so it is
  # worked out on load and on a change from elsewhere, never per keystroke.
  defp assign_big_swiss(socket),
    do: assign(socket, big_swiss: TitleNorms.big_swiss(socket.assigns.tournament))

  # While a form is dirty (the user is mid-edit), don't reload `@tournament`
  # - that would reset what is being typed. Only flag `stale` when the row
  # differs from the one last read or saved: the echo of this page's own
  # save is not news.
  @impl true
  def handle_info({:tournament_changed, _id, _hint}, %{assigns: %{dirty: true}} = socket) do
    case Tournaments.get_authorized_tournament(
           socket.assigns.current_scope,
           socket.assigns.tournament.id
         ) do
      fresh when fresh == socket.assigns.loaded -> {:noreply, socket}
      _ -> {:noreply, assign(socket, stale: true)}
    end
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
         |> assign(tournament: tournament, loaded: tournament, stale: false)
         |> assign_big_swiss()}
    end
  end

  # The dirty tracker has already set `dirty`; nothing else to do per
  # keystroke, and no reason to touch the database for it.
  @impl true
  def handle_event("officials_change", _params, socket),
    do: {:noreply, assign(socket, officials_dirty: true)}

  def handle_event("save_officials", %{"tournament" => params}, socket) do
    params =
      params
      |> Map.take(["chief_arbiter", "organizer", "officials"])
      |> clamp_officials_extra_arbiters()

    base = Tournaments.get_tournament!(socket.assigns.tournament.id)

    case missing_official_ids(params) do
      [] ->
        save_officials(socket, base, params)

      missing ->
        {:noreply,
         assign(socket, officials_error: id_required_message(missing), officials_note: nil)}
    end
  end

  # Arbiters beyond chief + the 2 ranked deputies - an unbounded list,
  # tracked as a plain count (`officials["extra_arbiters_count"]`) plus flat
  # `arbiterN_name`/`arbiterN_fide_id` officials keys, exactly like
  # deputy1/deputy2. Adding/removing only touches the in-memory
  # `@tournament`, same as a pick - "Save officials" persists it, the count
  # travelling through that save as a hidden input.
  def handle_event("add_arbiter", _params, socket) do
    {:noreply,
     assign(socket,
       tournament: bump_extra_arbiters(socket.assigns.tournament, 1),
       officials_dirty: true
     )}
  end

  def handle_event("remove_last_arbiter", _params, socket) do
    {:noreply,
     assign(socket,
       tournament: bump_extra_arbiters(socket.assigns.tournament, -1),
       officials_dirty: true
     )}
  end

  # Both boxes of any official's combobox (name, FIDE ID) route through here
  # - see `PairingsEngineWeb.Live.ArbiterCombo`. An unrecognised field is
  # ignored rather than crashed on: LiveView drops `phx-value-*` on a
  # form-serialised change, so the field can only be learned from `_target`,
  # and getting that wrong once took the whole LiveView down with it.
  def handle_event("arbiter_search", params, socket) do
    case ArbiterCombo.target_role_and_field(params) do
      nil ->
        {:noreply, socket}

      {role, field} ->
        query = ArbiterCombo.target_value(params)

        {:noreply,
         assign(socket,
           arbiter_search: ArbiterCombo.search(role, field, query),
           officials_dirty: true
         )}
    end
  end

  def handle_event("arbiter_pick", %{"role" => role, "fide-id" => fide_id}, socket) do
    case ArbiterCombo.picked_player(fide_id) do
      nil ->
        {:noreply, socket}

      fp ->
        {:noreply,
         assign(socket,
           tournament: apply_arbiter_pick(socket.assigns.tournament, role, fp),
           arbiter_search: nil,
           officials_dirty: true
         )}
    end
  end

  def handle_event("norm_change", _params, socket), do: {:noreply, socket}

  def handle_event("save_norm_settings", %{"tournament" => params}, socket) do
    params = Map.take(params, ["norm_event_type"])
    base = Tournaments.get_tournament!(socket.assigns.tournament.id)

    case Tournaments.update_tournament(base, params) do
      {:ok, tournament} ->
        log_settings_change(socket, base, tournament)

        # Only the event type is taken from the reloaded row: officials
        # typed (or picked) and not yet saved stay on screen.
        tournament_on_screen = %{
          socket.assigns.tournament
          | norm_event_type: tournament.norm_event_type
        }

        {:noreply,
         assign(socket,
           tournament: tournament_on_screen,
           loaded: tournament,
           norm_note: gettext("Saved."),
           norm_error: nil,
           dirty: socket.assigns.officials_dirty,
           stale: false
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, norm_error: error_text(changeset), norm_note: nil)}
    end
  end

  ## ---------- officials helpers ----------

  defp officials_fields, do: @officials_fields
  defp deputy_fields, do: @deputy_fields

  defp o_get(tournament, key), do: Map.get(tournament.officials || %{}, key, "")

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # Every arbiter FIDE reports on is registered with FIDE and therefore has an
  # id - there is no such thing as an official without one. Saving a bare name
  # only produces a report FIDE will bounce, and the half-filled record is what
  # the SWAR import leaves behind when a name is ambiguous, so refuse the save
  # and point at the lookup instead of storing something unusable.
  defp missing_official_ids(params) do
    officials = Map.get(params, "officials", %{})

    chief =
      if not blank?(Map.get(params, "chief_arbiter")) and
           blank?(Map.get(officials, "chief_arbiter_fide_id")),
         do: ["Chief arbiter"],
         else: []

    deputies =
      for {n, label} <- @deputy_fields,
          not blank?(Map.get(officials, "deputy#{n}_name")),
          blank?(Map.get(officials, "deputy#{n}_fide_id")),
          do: label

    extras =
      for n <- extra_arbiter_range(Map.get(officials, "extra_arbiters_count")),
          not blank?(Map.get(officials, "arbiter#{n}_name")),
          blank?(Map.get(officials, "arbiter#{n}_fide_id")),
          do: "Arbiter #{n}"

    chief ++ deputies ++ extras
  end

  # 1..count is a *descending* range when count is 0, so 0 (the common
  # case: no extra arbiters) short-circuits to an empty range explicitly.
  defp extra_arbiter_range(count) do
    case parse_extra_count(count) do
      n when n > 0 -> 1..n
      _ -> 1..0//1
    end
  end

  defp id_required_message(missing) do
    "Every official needs a FIDE ID - type their name or FIDE ID above and pick the matching " <>
      "result. Missing for: #{Enum.join(missing, ", ")}."
  end

  defp save_officials(socket, base, params) do
    case Tournaments.update_tournament(base, params) do
      {:ok, tournament} ->
        log_settings_change(socket, base, tournament)

        {:noreply,
         assign(socket,
           tournament: tournament,
           loaded: tournament,
           officials_note: "Saved.",
           officials_error: nil,
           dirty: false,
           officials_dirty: false,
           stale: false
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, officials_error: error_text(changeset), officials_note: nil)}
    end
  end

  defp apply_arbiter_pick(tournament, "chief_arbiter", fp) do
    %{
      tournament
      | chief_arbiter: fp.name,
        officials: put_official(tournament, "chief_arbiter_fide_id", fp.fide_id)
    }
  end

  defp apply_arbiter_pick(tournament, "organizer", fp) do
    %{
      tournament
      | organizer: fp.name,
        officials: put_official(tournament, "organizer_id", fp.fide_id)
    }
  end

  defp apply_arbiter_pick(tournament, "person_responsible_pairings", fp) do
    officials =
      tournament
      |> put_official("person_responsible_pairings", fp.name)
      |> Map.put("person_responsible_pairings_fide_id", fp.fide_id)

    %{tournament | officials: officials}
  end

  defp apply_arbiter_pick(tournament, "deputy" <> _ = role, fp),
    do: put_named_official(tournament, role, fp)

  defp apply_arbiter_pick(tournament, "arbiter" <> _ = role, fp),
    do: put_named_official(tournament, role, fp)

  defp apply_arbiter_pick(tournament, _role, _fp), do: tournament

  defp put_named_official(tournament, role, fp) do
    officials =
      tournament
      |> put_official("#{role}_name", fp.name)
      |> Map.put("#{role}_fide_id", fp.fide_id)

    %{tournament | officials: officials}
  end

  defp put_official(tournament, key, value), do: Map.put(tournament.officials || %{}, key, value)

  defp extra_arbiters_count(tournament),
    do: tournament |> o_get("extra_arbiters_count") |> parse_extra_count()

  # Clamped, same as the public tools page - the count drives IT3 template
  # growth at download time (`Forms.max_extra_arbiters/0`).
  defp parse_extra_count(nil), do: 0
  defp parse_extra_count(n) when is_integer(n), do: clamp_extra_count(n)

  defp parse_extra_count(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> clamp_extra_count(n)
      :error -> 0
    end
  end

  defp parse_extra_count(_), do: 0

  defp clamp_extra_count(n), do: n |> max(0) |> min(Forms.max_extra_arbiters())

  # The count travels through "Save officials" as a hidden input, so the
  # submitted params can carry anything; clamp before it reaches the changeset.
  defp clamp_officials_extra_arbiters(
         %{"officials" => %{"extra_arbiters_count" => value} = officials} = params
       ) do
    Map.put(
      params,
      "officials",
      Map.put(officials, "extra_arbiters_count", parse_extra_count(value))
    )
  end

  defp clamp_officials_extra_arbiters(params), do: params

  defp bump_extra_arbiters(tournament, delta) do
    current = extra_arbiters_count(tournament)
    new_count = clamp_extra_count(current + delta)

    officials =
      tournament
      |> put_official("extra_arbiters_count", new_count)
      |> then(fn officials ->
        if delta < 0 do
          officials
          |> Map.delete("arbiter#{current}_name")
          |> Map.delete("arbiter#{current}_fide_id")
        else
          officials
        end
      end)

    %{tournament | officials: officials}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      update_notice={assigns[:update_notice]}
      fide_notice={assigns[:fide_notice]}
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
      tournament={@tournament}
      active="settings"
    >
      <.settings_page
        tournament={@tournament}
        current_scope={@current_scope}
        active={:norms}
        subtitle={gettext("Settings - Officials & norms")}
      >
        <:subtitle_extra>
          <PairingsEngineWeb.Components.ManualLink.manual_link topic={:norms_settings} />
        </:subtitle_extra>
        <.stale_banner stale={@stale} />

        <div class="card" id="officials-card">
          <h2>{gettext("Officials")}</h2>

          <p class="hint" style="margin-top: 0">
            {gettext(
              "The IT3, FA1, IA1 and IT4 FIDE report forms are filled in from these. FIDE identifies every official by FIDE ID, so type a name or an ID and pick the matching player. Pairing mode is always computerized, and the pairing program names whichever engine paired this tournament."
            )}
          </p>

          <%!-- `phx-debounce` on the form applies to every input in it (the
          arbiter comboboxes carry their own, since they run a FIDE search).
          `officials_change` does nothing but let the dirty tracker see an
          edit, so there is no reason to round-trip on each character. --%>
          <form
            id="officials-form"
            phx-submit="save_officials"
            phx-change="officials_change"
            phx-debounce="300"
          >
            <div class="form-grid">
              <label :for={{key, label, type} <- officials_fields()} class="field">
                <span>{label}</span>
                <input
                  type={type}
                  name={"tournament[officials][#{key}]"}
                  value={o_get(@tournament, key)}
                />
              </label>

              <.arbiter_combo
                role="chief_arbiter"
                label={gettext("Chief arbiter")}
                required
                name_field="tournament[chief_arbiter]"
                name_value={@tournament.chief_arbiter}
                id_field="tournament[officials][chief_arbiter_fide_id]"
                id_value={o_get(@tournament, "chief_arbiter_fide_id")}
                search={@arbiter_search}
              />
              <.arbiter_combo
                role="organizer"
                label={gettext("Organizer")}
                name_field="tournament[organizer]"
                name_value={@tournament.organizer}
                id_field="tournament[officials][organizer_id]"
                id_value={o_get(@tournament, "organizer_id")}
                search={@arbiter_search}
              />
              <.arbiter_combo
                role="person_responsible_pairings"
                label={gettext("Person responsible for pairings")}
                name_field="tournament[officials][person_responsible_pairings]"
                name_value={o_get(@tournament, "person_responsible_pairings")}
                id_field="tournament[officials][person_responsible_pairings_fide_id]"
                id_value={o_get(@tournament, "person_responsible_pairings_fide_id")}
                search={@arbiter_search}
              />
              <label class="field">
                <span>{gettext("IT4 event type")}</span>
                <input
                  name="tournament[officials][it4_event_type]"
                  value={o_get(@tournament, "it4_event_type")}
                />
              </label>

              <label class="field" style="grid-column: 1 / -1">
                <span>{gettext("Link to pairings web (IT4)")}</span>
                <input
                  name="tournament[officials][pairings_web_link]"
                  value={o_get(@tournament, "pairings_web_link")}
                />
              </label>
            </div>

            <h3 style="margin: 18px 0 8px; font-size: 14px">{gettext("Deputy arbiters")}</h3>

            <div class="form-grid">
              <div :for={{n, label} <- deputy_fields()} style="display: contents">
                <.arbiter_combo
                  role={"deputy#{n}"}
                  label={label}
                  name_field={"tournament[officials][deputy#{n}_name]"}
                  name_value={o_get(@tournament, "deputy#{n}_name")}
                  id_field={"tournament[officials][deputy#{n}_fide_id]"}
                  id_value={o_get(@tournament, "deputy#{n}_fide_id")}
                  search={@arbiter_search}
                />
                <label class="field">
                  <span>{gettext("%{role} - e-mail", role: label)}</span>
                  <input
                    name={"tournament[officials][deputy#{n}_email]"}
                    value={o_get(@tournament, "deputy#{n}_email")}
                  />
                </label>
              </div>
            </div>

            <h3 style="margin: 18px 0 8px; font-size: 14px">
              {gettext("Additional arbiters")}
              <span class="hint" style="font-weight: normal">
                {gettext(
                  "(beyond chief + 2 deputies - FIDE doesn't rank these, so IT3 prints each as a plain \"Arbiter\" row)"
                )}
              </span>
            </h3>

            <input
              type="hidden"
              name="tournament[officials][extra_arbiters_count]"
              value={extra_arbiters_count(@tournament)}
            />
            <div class="form-grid">
              <div
                :for={n <- extra_arbiter_range(o_get(@tournament, "extra_arbiters_count"))}
                style="display: contents"
              >
                <.arbiter_combo
                  role={"arbiter#{n}"}
                  label={"Arbiter #{n}"}
                  name_field={"tournament[officials][arbiter#{n}_name]"}
                  name_value={o_get(@tournament, "arbiter#{n}_name")}
                  id_field={"tournament[officials][arbiter#{n}_fide_id]"}
                  id_value={o_get(@tournament, "arbiter#{n}_fide_id")}
                  search={@arbiter_search}
                />
              </div>
            </div>

            <div class="actions" style="margin-top: 8px">
              <button type="button" class="pe-btn" phx-click="add_arbiter">{gettext("+ Add arbiter")}</button>
              <button
                :if={extra_arbiters_count(@tournament) > 0}
                type="button"
                class="pe-btn danger-link"
                phx-click="remove_last_arbiter"
              >
                {gettext("Remove last arbiter")}
              </button>
            </div>

            <h3 style="margin: 18px 0 8px; font-size: 14px">{gettext("Special remarks (IT3)")}</h3>

            <div class="form-grid">
              <label :for={n <- 1..4} class="field">
                <span>{gettext("Remark %{n}", n: n)}</span>
                <input
                  name={"tournament[officials][remark#{n}]"}
                  value={o_get(@tournament, "remark#{n}")}
                />
              </label>
            </div>

            <div class="actions">
              <button type="submit" id="officials-save" class="pe-btn primary">
                {gettext("Save officials")}
              </button>
              <span :if={@officials_note} class="ok-note tset-saved" role="status">
                <.icon name="hero-check-micro" class="size-4" /> {@officials_note}
              </span>
              <span :if={@officials_error} class="error-note tset-error" role="alert">
                {@officials_error}
              </span>
            </div>
          </form>
        </div>

        <div class="card" id="title-norms-card">
          <h2>{gettext("Title norms")}</h2>

          <form id="norm-settings-form" phx-submit="save_norm_settings" phx-change="norm_change">
            <.setting_group>
              <.setting_field
                label={gettext("Event type for title norms")}
                hint={
                  gettext(
                    "Only matters for a FIDE-rated event. Each player's games are judged with the fewer games or the federation-mix exemption this kind of event is granted in the FIDE Title Regulations; an ordinary event keeps the full requirements. Only the kinds that fit this tournament's type (team or individual) are offered."
                  )
                }
              >
                <select id="norm-event-type" name="tournament[norm_event_type]">
                  <option
                    :for={type <- Tournament.norm_event_types_for(@tournament)}
                    value={type}
                    selected={Tournament.effective_norm_event_type(@tournament) == type}
                  >
                    {norm_event_type_label(type)}
                  </option>
                </select>
              </.setting_field>
            </.setting_group>

            <div class="actions">
              <button type="submit" id="norm-settings-save" class="pe-btn primary">
                {gettext("Save event type")}
              </button>
              <.save_status note={@norm_note} error={@norm_error} id="norm-settings-note" />
            </div>
          </form>

          <h3 style="margin: 18px 0 4px; font-size: 14px">
            {gettext("Big open Swiss (B.01 1.4.3 d)")}
          </h3>
          <p id="big-swiss-status" class="hint" style="margin: 0">
            {big_swiss_text(@big_swiss)}
          </p>
        </div>
      </.settings_page>
    </Layouts.app>
    """
  end

  # What the field says about 1.4.3 (d), in a sentence.
  defp big_swiss_text(nil),
    do:
      gettext(
        "Not asked: it applies only to an individual Swiss with the host federation set under Tournament, and is counted once a round is complete. Nothing to set; it is worked out from the players."
      )

  defp big_swiss_text(%{applies?: true} = b),
    do:
      gettext(
        "Applies: %{players} FIDE-rated players from %{federations} federations other than %{host}, %{titled} of them GM, IM, WGM or WIM, each missing at most one of %{rounds} rounds. The federation mix is lifted for every player.",
        Map.take(b, [:players, :federations, :host, :titled, :rounds])
      )

  defp big_swiss_text(b),
    do:
      gettext(
        "Does not apply: %{players} FIDE-rated players from %{federations} federations other than %{host}, %{titled} of them GM, IM, WGM or WIM, counting only those who missed at most one of %{rounds} rounds. It needs at least 20 players, 3 federations and 10 titled. Nothing to set; it is worked out from the players.",
        Map.take(b, [:players, :federations, :host, :titled, :rounds])
      )
end
