defmodule PairingsEngineWeb.SettingsFideLive do
  @moduledoc """
  The "FIDE" settings page (`/t/:id/settings/fide`) - the tournament's
  FIDE-report identifiers (the "ID of Tournament" and "Code of event" used on
  the IT3 / FA1 / IA1 / IT4 forms), the `fide_homologated` tickbox, and the
  per-round FIDE-ID-range editor (SWAR's "this FIDE tournament ID applies to
  rounds X-Y" model - see `PairingsEngine.Tournaments.Tournament`'s
  `fide_id_ranges` schema doc and `PairingsEngine.TrfExport.applicable_fide_id/2`,
  the consumer at export time). The officials and arbiter details that feed
  those same report forms live on the Norms tab.
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport

  alias PairingsEngine.{Audit, Authz, Compliance, RatingLists, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     socket
     |> attach_dirty_tracker()
     |> assign_rating_lists(tournament)
     |> assign(
       tournament: tournament,
       ignored_bye_preferences: PairingsEngine.Pairing.ignored_bye_preferences(tournament),
       page_title: "#{tournament.name} · Settings",
       rows: tournament.fide_id_ranges || [],
       may_load_lists?: Authz.may_administer?(socket.assigns.current_scope.user),
       note: nil,
       error: nil,
       # The Rating lists card has a voice of its own: its messages were the
       # FIDE form's too, so "Saved." beside "Save FIDE settings" could mean
       # a click on the other card.
       rating_note: nil,
       rating_error: nil,
       # Unsaved edits in the FIDE form (the page-wide `dirty` is set by every
       # event, a rating-list click included).
       form_dirty: false,
       dirty: false,
       stale: false,
       # The two-step "Leave FIDE mode" (TEC's Level 4): nil, then :warn,
       # then :consequences. Only a confirm sent from :consequences leaves.
       leave_step: nil
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
         socket
         |> assign_rating_lists(tournament)
         |> assign(
           tournament: tournament,
           ignored_bye_preferences: PairingsEngine.Pairing.ignored_bye_preferences(tournament),
           rows: tournament.fide_id_ranges || [],
           form_dirty: false,
           stale: false
         )}
    end
  end

  # Keeps `rows` (the in-progress range editor state) in sync with every
  # keystroke, so "Add row"/"Remove row" - which only touch `rows` directly,
  # not the raw form params - never clobber edits the arbiter already typed
  # into other rows. Nothing is persisted here; only "save" writes to the DB.
  @impl true
  def handle_event("validate", %{"tournament" => params}, socket) do
    {:noreply, assign(socket, rows: parse_rows_param(params["fide_id_ranges"]), form_dirty: true)}
  end

  def handle_event("add_range", _params, socket) do
    row = %{"fide_tournament_id" => "", "from_round" => "", "to_round" => ""}
    {:noreply, assign(socket, rows: socket.assigns.rows ++ [row], form_dirty: true)}
  end

  def handle_event("remove_range", %{"index" => index}, socket) do
    index = String.to_integer(index)
    {:noreply, assign(socket, rows: List.delete_at(socket.assigns.rows, index), form_dirty: true)}
  end

  ## ---------- the rating-list sequence and the consistency check ----------
  #
  # Each click saves on its own: the sequence is a list being arranged, not a
  # form to be filled in and sent. It says so in its own card (`rating_note`)
  # and leaves the FIDE form alone: whatever was typed there and not saved
  # is still unsaved, so the page stays dirty if the form is.

  def handle_event("seq_move", %{"index" => index, "dir" => dir}, socket) do
    seq = socket.assigns.rating_sequence

    with {i, ""} <- Integer.parse(index),
         j = if(dir == "up", do: i - 1, else: i + 1),
         true <- i in 0..(length(seq) - 1)//1 and j in 0..(length(seq) - 1)//1 do
      {:noreply, save_sequence(socket, swap(seq, i, j))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("seq_remove", %{"index" => index}, socket) do
    seq = socket.assigns.rating_sequence

    with {i, ""} <- Integer.parse(index),
         true <- length(seq) > 1 and i in 0..(length(seq) - 1)//1 do
      {:noreply, save_sequence(socket, List.delete_at(seq, i))}
    else
      _ ->
        {:noreply,
         assign(socket,
           rating_error: gettext("The sequence needs at least one list."),
           rating_note: nil
         )}
    end
  end

  def handle_event("seq_add", %{"entry" => entry}, socket) do
    seq = socket.assigns.rating_sequence

    if entry in Enum.map(socket.assigns.addable, &elem(&1, 0)) and entry not in seq do
      {:noreply, save_sequence(socket, seq ++ [entry])}
    else
      {:noreply, socket}
    end
  end

  def handle_event("seq_reset", _params, socket) do
    {:noreply, save_sequence(socket, [])}
  end

  def handle_event("set_rating_checks", params, socket) do
    enabled = params["enabled"] in ["true", "on"]

    base = Tournaments.get_tournament!(socket.assigns.tournament.id)

    case Tournaments.update_tournament(base, %{"rating_checks_enabled" => enabled}) do
      {:ok, tournament} ->
        log_settings_change(socket, base, tournament)

        {:noreply,
         assign(socket,
           tournament: tournament,
           rating_note: gettext("Saved."),
           rating_error: nil,
           note: nil,
           error: nil,
           dirty: socket.assigns.form_dirty,
           stale: false
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, rating_error: error_text(changeset), rating_note: nil)}
    end
  end

  ## ---------- leaving FIDE mode: two steps, then for good ----------
  #
  # VCL4THP Q43 wants the way out of FIDE mode behind TEC's Level-4 warning:
  # a first message saying the act is not compliant, then a second one that
  # spells out what it costs, answered the opposite way round from the first
  # (there "continue", here "no, do not stay"). The server holds the step,
  # so a confirm that skips the first message is ignored.
  def handle_event("leave_fide_start", _params, socket),
    do: {:noreply, assign(socket, leave_step: :warn)}

  def handle_event("leave_fide_continue", _params, %{assigns: %{leave_step: :warn}} = socket),
    do: {:noreply, assign(socket, leave_step: :consequences)}

  def handle_event("leave_fide_continue", _params, socket), do: {:noreply, socket}

  def handle_event("leave_fide_cancel", _params, socket),
    do: {:noreply, assign(socket, leave_step: nil)}

  def handle_event(
        "leave_fide_confirm",
        _params,
        %{assigns: %{leave_step: :consequences}} = socket
      ) do
    base = Tournaments.get_tournament!(socket.assigns.tournament.id)

    case Tournaments.leave_fide_mode(base) do
      {:ok, tournament} ->
        Audit.log(
          tournament.id,
          socket.assigns.current_scope,
          "tournament.fide_compliance_lost",
          %{
            setting: "fide_mode",
            code: "left_by_arbiter",
            round: tournament.fide_compliance_lost_round
          }
        )

        {:noreply,
         assign(socket,
           tournament: tournament,
           leave_step: nil,
           note: gettext("This tournament has left FIDE mode."),
           error: nil
         )}

      {:error, reason} ->
        {:noreply, assign(socket, leave_step: nil, error: error_text(reason), note: nil)}
    end
  end

  def handle_event("leave_fide_confirm", _params, socket), do: {:noreply, socket}

  def handle_event("save", %{"tournament" => params}, socket) do
    params =
      params
      |> Map.take([
        "fide_tournament_id",
        "event_code",
        "fide_homologated",
        "norm_event_type",
        "fide_id_ranges"
      ])
      |> Map.update("fide_id_ranges", [], &parse_rows_param/1)

    base = Tournaments.get_tournament!(socket.assigns.tournament.id)

    case Tournaments.update_tournament(base, params) do
      {:ok, tournament} ->
        log_settings_change(socket, base, tournament)

        {:noreply,
         assign(socket,
           tournament: tournament,
           ignored_bye_preferences: PairingsEngine.Pairing.ignored_bye_preferences(tournament),
           rows: tournament.fide_id_ranges || [],
           note: "Saved.",
           error: nil,
           rating_note: nil,
           rating_error: nil,
           form_dirty: false,
           dirty: false,
           stale: false
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, error: error_text(changeset), note: nil)}
    end
  end

  defp assign_rating_lists(socket, tournament) do
    sequence = RatingLists.sequence(tournament)

    assign(socket,
      rating_sequence: sequence,
      custom_names: RatingLists.custom_names(),
      addable:
        Enum.reject(RatingLists.available_entries(), fn {entry, _} -> entry in sequence end)
    )
  end

  # A sequence equal to the default for the rate of play is stored as no
  # sequence, so it keeps following the rate of play if that changes.
  defp save_sequence(socket, list) do
    base = Tournaments.get_tournament!(socket.assigns.tournament.id)
    list = if list == RatingLists.default_sequence(base.standard), do: [], else: list

    case Tournaments.update_tournament(base, %{"rating_list_sequence" => list}) do
      {:ok, tournament} ->
        log_settings_change(socket, base, tournament)

        socket
        |> assign_rating_lists(tournament)
        |> assign(
          tournament: tournament,
          rating_note: gettext("Saved."),
          rating_error: nil,
          note: nil,
          error: nil,
          dirty: socket.assigns.form_dirty,
          stale: false
        )

      {:error, changeset} ->
        assign(socket, rating_error: error_text(changeset), rating_note: nil)
    end
  end

  defp swap(list, i, j) do
    a = Enum.at(list, i)
    b = Enum.at(list, j)
    list |> List.replace_at(i, b) |> List.replace_at(j, a)
  end

  defp entry_label("fide_standard", _), do: gettext("FIDE Standard")
  defp entry_label("fide_rapid", _), do: gettext("FIDE Rapid")
  defp entry_label("fide_blitz", _), do: gettext("FIDE Blitz")
  defp entry_label("effective_rapid", _), do: gettext("Effective Rapid (Rapid, else Standard)")
  defp entry_label("effective_blitz", _), do: gettext("Effective Blitz (Blitz, else Standard)")
  defp entry_label("national", _), do: gettext("National list")
  defp entry_label("custom:" <> _ = entry, names), do: RatingLists.label(entry, names)

  # The "fide_id_ranges" form param arrives as a map indexed by string
  # position ("0", "1", ...) rather than a list - standard HTML nested-form
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

  attr :step, :atom, required: true

  defp leave_fide_mode(assigns) do
    ~H"""
    <div id="leave-fide-mode" style="margin-top: 12px">
      <p class="hint" style="margin: 0 0 8px">
        {gettext(
          "In FIDE mode, once the first round is paired, the number of rounds, the scoring, the bye's value, the acceleration, the pairing system and the tie-breaks are locked, and only the last two rounds played can be corrected. Leaving FIDE mode opens them."
        )}
      </p>

      <button
        :if={is_nil(@step)}
        id="leave-fide-start"
        type="button"
        class="pe-btn"
        phx-click="leave_fide_start"
      >
        {gettext("Leave FIDE mode…")}
      </button>

      <.fide_exit_dialog
        id="leave-fide"
        step={@step}
        continue_event="leave_fide_continue"
        cancel_event="leave_fide_cancel"
        confirm_event="leave_fide_confirm"
      />
    </div>
    """
  end

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

          <p class="subtitle" style="margin: 0">
            {gettext("Settings - FIDE")}
            <PairingsEngineWeb.Components.ManualLink.manual_link topic={:fide_settings} />
          </p>
        </div>
        <span class={["badge", @tournament.status == "setup" && "muted"]}>{@tournament.status}</span>
      </div>
      <.settings_subnav tournament={@tournament} active={:fide} /> <.stale_banner stale={@stale} />
      <div class="card">
        <h2>{gettext("FIDE handling")}</h2>
        <.compliance_notice tournament={@tournament} show_compliant />
        <p class="hint" style="margin-bottom: 0">
          {gettext(
            "This is not the same question as the tickbox below. This one is about how the software handled the event; that one is about whether you are sending it to FIDE to be rated. A club evening can be handled to the letter and never reported, and a rated event can be run however its arbiter chooses."
          )}
        </p>
        <.leave_fide_mode :if={Compliance.fide_mode?(@tournament)} step={@leave_step} />
      </div>

      <form id="fide-settings-form" phx-submit="save" phx-change="validate">
        <div class="card">
          <h2>{gettext("FIDE report identifiers")}</h2>

          <p class="hint" style="margin-top: 0">
            <.rich_text text={
              gettext(
                "The tournament's own FIDE identifiers, used to fill the IT3 / FA1 / IA1 / IT4 report forms on the %[norms] tab. The officials, arbiters and pairing-system details for those reports live on the Norms tab too."
              )
            }>
              <:part name="norms">
                <.link navigate={~p"/t/#{@tournament.id}/norms"}>{gettext("Norms")}</.link>
              </:part>
            </.rich_text>
          </p>

          <.setting_group>
            <.setting_toggle
              name="tournament[fide_homologated]"
              label={gettext("This tournament is FIDE-homologated (rated/reportable)")}
              checked={@tournament.fide_homologated}
            />
            <%!-- Bye preferences are not applied on a FIDE-rated
                  tournament; stored ones are kept, and this says whose. --%>
            <div
              :if={@ignored_bye_preferences != []}
              id="fide-bye-preference-ignored"
              class="pe-modal-warn"
              role="note"
            >
              <strong>{gettext("Bye preferences ignored: this tournament is FIDE-rated.")}</strong> {ngettext(
                "%{names} has a bye preference, which is not applied when pairing a FIDE-rated tournament. It is kept, and applies again if the tournament stops being FIDE-rated.",
                "%{names} have bye preferences, which are not applied when pairing a FIDE-rated tournament. They are kept, and apply again if the tournament stops being FIDE-rated.",
                length(@ignored_bye_preferences),
                names: Enum.join(@ignored_bye_preferences, ", ")
              )}
            </div>

            <.setting_field label={gettext("FIDE tournament ID (tournament-wide default)")}>
              <input name="tournament[fide_tournament_id]" value={@tournament.fide_tournament_id} />
            </.setting_field>

            <.setting_field label={gettext("FIDE event code")}>
              <input name="tournament[event_code]" value={@tournament.event_code} />
            </.setting_field>

            <.setting_field
              label={gettext("Event type for title norms")}
              hint={
                gettext(
                  "Only matters for a FIDE-rated event. The Norms tab judges each player's games with the fewer games or the federation-mix exemption this kind of event is granted in the FIDE Title Regulations; an ordinary event keeps the full requirements. Only the kinds that fit this tournament's type (team or individual) are offered."
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

          <p class="hint" style="margin-bottom: 0">
            {gettext(
              "The FIDE tournament ID above is used whenever no per-round range below unambiguously covers the exported rounds (no ranges configured, the export spans more than one range, or matches none) - see the ranges below for splitting one event's report across differently-rated sections. It's a different thing from the event code: the ID is this report's own numeric identifier at FIDE (IT3's \"ID of Tournament\"), the event code is your federation's rating-homologation code (e.g. BEL2026001)."
            )}
          </p>
        </div>

        <div class="card">
          <h2>{gettext("Per-round FIDE-ID ranges")}</h2>

          <p class="hint" style="margin-top: 0">
            {gettext(
              "For splitting one event's FIDE report across rated sections - e.g. FIDE ID 89495 for rounds 1-3, a different ID for rounds 4-9. When exporting a TRF whose selected rounds fall entirely inside one range below, that range's ID is used instead of the tournament-wide default above. Ranges may not overlap."
            )}
          </p>

          <div :if={@rows != []} class="card-table-wrap">
            <table class="pe-table">
              <thead>
                <tr>
                  <th>{gettext("FIDE tournament ID")}</th>

                  <th>{gettext("From round")}</th>

                  <th>{gettext("To round")}</th>

                  <th><span class="sr-only">{gettext("Actions")}</span></th>
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
                      {gettext("Remove")}
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <p :if={@rows == []} class="hint">
            {gettext(
              "No per-round ranges configured - every export uses the tournament-wide default ID above."
            )}
          </p>

          <div class="actions">
            <button type="button" class="pe-btn" phx-click="add_range">{gettext("Add range")}</button>
          </div>
        </div>

        <div class="actions">
          <button type="submit" id="fide-settings-save" class="pe-btn primary">
            {gettext("Save FIDE settings")}
          </button>
          <span :if={@note} id="fide-note" class="ok-note" style="align-self: center">{@note}</span>
          <span :if={@error} id="fide-error" class="error-note" style="align-self: center">
            {@error}
          </span>
        </div>
      </form>

      <div id="rating-lists-card" class="card">
        <h2>{gettext("Rating lists")}</h2>
        <p class="hint" style="margin-top: 0">
          {gettext(
            "The lists a player's rating is taken from when the player is added or the ratings are refreshed, in order. The first is the main list: its rating is entered automatically, and the ratings the player has in the other lists are offered to pick instead. A FIDE list fills the FIDE rating; the national list and your own lists fill the national rating."
          )}
        </p>
        <p
          :if={!RatingLists.custom_sequence?(@tournament)}
          id="rating-sequence-default"
          class="hint"
        >
          {gettext("This is the default sequence for the tournament's rate of play.")}
        </p>

        <ol id="rating-sequence" style="padding-left: 22px">
          <li
            :for={{entry, i} <- Enum.with_index(@rating_sequence)}
            id={"rating-sequence-#{i}"}
            style="display: flex; gap: 8px; align-items: center; margin: 4px 0"
          >
            <span style="flex: 1">
              {entry_label(entry, @custom_names)}
              <span :if={i == 0} class="badge muted">{gettext("main list")}</span>
            </span>
            <button
              type="button"
              class="pe-btn"
              id={"rating-sequence-up-#{i}"}
              phx-click="seq_move"
              phx-value-index={i}
              phx-value-dir="up"
              disabled={i == 0}
              aria-label={gettext("Move up")}
            >
              <.icon name="hero-arrow-up" class="w-4 h-4" />
            </button>
            <button
              type="button"
              class="pe-btn"
              id={"rating-sequence-down-#{i}"}
              phx-click="seq_move"
              phx-value-index={i}
              phx-value-dir="down"
              disabled={i == length(@rating_sequence) - 1}
              aria-label={gettext("Move down")}
            >
              <.icon name="hero-arrow-down" class="w-4 h-4" />
            </button>
            <button
              type="button"
              class="pe-btn danger-link"
              id={"rating-sequence-remove-#{i}"}
              phx-click="seq_remove"
              phx-value-index={i}
              disabled={length(@rating_sequence) == 1}
            >
              {gettext("Leave out")}
            </button>
          </li>
        </ol>

        <form
          :if={@addable != []}
          id="rating-sequence-add-form"
          phx-submit="seq_add"
          style="display: flex; gap: 8px; align-items: center; flex-wrap: wrap"
        >
          <select
            name="entry"
            id="rating-sequence-add-select"
            class="pe-input"
            style="width: auto"
            aria-label={gettext("Add to the sequence")}
          >
            <option :for={{entry, _label} <- @addable} value={entry}>
              {entry_label(entry, @custom_names)}
            </option>
          </select>
          <button type="submit" class="pe-btn" id="rating-sequence-add">
            {gettext("Add to the sequence")}
          </button>
        </form>

        <div class="actions">
          <button
            :if={RatingLists.custom_sequence?(@tournament)}
            type="button"
            class="pe-btn"
            id="rating-sequence-reset"
            phx-click="seq_reset"
          >
            {gettext("Back to the default sequence")}
          </button>
          <.link :if={@may_load_lists?} navigate={~p"/rating-lists"} id="rating-lists-manage">
            {gettext("Load your own rating list")}
          </.link>
        </div>

        <h3 style="margin-bottom: 4px">{gettext("Consistency checks")}</h3>
        <form id="rating-checks-form" phx-change="set_rating_checks">
          <input type="hidden" name="enabled" value="false" />
          <label style="display: flex; gap: 8px; align-items: center">
            <input
              type="checkbox"
              id="rating-checks-enabled"
              name="enabled"
              value="true"
              checked={@tournament.rating_checks_enabled}
            />
            <span>
              {gettext("Tell me when the FIDE list gives a player a different rating or title")}
            </span>
          </label>
        </form>
        <p class="hint" style="margin-bottom: 0">
          {gettext(
            "Switched off, nothing is checked on its own. The Refresh ratings button on the Players page still compares the ratings on file with the list when you ask."
          )}
        </p>
        <span :if={@rating_note} id="rating-note" class="ok-note">{@rating_note}</span>
        <span :if={@rating_error} id="rating-error" class="error-note">{@rating_error}</span>
      </div>
    </Layouts.app>
    """
  end
end
