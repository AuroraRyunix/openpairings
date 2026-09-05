defmodule PairingsEngineWeb.LiveRoundLive do
  @moduledoc """
  Read-only "projector" view of a tournament's latest paired round: the
  pairing list with live results, and current standings below it. Also the
  arbiter's mobile-enrollment QR generator (see PairingsEngine.Mobile) - both
  live here since an arbiter typically opens this page once and leaves it up.
  Meant to be popped into its own tab/window (see the "Local view & phone QR"
  link on PairingsLive) and left open - it subscribes to the same tournament
  topic as every other tournament-scoped view and updates the instant a
  result is entered elsewhere, no polling.
  """

  use PairingsEngineWeb, :live_view

  alias PairingsEngineWeb.PublicLink

  alias PairingsEngine.{Tournaments, Standings, Tiebreaks, Keizer, Mobile, PairingDisplay}
  alias PairingsEngine.Pairing, as: Engine

  # How long each page of boards stays up.
  #
  # Sized for the person standing in front of it, not the arbiter: long
  # enough to find your name in a column of twenty, short enough that a
  # four-page cycle comes back round inside a minute. Someone who arrives
  # just as their page leaves should not feel they have missed it.
  @cycle_ms 12_000

  # A last-resort page size for the moment before the browser has measured
  # itself, and for anything that never reports (a screenshot, a test). Small
  # enough to be legible on a modest screen rather than optimistic.
  @default_rows_per_page 12

  @result_labels %{
    "1-0" => "1-0",
    "1/2-1/2" => "½-½",
    "0-1" => "0-1",
    "1/2-0" => "½-0",
    "0-1/2" => "0-½",
    "1-0FF" => "1-0 FF",
    "0-1FF" => "0-1 FF",
    "0-0FF" => "0-0 FF",
    "0-0" => "0-0"
  }

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)
    display? = params["display"] in ["1", "true"]

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     socket
     |> assign(
       tournament: tournament,
       page_title: "#{tournament.name} · Live",
       new_enrollment: nil,
       # Projector mode: the boards, full screen, nothing else. Reached by the
       # button on this page, or by `?display=1` so a machine that drives a
       # hall screen can be pointed at a URL and left alone.
       display?: display?,
       # On by default, and deliberately: this is aimed at a projector in a
       # bright room, where whatever theme the arbiter happens to like on
       # their laptop is the wrong answer. Overridable all the same - some
       # rooms are dark, and some screens are better than others.
       high_contrast?: true,
       # How many board rows the screen can hold. The browser measures itself
       # and says; until it does, `@default_rows_per_page` keeps the page
       # sensible rather than empty.
       rows_per_page: @default_rows_per_page,
       page: 0,
       paused?: false,
       cycle_timer: nil
     )
     |> assign_enrollments()
     |> reload()
     # Start the cycle here, not only when the button is pressed.
     #
     # `?display=1` exists so a machine that drives a hall screen can be
     # pointed at a URL and left alone - and that was the one path that never
     # started the timer, because `reschedule_cycle/1` was reached only from
     # `toggle_display`, `toggle_pause` and the tick itself. The kiosk showed
     # page one of the boards for the rest of the tournament.
     |> reschedule_cycle()}
  end

  defp reschedule_cycle(socket) do
    if timer = socket.assigns.cycle_timer, do: Process.cancel_timer(timer)

    if socket.assigns.display? and not socket.assigns.paused? do
      assign(socket, cycle_timer: Process.send_after(self(), :cycle_page, @cycle_ms))
    else
      assign(socket, cycle_timer: nil)
    end
  end

  # `@cycle_ms` inside a template would mean `assigns.cycle_ms`, so the bar
  # reads the module attribute through here. One number drives both the timer
  # and the animation; two would drift and the bar would lie.
  defp cycle_ms, do: @cycle_ms

  defp page_count(socket), do: page_count_for(socket.assigns)

  # The template has assigns, the handlers have a socket. Counting lives here
  # once so the footer and the cycle can never disagree about how many pages
  # there are - which would show "Page 3 of 2" for one frame after a resize.
  defp page_count_for(%{round: nil}), do: 1

  defp page_count_for(%{round: round} = assigns) do
    rows = length(display_rows(round.pairings))
    per = max(assigns.rows_per_page, 1)
    max(ceil(rows / per), 1)
  end

  defp last_page(socket), do: page_count(socket) - 1

  # The slice actually on screen. Outside display mode the whole list is the
  # page, so the ordinary view is untouched by any of this.
  defp page_rows(socket_assigns, rows) do
    if socket_assigns.display? do
      Enum.slice(
        rows,
        socket_assigns.page * socket_assigns.rows_per_page,
        socket_assigns.rows_per_page
      )
    else
      rows
    end
  end

  defp assign_enrollments(socket) do
    assign(socket, :enrollments, Mobile.list_enrollments(socket.assigns.tournament.id))
  end

  defp enroll_expiry(%DateTime{} = dt), do: Calendar.strftime(dt, "%d %b %H:%M")

  defp enrollment_level_label("deputy"), do: gettext("Deputy")
  defp enrollment_level_label(_helper), do: gettext("Helper")

  defp board_range_label(nil, nil), do: nil
  defp board_range_label(from, nil), do: gettext("Boards %{from}+", from: from)
  defp board_range_label(nil, to), do: gettext("Boards up to %{to}", to: to)
  defp board_range_label(from, to), do: gettext("Boards %{from}-%{to}", from: from, to: to)

  # "Boards 1-10 · Helper" rather than a bare token id - one enrolment can
  # be used by unlimited phones, so this line IS the audit trail for what
  # the CODE may do, not a particular device. An arbiter checking "did I
  # hand out the right thing" needs the range and the level together, not
  # a code number to cross-reference against memory.
  defp enrollment_scope_label(e) do
    level = enrollment_level_label(e.level)

    case board_range_label(e.board_from, e.board_to) do
      nil -> level
      range -> gettext("%{range} · %{level}", range: range, level: level)
    end
  end

  # Blank stays "no restriction" rather than an error - the field is
  # optional. Anything that doesn't parse as a positive integer (a stray
  # non-numeric value from outside the `type="number"` input) is treated
  # the same way rather than surfacing a confusing error on a field the
  # arbiter may not have touched at all; `Mobile.create_enrollment/2`'s own
  # validation is what actually guards the range that DOES get set.
  defp parse_board(nil), do: nil
  defp parse_board(""), do: nil

  defp parse_board(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp enrollment_opts(params) do
    [
      label: params |> Map.get("label", "") |> to_string() |> String.trim(),
      level: Map.get(params, "level", "helper"),
      board_from: parse_board(params["board_from"]),
      board_to: parse_board(params["board_to"])
    ]
  end

  # Shown wherever a code needs a face - the just-minted panel and the
  # device list - so an arbiter matching phone to person doesn't fall back
  # to reading out an 8-digit code. Naming is optional (an arbiter in a
  # hurry must still be able to mint one with zero fields filled), so this
  # is the one place that decides what an empty name reads as instead of a
  # blank cell that looks like the row failed to load.
  defp enrollment_name_label(%Mobile.Enrollment{label: ""}), do: gettext("No name given")
  defp enrollment_name_label(%Mobile.Enrollment{label: label}), do: label

  # What tells an arbiter whether the code they just handed over actually
  # got scanned - "Not used yet" versus claimed-and-when, not just present
  # in the list. `claimed_at` only ever moves nil -> a timestamp
  # (`Mobile.claim/1`), never back, so there is no third state to render.
  defp claim_status_label(%Mobile.Enrollment{claimed_at: nil}), do: gettext("Not used yet")

  defp claim_status_label(%Mobile.Enrollment{claimed_at: %DateTime{} = claimed_at}),
    do: gettext("Claimed %{when}", when: enroll_expiry(claimed_at))

  # A board-range validation failure gets its own message (what to fix);
  # anything else - a `:level` that didn't come from the `<select>`, say -
  # falls back to the same generic retry message this already had.
  defp enrollment_changeset_error(%Ecto.Changeset{} = changeset) do
    if changeset.errors[:board_from] || changeset.errors[:board_to] do
      gettext(
        "Board range is invalid - \"to\" must be at least \"from\", and both must be 1 or higher."
      )
    else
      gettext("Could not enrol a phone - please retry.")
    end
  end

  @impl true
  # `create_enrollment/2` refuses on an archived or handed-off tournament, so
  # the old `{:ok, enrollment} =` would have taken the page down with a
  # MatchError instead of saying why - on the one page an arbiter leaves open
  # on a projector all day.
  # ---- the pairing cycle ---------------------------------------------------
  #
  # Only ever pairings. Standings are the arbiter's business and belong on the
  # page below, not in a rotation somebody is watching for their own board.

  @doc false
  def handle_event("toggle_display", _params, socket) do
    socket = assign(socket, display?: not socket.assigns.display?, page: 0)
    {:noreply, reschedule_cycle(socket)}
  end

  def handle_event("toggle_contrast", _params, socket) do
    {:noreply, assign(socket, high_contrast?: not socket.assigns.high_contrast?)}
  end

  # Someone in the hall wants to read a board without chasing it. Pausing
  # leaves the page where it is rather than jumping to the start, so what they
  # were reading is what stays up.
  def handle_event("toggle_pause", _params, socket) do
    socket = assign(socket, paused?: not socket.assigns.paused?)
    {:noreply, reschedule_cycle(socket)}
  end

  # The browser measuring itself. Sent on mount and on resize, so a screen
  # that is rotated or a window that is dragged to another monitor re-fits
  # rather than keeping a page size for a shape it no longer has.
  def handle_event("rows_fit", %{"rows" => rows}, socket) when is_integer(rows) and rows > 0 do
    socket = assign(socket, rows_per_page: rows)

    # Clamp rather than reset: a screen that just got shorter should not throw
    # the viewer back to page one mid-read.
    {:noreply, assign(socket, page: min(socket.assigns.page, last_page(socket)))}
  end

  def handle_event("rows_fit", _params, socket), do: {:noreply, socket}

  def handle_event("generate_enrollment", params, socket) do
    case Mobile.create_enrollment(socket.assigns.tournament.id, enrollment_opts(params)) do
      {:ok, enrollment} ->
        {:noreply,
         socket
         |> assign(new_enrollment: enrollment)
         |> assign_enrollments()}

      {:error, reason} when is_atom(reason) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Tournaments.refusal_message(reason, gettext("enrolling a phone"))
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, enrollment_changeset_error(changeset))}
    end
  end

  def handle_event("revoke_enrollment", %{"id" => id}, socket) do
    case Integer.parse(to_string(id)) do
      {int, _} -> Mobile.revoke(socket.assigns.tournament.id, int)
      _ -> :ok
    end

    new_enrollment =
      if socket.assigns.new_enrollment &&
           to_string(socket.assigns.new_enrollment.id) == to_string(id),
         do: nil,
         else: socket.assigns.new_enrollment

    {:noreply, socket |> assign(new_enrollment: new_enrollment) |> assign_enrollments()}
  end

  # Purely a display page - nothing here is user-editable, so every
  # broadcast just reloads everything.
  @impl true
  @doc false
  def handle_info(:cycle_page, socket) do
    pages = page_count(socket)

    socket =
      if socket.assigns.paused? or pages <= 1 do
        socket
      else
        assign(socket, page: rem(socket.assigns.page + 1, pages))
      end

    {:noreply, reschedule_cycle(socket)}
  end

  # One timer at a time. Every path that could change whether cycling makes
  # sense - entering display mode, pausing, a tick - comes through here, so
  # there is never a second timer left running behind the first.

  def handle_info({:tournament_changed, _tournament_id, _hint}, socket) do
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
        {:noreply, socket |> assign(tournament: tournament) |> reload()}
    end
  end

  # Keizer tournaments show their own ladder (rank/value/Keizer points)
  # instead of the FIDE-tiebreak table - see PairingsEngine.Keizer.standings/1
  # and docs/pairing-systems.md, same as StandingsLive/PublicStandingsLive.
  defp reload(socket) do
    tournament = socket.assigns.tournament
    keizer? = tournament.pairing_system == "keizer"

    # What this page shows is what is PUBLISHED, not what is paired.
    #
    # It used to show the latest paired round, which meant an arbiter with
    # manual publishing could put a round on a wall in front of two hundred
    # players while it was still deliberately withheld from the results site.
    # There is no such thing as "shown in the hall but not published": the
    # people it is being withheld from are the ones standing in front of it.
    # So a round is live or it is not, and this page tracks the same flag the
    # public page does.
    #
    # In "immediate" mode every paired round is published the moment it
    # exists and this is a no-op. Do NOT assume that is the common case: the
    # migration sets the column default to "immediate", but the schema's own
    # default is "manual" and Ecto sends struct defaults on insert, so every
    # tournament created through the app is actually "manual", which is the
    # intended default - see the note on the field itself.
    paired = Engine.paired_rounds_count(tournament.id)
    shown = Tournaments.latest_published_round_number(tournament)

    assign(socket,
      round_number: shown,
      # Kept so the page can say a round is waiting rather than just appearing
      # to be a round behind.
      paired_rounds: paired,
      round: shown > 0 && Tournaments.get_round(tournament.id, shown),
      scores:
        if(shown > 0, do: Standings.player_scores_before_round(tournament, shown), else: %{}),
      round_byes:
        if(shown > 0, do: Tournaments.list_byes_for_round(tournament.id, shown), else: []),
      # The byes table's absence counts, once per reload rather than once
      # per rendered row (`Standings.absent_counts/1`). An empty map, and no
      # query at all, unless the tournament caps "Pt ABSENT" by occurrence.
      absent_counts: Standings.absent_counts(tournament),
      keizer?: keizer?,
      entries:
        if(keizer?,
          do: Keizer.standings(tournament),
          # Through the published round only. Showing the boards of round 4
          # above a table that already counts round 5's results would give
          # away the round being withheld just as surely as showing it.
          else: Standings.standings(tournament, through_round: shown)
        )
    )
  end

  defp player_label(nil), do: ""

  defp player_label(player) do
    rating = PairingsEngine.Tournaments.Player.rating(player)

    "#{if player.title != "", do: "#{player.title} "}#{player.name}" <>
      if(rating > 0, do: " (#{rating})", else: "")
  end

  # Board-list label only: `player_label/1` plus the player's score coming
  # into this round, in the same parenthetical - "Name (2400, 2.5)", or
  # "Name (2.5)" with no rating.
  defp seat_label(nil, _scores), do: ""

  defp seat_label(player, scores) do
    rating = PairingsEngine.Tournaments.Player.rating(player)
    score = format_score(Map.get(scores, player.id, 0.0))
    title = if player.title != "", do: "#{player.title} "

    bracket = if rating > 0, do: "(#{rating}, #{score})", else: "(#{score})"

    "#{title}#{player.name} #{bracket}"
  end

  defp format_score(v) when is_float(v) do
    if v == Float.round(v, 0), do: trunc(v), else: v
  end

  defp format_score(v), do: v

  defp result_label(result), do: Map.get(@result_labels, result, result)

  # Same display logic the authenticated Pairings page uses
  # (`PairingsEngineWeb.PairingsLive.display_rows/1`) - fixed-table
  # ("special") boards renumbered/relabeled and moved to the end, byes and
  # vacant seats sorted below those, real boards renumbered to close the
  # gap. Before this, this page just sorted by raw `pairing.board`, so
  # the projector view silently disagreed with the Pairings page (and
  # print) on both the board LABEL and the row ORDER the moment a
  # tournament had a fixed-table player, a bye, or an absence.
  # Hidden rows (an arbiter's "don't show me this fully-vacated board" -
  # see `PairingsEngine.Tournaments.set_pairing_hidden/3`) are filtered out
  # before they ever reach `PairingDisplay`, so a hidden row plays no part
  # in the (already-frozen - see `PairingDisplay`'s moduledoc) board
  # renumbering at all, same as PairingsLive's own `display_rows/1`.
  defp display_rows(pairings) do
    pairings |> Enum.reject(& &1.hidden) |> PairingDisplay.with_display_boards()
  end

  # Label for a byes-table row's `type` - distinct from the "bye" badge
  # shown for a pairing-allocated bye (a real Pairing row), since these
  # never appear in round.pairings (see Tournaments.list_byes_for_round/2).
  defp bye_type_label("requested-half"), do: "requested half-point bye"
  defp bye_type_label("requested-zero"), do: "requested zero-point bye"
  defp bye_type_label("absent"), do: "absent"
  defp bye_type_label(other), do: other

  defp format_tb(value) when is_float(value) do
    if value == Float.round(value, 0), do: trunc(value), else: value
  end

  defp format_tb(value), do: value

  defp tb_name(code), do: (Tiebreaks.get(code) || %{name: code}).name

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
      tournament={@tournament}
      active="live"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">
            <%= if @round_number > 0 do %>
              {gettext("Live · Round %{n}", n: @round_number)}
            <% else %>
              {gettext("Live · no rounds paired yet")}
            <% end %>
          </p>
        </div>

        <div class="actions" style="margin: 0">
          <%!-- Only worth offering once there is something to project. --%>
          <button :if={@round} type="button" class="pe-btn" phx-click="toggle_display">
            {if @display?, do: gettext("Leave projector view"), else: gettext("Projector view")}
          </button>

          <%!-- The override. On by default because this is aimed at a bright
                room; off for the arbiter who is only checking the page on
                their own screen, or a hall dark enough not to need it. --%>
          <button :if={@display?} type="button" class="pe-btn" phx-click="toggle_contrast">
            {if @high_contrast?,
              do: gettext("Use my theme"),
              else: gettext("High contrast")}
          </button>
        </div>
      </div>

      <%!-- Not offered on a local run, because it cannot work there and
            looks like it can. Two independent reasons, either of which is
            enough: the QR encodes this endpoint's host, which local mode
            sets to "localhost", so a phone scanning it resolves its OWN
            localhost; and the listener is pinned to 127.0.0.1, so even the
            laptop's real LAN address would be refused.

            That pin is not incidental - `config/runtime.exs` calls it "what
            makes local mode safe to have at all", since the mode prints
            login links to a terminal and auto-signs-in whoever reaches it.
            Binding wider to make this feature work would hand
            sign-in-as-the-owner to everyone on the venue wifi. So this is a
            property of the deployment, not a missing feature, and the panel
            says which rather than disappearing without explanation. --%>
      <details :if={local_mode?()} class="card" style="margin-bottom: 20px">
        <summary style="cursor: pointer; font-weight: 650">
          {gettext("📱 Enrol a phone to enter results")}
        </summary>

        <p class="hint">
          {gettext(
            "Not available when OpenPairings runs on your own computer. This machine only accepts connections from itself - which is what keeps a no-login build safe - so a phone cannot reach it, and the QR code would point the phone at itself. Helpers can enter results from a phone when a tournament runs on a shared server."
          )}
        </p>
      </details>

      <details :if={not local_mode?()} class="card" style="margin-bottom: 20px">
        <summary style="cursor: pointer; font-weight: 650">
          {gettext("📱 Enrol a phone to enter results")}
        </summary>

        <p class="hint">
          {gettext(
            "Let helpers enter results from their phone, no account needed. Show them the QR code or the 6-digit code. Access is result-entry only, scoped to this tournament, and you can revoke it any time."
          )}
        </p>

        <%!-- Level + board range travel WITH the code from the moment it is
              minted - there is no "edit an enrolment" screen, so whatever is
              picked here is what that code does for its whole life. Kept to
              two compact fields (a level picker, an optional board range) on
              purpose: a permission matrix of checkboxes is easier to
              misconfigure in a hall with players waiting than one dropdown
              that names the two levels plainly.

              The name field goes FIRST, ahead of the level picker it used
              to open on - now that a code is good for one phone only, "who
              is this for" is the first thing worth asking, not an
              afterthought filled in (or not) after the access decision. Not
              `required`, though: an arbiter mid-round handing out codes as
              fast as they can type still needs to mint one with nothing but
              a tap on the button. --%>
        <form
          phx-submit="generate_enrollment"
          style="display: flex; flex-wrap: wrap; gap: 12px; align-items: flex-end; margin: 0"
        >
          <label style="display: flex; flex-direction: column; gap: 2px; font-size: 13px">
            {gettext("Name (optional)")}
            <input
              type="text"
              name="label"
              class="pe-input"
              maxlength="60"
              placeholder={gettext("Anke, Board 1-10 helper")}
            />
          </label>

          <label style="display: flex; flex-direction: column; gap: 2px; font-size: 13px">
            {gettext("Access level")}
            <select name="level" class="pe-select">
              <option value="helper">{gettext("Helper - fill blanks, latest round only")}</option>
              <option value="deputy">{gettext("Deputy - enter and correct, any round")}</option>
            </select>
          </label>

          <label style="display: flex; flex-direction: column; gap: 2px; font-size: 13px">
            {gettext("Boards (optional)")}
            <span style="display: flex; gap: 4px; align-items: center">
              <input
                type="number"
                min="1"
                name="board_from"
                class="pe-input"
                style="width: 64px"
                placeholder={gettext("from")}
              />
              <span aria-hidden="true">–</span>
              <input
                type="number"
                min="1"
                name="board_to"
                class="pe-input"
                style="width: 64px"
                placeholder={gettext("to")}
              />
            </span>
          </label>

          <button class="pe-btn primary" type="submit">{gettext("Generate a code")}</button>
        </form>

        <div :if={@new_enrollment} class="enroll-panel" style="margin-top: 16px">
          <div class="enroll-qr">
            <div class="enroll-qr-inner">
              {Phoenix.HTML.raw(Mobile.qr_svg(url(~p"/m/e/#{@new_enrollment.token}")))}
            </div>
          </div>
          <div>
            <%!-- Named FIRST here too, above the code itself - this panel is
                  what the arbiter is looking at while handing the phone
                  over, and "which phone is this" is what settles that,
                  not the digits. Absent when nothing was typed, same as
                  the device list below leaving no gap where it would sit. --%>
            <div :if={@new_enrollment.label != ""} class="enroll-name">
              {@new_enrollment.label}
            </div>
            <div class="enroll-code-label">{gettext("6-digit code")}</div>
            <div class="enroll-code">{@new_enrollment.code}</div>
            <p class="enroll-url">
              <.rich_text text={
                gettext("Scan the QR, or open %[url] on the phone and enter the code.")
              }>
                <:part name="url"><strong>{url(~p"/m")}</strong></:part>
              </.rich_text>
            </p>
            <p class="hint">{enrollment_scope_label(@new_enrollment)}</p>
            <p class="hint">
              {gettext("Expires %{when}.", when: enroll_expiry(@new_enrollment.expires_at))}
            </p>
          </div>
        </div>

        <div :if={@enrollments != []} style="margin-top: 18px">
          <h3 style="margin: 0 0 8px; font-size: 14px">{gettext("Active phones")}</h3>
          <table class="pe-table">
            <tbody>
              <tr :for={e <- @enrollments}>
                <td><strong>{enrollment_name_label(e)}</strong></td>
                <td class="hint">{gettext("Code %{code}", code: e.code)}</td>
                <td class="hint">{enrollment_scope_label(e)}</td>
                <td class="hint">{claim_status_label(e)}</td>
                <td class="hint">{gettext("expires %{when}", when: enroll_expiry(e.expires_at))}</td>
                <td style="text-align: right">
                  <button class="pe-btn danger-link" phx-click="revoke_enrollment" phx-value-id={e.id}>
                    {gettext("Revoke")}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </details>

      <details class="card" style="margin-bottom: 20px">
        <summary style="cursor: pointer; font-weight: 650">
          {gettext("📣 Let spectators follow the standings")}
        </summary>

        <%= if PublicLink.public?(@tournament) do %>
          <p class="hint">
            {gettext(
              "Anyone can scan this to open live standings on their own phone - no login needed."
            )}
          </p>
          <div class="enroll-panel" style="margin-top: 16px">
            <div class="enroll-qr">
              <div class="enroll-qr-inner">
                {Phoenix.HTML.raw(Mobile.qr_svg(PublicLink.url(@tournament, :standings)))}
              </div>
            </div>
            <div>
              <p class="enroll-url">
                <.rich_text text={gettext("Or open %[url]")}>
                  <:part name="url">
                    <strong>{PublicLink.url(@tournament, :standings)}</strong>
                  </:part>
                </.rich_text>
              </p>
            </div>
          </div>
        <% else %>
          <p class="hint">
            <.rich_text text={
              gettext(
                "This tournament is not published, so there is no page for spectators to open. %[settings] to publish it to the results site and get a link and QR code."
              )
            }>
              <:part name="settings">
                <.link navigate={~p"/t/#{@tournament.id}/settings"}>
                  {gettext("Turn publishing on in Settings")}
                </.link>
              </:part>
            </.rich_text>
          </p>
        <% end %>
      </details>

      <div :if={@round == nil and @paired_rounds == 0} class="card empty">
        <p><strong>{gettext("No round has been paired yet.")}</strong></p>
      </div>

      <%!-- A round exists but is not public. Said plainly, because the
            alternative is a screen that looks a round behind with no reason
            given - and an arbiter who assumes the page is broken rather than
            that they have not published yet. --%>
      <div :if={@paired_rounds > @round_number} class="card note">
        <p style="margin: 0 0 6px">
          <strong>
            {gettext("Round %{n} is paired but not published.", n: @paired_rounds)}
          </strong>
        </p>
        <p class="hint" style="margin: 0">
          {gettext(
            "This view shows what is public, so a round is never on a screen in the hall while it is being held back from the results site. Publish it on the pairings page to show it here."
          )}
        </p>
        <div class="actions" style="margin-top: 10px">
          <.link navigate={~p"/t/#{@tournament.id}/pairings"} class="pe-btn">
            {gettext("Go to pairings")}
          </.link>
        </div>
      </div>

      <%!-- `data-theme` is a bare attribute selector in app.css, so putting it
            here hands this subtree the contrast palette without a single new
            colour: the projector gets the theme built for exactly this, and
            the arbiter's own theme is left alone everywhere else. --%>
      <div
        :if={@round}
        class={["card table-card", @display? && "hall-screen"]}
        data-theme={@display? and @high_contrast? and "contrast"}
        id="hall-boards"
        phx-hook=".BoardFit"
        phx-click={@display? && "toggle_pause"}
      >
        <%!-- Same White-right/Result-centre/Black-left convention as the
             pairings page's own table (see `assets/css/app.css`), scoped
             to this table's own narrower fixed Result width via
             `#hall-boards` - this screen is read from across a room, not a
             desk, so it doesn't need the arbiter page's 220px. --%>
        <table class="pe-table">
          <thead>
            <tr>
              <th class="num">{gettext("Board")}</th>
              <th class="pairing-white">{gettext("White")}</th>
              <th class="pairing-result">{gettext("Result")}</th>
              <th class="pairing-black">{gettext("Black")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={
              %{pairing: pairing, board: display_board} <-
                page_rows(assigns, display_rows(@round.pairings))
            }>
              <td class="num">{display_board}</td>
              <td class="pairing-white">
                <strong>{seat_label(pairing.white_player, @scores)}</strong>
              </td>
              <td class="pairing-result">
                <%= cond do %>
                  <% pairing.result == "bye" -> %>
                    <span class="badge">{gettext("bye (%{pts} pt)", pts: @tournament.bye_value)}</span>
                  <% pairing.result == "" -> %>
                    <span class="badge muted">{gettext("in progress")}</span>
                  <% true -> %>
                    <span class="badge">{result_label(pairing.result)}</span>
                <% end %>
              </td>
              <td class="pairing-black">{seat_label(pairing.black_player, @scores)}</td>
            </tr>
          </tbody>
        </table>

        <%!-- Only when it actually cycles. A page counter over a single page
              of boards is machinery with nothing to do, and a viewer reading
              "1 of 1" learns only that somebody could not be bothered to
              check. --%>
        <div :if={@display? and page_count_for(assigns) > 1} class="hall-foot">
          <span class="hall-page">
            {gettext("Page %{n} of %{total}", n: @page + 1, total: page_count_for(assigns))}
          </span>

          <span :if={@paused?} class="hall-paused">{gettext("Paused - tap to resume")}</span>

          <%!-- The bar is not decoration: somebody looking for board 47 needs
                to know their page is coming and roughly when, or a rotating
                screen is worse than a still one. --%>
          <span :if={not @paused?} class="hall-bar" aria-hidden="true">
            <span class="hall-bar-fill" style={"animation-duration: #{cycle_ms()}ms"}></span>
          </span>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".BoardFit">
        // Measures how many board rows this screen can actually hold and tells
        // the server, so a hall screen fits itself to whatever it is plugged
        // into rather than to a number somebody guessed. The server owns which
        // page is showing; this only reports the shape of the glass.
        export default {
          mounted() {
            this.report = () => {
              if (!this.el.classList.contains("hall-screen")) return;

              const row = this.el.querySelector("tbody tr");
              const head = this.el.querySelector("thead");
              if (!row) return;

              const rowHeight = row.getBoundingClientRect().height;
              if (rowHeight <= 0) return;

              // Measure from the table's own top to the bottom of the window,
              // so page furniture above it is accounted for without having to
              // know what any of it is.
              const top = this.el.getBoundingClientRect().top;
              const headHeight = head ? head.getBoundingClientRect().height : 0;
              // Room for the footer and a little breathing space, so the last
              // row is never half-clipped at the bottom edge.
              const chrome = headHeight + 96;
              const usable = window.innerHeight - top - chrome;

              const rows = Math.max(Math.floor(usable / rowHeight), 1);
              if (rows !== this.lastRows) {
                this.lastRows = rows;
                this.pushEvent("rows_fit", { rows: rows });
              }
            };

            // Re-measure when the window changes: a screen gets rotated, a
            // window is dragged to another monitor, the browser chrome appears.
            this.onResize = () => window.requestAnimationFrame(this.report);
            window.addEventListener("resize", this.onResize);
            this.report();
          },

          updated() {
            this.report();
          },

          destroyed() {
            window.removeEventListener("resize", this.onResize);
          }
        }
      </script>

      <div :if={@round_byes != []} class="card table-card" style="margin-top: 16px">
        <table class="pe-table">
          <thead>
            <tr>
              <th>{gettext("Player")}</th>
              <th style="text-align: center; width: 220px">Bye</th>
            </tr>
          </thead>

          <tbody>
            <tr :for={bye <- @round_byes}>
              <td>{player_label(bye.player)}</td>

              <td style="text-align: center">
                <span class="badge">
                  {bye_type_label(bye.type)} ({Standings.bye_points_for_row(
                    bye,
                    @tournament,
                    @absent_counts
                  )} pt)
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <h2 style="margin-top: 32px">{gettext("Standings")}</h2>

      <div :if={@entries == []} class="card empty">
        <p><strong>{gettext("No players registered yet.")}</strong></p>
      </div>

      <div :if={@entries != [] and !@keizer?} class="card table-card">
        <table class="pe-table">
          <thead>
            <tr>
              <th class="num">{gettext("Rank")}</th>
              <th>{gettext("Name")}</th>
              <th class="num">Elo</th>
              <th class="num">Pts</th>
              <th :for={code <- @tournament.tiebreaks} class="num" title={tb_name(code)}>
                {code}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={entry <- @entries}>
              <td class="num">{entry.rank}</td>
              <td>
                <strong>
                  {if entry.player.title != "", do: "#{entry.player.title} "}{entry.player.name}
                </strong>
              </td>
              <td class="num">
                {if PairingsEngine.Tournaments.Player.rating(entry.player) > 0,
                  do: PairingsEngine.Tournaments.Player.rating(entry.player),
                  else: "-"}
              </td>
              <td class="num"><strong>{entry.points}</strong></td>
              <td :for={code <- @tournament.tiebreaks} class="num">
                {format_tb(Map.get(entry.tiebreaks, code, 0.0))}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@entries != [] and @keizer?} class="card table-card">
        <table class="pe-table">
          <thead>
            <tr>
              <th class="num">{gettext("Rank")}</th>
              <th>{gettext("Name")}</th>
              <th class="num">Elo</th>
              <th class="num">{gettext("Value")}</th>
              <th class="num">{gettext("Keizer pts")}</th>
              <th class="num">{gettext("Score")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={entry <- @entries}>
              <td class="num">{entry.rank}</td>
              <td>
                <strong>
                  {if entry.player.title != "", do: "#{entry.player.title} "}{entry.player.name}
                </strong>
              </td>
              <td class="num">
                {if PairingsEngine.Tournaments.Player.rating(entry.player) > 0,
                  do: PairingsEngine.Tournaments.Player.rating(entry.player),
                  else: "-"}
              </td>
              <td class="num">{entry.value}</td>
              <td class="num"><strong>{entry.points}</strong></td>
              <td class="num">{entry.raw_points}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end

  # One reader for "is this a local run", like every other consumer of
  # this flag in the app.
  defp local_mode?, do: PairingsEngine.Authz.local_mode?()
end
