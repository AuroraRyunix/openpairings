defmodule PairingsEngineWeb.SettingsResultsLive do
  @moduledoc """
  The "Results site" settings page (`/t/:id/settings/results`) - everything
  about this tournament's public existence, in one place.

  ## Why it is one page

  These controls were spread across two others and read as unrelated: the
  publish switch and the share link sat under Tournament next to the logo
  uploader, while the entry form and the publish-each-round timing sat under
  Options next to pairing preferences. They are not unrelated. Every one of
  them answers some part of "what does the public see", and an arbiter about
  to put an event online wants that question answered on one screen rather
  than assembled from two.

  It also gives the ticks somewhere to live. "Show clubs" is meaningless
  beside a logo uploader and obvious beside "publish this tournament".

  ## What is deliberately still elsewhere

  Reviewing entries. That is a working screen with a list and decisions on
  it, not a setting, and it lives with the players it creates. There is a
  link to it from here.
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport

  import PairingsEngineWeb.Components.ConnectionStatus

  alias PairingsEngine.{Audit, PublicDisplay, Publishing, Standings, Tiebreaks, Tournaments}
  alias PairingsEngine.Tournaments.Tournament
  alias PairingsEngineWeb.PublicLink

  # Polled rather than pushed. The question is "can this machine publish right
  # now", and only asking produces an answer - there is no event to subscribe
  # to for "the wifi came back". Slow enough not to hammer the results site
  # from an idle settings page, fast enough that an arbiter who has just
  # plugged a cable back in sees it go green without reloading.
  @connection_poll :timer.seconds(10)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
      if connection_polling?(), do: send(self(), :poll_connection)
    end

    {:ok,
     socket
     |> assign(
       tournament: tournament,
       page_title: "#{tournament.name} · OpenResults",
       openresults_configured?: Publishing.configured?(),
       # Tracked as its own assign so the "Delay (minutes)" field can be
       # shown/hidden live as the "Publish each round" select changes,
       # without waiting for a round trip through `@tournament`.
       publish_mode: tournament.publish_mode,
       connection: nil,
       stale: false
     )
     |> assign_ranking_tiebreaks()}
  end

  @impl true
  def handle_info({:tournament_changed, _id, _hint}, socket) do
    case Tournaments.get_authorized_tournament(
           socket.assigns.current_scope,
           socket.assigns.tournament.id
         ) do
      nil ->
        {:noreply, push_navigate(socket, to: ~p"/")}

      tournament ->
        # Re-derived, not carried: the tie-break selection is edited on
        # another settings page, and a broadcast from there has to move the
        # checkboxes here.
        {:noreply,
         socket
         |> assign(tournament: tournament, publish_mode: tournament.publish_mode)
         |> assign_ranking_tiebreaks()}
    end
  end

  # In a task, never in this process. `Publishing.status/0` is a network round
  # trip with a fifteen-second timeout, and running it here would freeze the
  # page - every click, every toggle - for as long as an unreachable results
  # site takes to give up.
  def handle_info(:poll_connection, socket) do
    parent = self()

    Task.Supervisor.start_child(PairingsEngine.TaskSupervisor, fn ->
      # Rescued because this is a network call and the page must survive
      # anything it does: a check that blows up leaves the last known state on
      # screen rather than taking the settings page with it.
      status =
        try do
          Publishing.status()
        rescue
          _ -> nil
        catch
          _, _ -> nil
        end

      if status, do: send(parent, {:connection, status})
    end)

    Process.send_after(self(), :poll_connection, @connection_poll)
    {:noreply, socket}
  end

  def handle_info({:connection, status}, socket) do
    {:noreply, assign(socket, connection: status)}
  end

  # Last, so it cannot swallow the clauses above it - which it did, silently,
  # the first time the poll was added below it.
  def handle_info(_message, socket), do: {:noreply, socket}

  ## ---------- publishing ----------

  @impl true
  def handle_event("toggle_publish_to_openresults", _params, socket) do
    enabled? = !socket.assigns.tournament.publish_to_openresults

    case Tournaments.set_publish_to_openresults(socket.assigns.tournament, enabled?) do
      {:ok, tournament} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "openresults.toggled", %{
          enabled: enabled?
        })

        note =
          if enabled?,
            do: "This tournament will be published. The first copy is on its way.",
            else:
              "This tournament will not be published again. Anything already sent stays where it is."

        {:noreply, socket |> assign(tournament: tournament) |> put_flash(:info, note)}

      {:error, :archived} ->
        {:noreply, put_flash(socket, :error, error_text(:archived))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not change publishing")}
    end
  end

  def handle_event("toggle_listed", _params, socket) do
    listed? = !listed?(socket.assigns.tournament)

    case Tournaments.set_public_listed(socket.assigns.tournament, listed?) do
      {:ok, tournament} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "openresults.listed", %{
          listed: listed?
        })

        note =
          if listed?,
            do: "This tournament will appear on the results site's front page.",
            else: "This tournament is no longer listed. Its link still works."

        {:noreply, socket |> assign(tournament: tournament) |> put_flash(:info, note)}

      {:error, :archived} ->
        {:noreply, put_flash(socket, :error, error_text(:archived))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not change the listing")}
    end
  end

  ## ---------- when each paired round reaches the results site ----------

  # Purely cosmetic: shows/hides the "Delay (minutes)" field below as the
  # "Publish each round" select changes, so an arbiter isn't shown a field
  # that's ignored unless the mode is "timed" (see the field's own hint
  # text, still kept as a fallback).
  def handle_event(
        "publish_mode_change",
        %{"tournament" => %{"publish_mode" => mode}},
        socket
      ) do
    {:noreply, assign(socket, publish_mode: mode)}
  end

  def handle_event("save_publish_settings", %{"tournament" => params}, socket) do
    base = socket.assigns.tournament

    case Tournaments.update_tournament(base, params) do
      {:ok, tournament} ->
        log_settings_change(socket, base, tournament)

        {:noreply,
         socket
         |> assign(tournament: tournament, publish_mode: tournament.publish_mode)
         |> put_flash(:info, "Saved.")}

      {:error, :archived} ->
        {:noreply, put_flash(socket, :error, error_text(:archived))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save the publish settings")}
    end
  end

  # The whole form, not one checkbox: `phx-change` on the form sends every
  # ticked box and omits every unticked one, which is exactly what
  # `PublicDisplay.cast/1` reads. Handling one box at a time would mean
  # tracking state this page does not need to hold.
  def handle_event("save_display", params, socket) do
    display = Map.get(params, "display", %{})
    # `%{}` and not `nil`: the form always carries the tie-break block when
    # the columns are on, so an absent param means every box was unticked,
    # not that this caller is leaving the list alone.
    tiebreaks = Map.get(params, "tiebreak", %{})

    case Tournaments.set_public_display(socket.assigns.tournament, display, tiebreaks) do
      {:ok, tournament} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "openresults.display", %{
          hidden: tournament.public_display |> Map.keys() |> Enum.sort(),
          hidden_tiebreaks: Enum.sort(tournament.public_hidden_tiebreaks || [])
        })

        {:noreply, socket |> assign(tournament: tournament) |> assign_ranking_tiebreaks()}

      {:error, :archived} ->
        {:noreply, put_flash(socket, :error, error_text(:archived))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save what the public page shows")}
    end
  end

  ## ---------- the entry form ----------

  def handle_event("toggle_registration", _params, socket) do
    open? = !socket.assigns.tournament.registration_open

    case Tournaments.set_registration_open(socket.assigns.tournament, open?) do
      {:ok, tournament} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "registration.toggled", %{
          open: open?
        })

        note =
          if open?,
            do: "The entry form is open on the results site.",
            else: "The entry form is closed. Entries already collected are still here."

        {:noreply, socket |> assign(tournament: tournament) |> put_flash(:info, note)}

      {:error, :archived} ->
        {:noreply, put_flash(socket, :error, error_text(:archived))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not change the entry form")}
    end
  end

  ## ---------- the address, and taking it down ----------

  # `Publishing.rotate_address/1` rather than `Tournaments.rotate_public_slug/1`
  # - see that function for why the bare rotation is not a revocation once the
  # page being revoked is on another server.
  def handle_event("rotate_public_slug", _params, socket) do
    case Publishing.rotate_address(socket.assigns.tournament) do
      {:ok, tournament, message} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "public_pages.link_rotated", %{
          published: Publishing.published?(tournament)
        })

        {:noreply, socket |> assign(tournament: tournament) |> put_flash(:info, message)}

      {:error, :archived} ->
        {:noreply, put_flash(socket, :error, error_text(:archived))}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, "Could not move this tournament: " <> message)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not move this tournament")}
    end
  end

  def handle_event("take_down_published", _params, socket) do
    tournament = socket.assigns.tournament

    case Publishing.take_down(tournament) do
      {:ok, message} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "openresults.taken_down", %{
          slug: tournament.public_slug
        })

        {:noreply,
         socket
         |> assign(tournament: Tournaments.get_tournament!(tournament.id))
         |> put_flash(:info, message)}

      {:error, message} ->
        # Deliberately not reloaded and nothing assigned: a failed takedown
        # changed nothing, and re-rendering as if it might have is how
        # somebody ends up believing an event was withdrawn while it is up.
        {:noreply,
         put_flash(socket, :error, "Could not remove it from the results site: #{message}")}
    end
  end

  ## ---------- a key an imported backup carried ----------

  def handle_event("adopt_openresults_claim", _params, socket) do
    case Publishing.adopt_claim(socket.assigns.tournament) do
      {:ok, updated} ->
        Audit.log(updated.id, socket.assigns.current_scope, "openresults.claim_adopted", %{
          slug: updated.public_slug
        })

        {:noreply,
         socket
         |> assign(tournament: updated)
         |> put_flash(
           :info,
           "This tournament now publishes to the address the backup came from. Its own public " <>
             "link changed to match."
         )}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, "Could not take it over: #{message}")}
    end
  end

  def handle_event("discard_openresults_claim", _params, socket) do
    case Publishing.discard_claim(socket.assigns.tournament) do
      {:ok, updated} ->
        Audit.log(updated.id, socket.assigns.current_scope, "openresults.claim_discarded", %{})

        {:noreply,
         socket
         |> assign(tournament: updated)
         |> put_flash(:info, "Starting fresh. This copy will publish to an address of its own.")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  ## ---------- helpers ----------

  # Green for on, red for off, with the word as well as the colour - a pill
  # that only differs by hue is unreadable to a colourblind arbiter and
  # ambiguous to everyone at a glance ("is green on, or is green good?").
  attr :on?, :boolean, required: true
  attr :on, :string, required: true
  attr :off, :string, required: true

  defp state(assigns) do
    ~H"""
    <span class={["state-pill", @on? && "is-on"]}>{if @on?, do: @on, else: @off}</span>
    """
  end

  defp listed?(tournament), do: tournament.public_listed != false

  defp show?(tournament, key), do: PublicDisplay.show?(tournament.public_display, key)

  defp hidden_tiebreaks(tournament), do: tournament.public_hidden_tiebreaks || []

  defp tiebreak_name(code), do: (Tiebreaks.get(code) || %{name: code}).name
  defp tiebreak_hint(code), do: (Tiebreaks.get(code) || %{description: ""}).description

  # What the tournament actually ranks on, which is what has a column to
  # hide. `Standings.effective_tiebreaks/1` drops the ones C.07 Article 10
  # forbids here and the ones nothing can calculate, and offering a checkbox
  # for a column that is not there either way would be a control over
  # nothing.
  defp assign_ranking_tiebreaks(socket) do
    assign(socket, ranking_tiebreaks: Standings.effective_tiebreaks(socket.assigns.tournament))
  end

  defp hidden_count(tournament), do: PublicDisplay.hidden_count(tournament.public_display)

  # The address the imported key is authority over, as one string an arbiter
  # can compare against what they know. The endpoint is whatever the machine
  # that exported the file was pointing at, which is not necessarily this
  # machine's - showing it is the point, since "is that the server I mean?"
  # is the question a takeover turns on.
  defp claimed_address(tournament) do
    case Publishing.claim(tournament) do
      %{slug: slug, endpoint: ""} -> "/t/#{slug}"
      %{slug: slug, endpoint: endpoint} -> "#{endpoint}/t/#{slug}"
      nil -> ""
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      flash={@flash}
      current_scope={@current_scope}
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">{gettext("OpenResults")}</p>
        </div>
        <span class={["badge", @tournament.status == "setup" && "muted"]}>{@tournament.status}</span>
      </div>

      <.settings_subnav tournament={@tournament} active={:results} />

      <div class="card">
        <h2>{gettext("Publish this tournament")}</h2>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "Publishing sends a copy of this tournament to the results site, where anyone can follow it - standings, pairings and player cards, no login. It is the only way this tournament becomes public: nothing is readable from this machine, which is the point, because spectators should never be loading the computer that runs the round."
          )}
        </p>

        <p class="hint">
          {gettext(
            "What leaves is what a wall chart would show - names, ratings, clubs, federations and results. You can narrow that below."
          )}
        </p>

        <%!-- Compact here: this page is about one tournament, and the
              connection is context rather than its subject. The full box is
              on Connections, where it is the subject. --%>
        <div style="margin: 12px 0">
          <.connection_status status={@connection} compact />
        </div>

        <div class="set-field solo">
          <span class="set-label">{gettext("Published")}</span>
          <div class="actions" style="margin-top: 6px; align-items: center; gap: 10px">
            <.state on?={@tournament.publish_to_openresults} on="Published" off="Not published" />
            <button
              type="button"
              class="pe-btn"
              phx-click="toggle_publish_to_openresults"
              disabled={not @openresults_configured? and not @tournament.publish_to_openresults}
            >
              {if @tournament.publish_to_openresults, do: "Turn off", else: "Turn on"}
            </button>
          </div>
        </div>

        <div class="set-field solo" style="margin-top: 18px">
          <span class="set-label">{gettext("Listed on the front page")}</span>
          <p class="hint" style="margin: 4px 0 0">
            {gettext(
              "Whether this tournament appears in the results site's list of published tournaments. Off by default: publishing gives this tournament an address, and putting it on the front page is a separate choice."
            )}
          </p>
          <p class="hint" style="margin: 4px 0 0">
            <strong>{gettext("This is not privacy.")}</strong>
            {gettext(
              "An unlisted tournament is still readable by anyone who has its address, and addresses get forwarded. It hides the event from someone browsing the site, not from someone who was sent the link."
            )}
          </p>
          <div class="actions" style="margin-top: 6px; align-items: center; gap: 10px">
            <.state on?={listed?(@tournament)} on="Listed" off="Unlisted" />
            <button type="button" class="pe-btn" phx-click="toggle_listed">
              {if listed?(@tournament), do: "Unlist it", else: "List it"}
            </button>
          </div>
        </div>
      </div>

      <%!-- Moved from Settings -> Options on 2026-08-29, with the rest of
            this tournament's public existence - see the moduledoc. Its help
            text used to point at a local `/p/:slug/pairings` link removed
            the same day; PublicLink is what replaced it, so this shows
            whatever that module says the real address is, or isn't yet. --%>
      <form id="publish-settings-form" phx-submit="save_publish_settings">
        <div class="card">
          <h2>{gettext("Public pairings")}</h2>

          <p class="subtitle" style="margin: 0 0 8px">
            <.rich_text text={
              gettext(
                "When a round you pair actually reaches %[link] - gated on \"Publish this tournament\" above, not on this setting. Whichever round is currently paired can always be published early or hidden again by hand from the Pairings page, regardless of this setting."
              )
            }>
              <:part name="link">
                <%= if PublicLink.public?(@tournament) do %>
                  <code>{PublicLink.url(@tournament)}</code>
                <% else %>
                  {gettext("this tournament's page on the results site")}
                <% end %>
              </:part>
            </.rich_text>
          </p>

          <.setting_group>
            <.setting_field label={gettext("Publish each round")}>
              <select name="tournament[publish_mode]" phx-change="publish_mode_change">
                <option
                  :for={mode <- Tournament.publish_modes()}
                  value={mode}
                  selected={@tournament.publish_mode == mode}
                >
                  {Tournament.publish_mode_label(mode)}
                </option>
              </select>
            </.setting_field>

            <.setting_field
              :if={@publish_mode == "timed"}
              label={gettext("Delay (minutes)")}
              hint={gettext("Only used when 'Publish each round' above is set to 'After a delay'")}
            >
              <input
                type="number"
                name="tournament[publish_delay_minutes]"
                value={@tournament.publish_delay_minutes}
                min="0"
              />
            </.setting_field>
          </.setting_group>

          <div class="actions form-actions" style="margin-top: 14px">
            <button type="submit" class="pe-btn primary">{gettext("Save")}</button>
          </div>
        </div>
      </form>

      <div class="card">
        <h2>{gettext("What the public page shows")}</h2>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "Untick anything this event's players would not expect on the open web. A club evening and an international open have different answers, and you are the one who knows which this is. Saved as you tick."
          )}
        </p>

        <p class="hint">
          {gettext(
            "Names, boards, results and placings are always shown on a page that is shown at all - they are the tournament. To hide those, switch the whole page off above, or do not publish."
          )}
        </p>

        <%!-- A grid of compact toggles grouped by what they decide, rather
              than a stacked list with a paragraph under each. The old shape
              took most of a screen for seven boxes; this holds seventeen in
              less room, and grouping is what makes seventeen legible at all.
              The hint moves to the title attribute - it is a reminder, not
              something to read seventeen times. --%>
        <form phx-change="save_display">
          <div :for={{group, heading, about} <- PublicDisplay.groups()} class="display-group">
            <div class="display-group-head">
              <strong>{heading}</strong>
              <span class="hint">{about}</span>
            </div>

            <div class="display-grid">
              <label
                :for={field <- PublicDisplay.fields(group)}
                class={["display-toggle", show?(@tournament, field.key) && "is-on"]}
                title={field.hint}
              >
                <input
                  type="checkbox"
                  name={"display[#{field.key}]"}
                  value="true"
                  checked={show?(@tournament, field.key)}
                />
                <span>{field.label}</span>
              </label>
            </div>
          </div>

          <%!-- Only when the columns are on at all, and only the tie-breaks
                this tournament actually ranks on - a code Article 10 dropped
                has no column to hide. --%>
          <div
            :if={show?(@tournament, "tiebreaks") and @ranking_tiebreaks != []}
            class="display-group"
          >
            <div class="display-group-head">
              <strong>{gettext("Which tie-breaks")}</strong>
              <span class="hint">
                {gettext("Each column on the public standings. The order is unaffected.")}
              </span>
            </div>

            <div class="display-grid">
              <label
                :for={code <- @ranking_tiebreaks}
                class={["display-toggle", code not in hidden_tiebreaks(@tournament) && "is-on"]}
                title={tiebreak_hint(code)}
              >
                <input
                  type="checkbox"
                  name={"tiebreak[#{code}]"}
                  value="true"
                  checked={code not in hidden_tiebreaks(@tournament)}
                /> <span>{tiebreak_name(code)}</span>
              </label>
            </div>

            <%!-- The thing an arbiter has to know before ticking these off.
                  Hiding a column does not stop it deciding the order, so two
                  players can sit one above the other with every published
                  number identical. The public page says so rather than
                  leaving it unexplained, but it is better said here first. --%>
            <p :if={hidden_tiebreaks(@tournament) != []} class="hint">
              {gettext(
                "The order still uses every tie-break above. A hidden one keeps deciding placings it no longer explains, so the public page carries a note saying the order used tie-breaks it does not show."
              )}
            </p>
          </div>
        </form>

        <p class="hint" style="margin-top: 14px">
          <%= if hidden_count(@tournament) == 0 do %>
            {gettext("Everything is shown.")}
          <% else %>
            {gettext("%{n} of %{total} hidden.",
              n: hidden_count(@tournament),
              total: length(PublicDisplay.fields())
            )}
          <% end %>
        </p>
      </div>

      <div class="card">
        <h2>{gettext("Entry form")}</h2>

        <p class="hint" style="margin-top: 0">
          <.rich_text text={
            gettext(
              "A page on the results site where players enter themselves. Everyone who signs up arrives marked %[flag] - nobody is added here until you review the entries and accept them, so a wrong rating or a missing FIDE ID is something you fix rather than something that breaks anything."
            )
          }>
            <:part name="flag"><strong>{gettext("not yet arrived")}</strong></:part>
          </.rich_text>
        </p>

        <p :if={not PublicLink.public?(@tournament)} class="hint" style="color: var(--danger)">
          {gettext(
            "This tournament is not published, and the form lives there - so opening it here has no effect until you publish."
          )}
        </p>

        <div class="set-field solo">
          <span class="set-label">{gettext("Accepting entries")}</span>
          <div class="actions" style="margin-top: 6px; align-items: center; gap: 10px">
            <.state on?={@tournament.registration_open} on="Open" off="Closed" />
            <button
              type="button"
              class="pe-btn"
              phx-click="toggle_registration"
              data-confirm={
                if @tournament.registration_open,
                  do: "Close the form? Nobody will be able to enter until you open it again.",
                  else: nil
              }
            >
              {if @tournament.registration_open, do: "Close it", else: "Open it"}
            </button>

            <a
              :if={@tournament.registration_open && PublicLink.public?(@tournament)}
              class="pe-btn"
              href={PublicLink.url(@tournament, :register)}
              target="_blank"
            >
              {gettext("Open the form")}
            </a>
          </div>
        </div>

        <div class="actions" style="margin-top: 14px">
          <.link class="pe-btn" navigate={~p"/t/#{@tournament.id}/registrations"}>
            {gettext("Review entries")}
          </.link>
        </div>
      </div>

      <div :if={PublicLink.public?(@tournament) or Publishing.published?(@tournament)} class="card">
        <h2>{gettext("The address")}</h2>

        <div :if={PublicLink.public?(@tournament)} class="set-field solo">
          <span class="set-label">{gettext("Share link")}</span>
          <p class="hint" style="margin: 4px 0 0">
            {gettext(
              "On the results site (%{host}), not on this machine. Share it, print it, put it on a QR code.",
              host: PublicLink.host(@tournament)
            )}
          </p>
          <p style="margin: 6px 0 0">
            <code>{PublicLink.url(@tournament, :standings)}</code>
          </p>
          <div class="actions" style="margin-top: 6px; gap: 10px; flex-wrap: wrap">
            <a class="pe-btn" href={PublicLink.url(@tournament, :standings)} target="_blank">
              {gettext("Open it")}
            </a>

            <%!-- The wording is deliberate about what this now costs. While
                  this app served the public pages, rotating was free and
                  instant - the old link 404'd because it was served from the
                  same database the slug lived in. The link is an address on
                  another server now, so revoking it means taking that copy
                  DOWN and publishing again at a new one. --%>
            <button
              type="button"
              class="pe-btn danger-link"
              phx-click="rotate_public_slug"
              data-confirm={
                gettext(
                  "Move this tournament to a new address? The current link stops working immediately - anyone using it, including printed QR codes and anything a club has embedded, will need the new one. The tournament is removed from the results site and published again at a fresh address; its results and players here are untouched."
                )
              }
            >
              {gettext("Move to a new address")}
            </button>
          </div>
        </div>

        <%!-- Offered on the key, not on the switch. The switch says whether
              more will be sent; the key is what says something IS out there
              and that this machine is the one that can withdraw it. A
              tournament that opted in and never published has nothing to take
              down, and one switched off still does. --%>
        <div :if={Publishing.published?(@tournament)} style="margin-top: 14px">
          <p class="hint" style="margin: 0">
            {gettext(
              "A copy of this tournament is on the results site. Turning publishing off stops sending updates; it does not take that copy down."
            )}
          </p>
          <div class="actions" style="margin-top: 6px">
            <button
              type="button"
              class="pe-btn danger-link"
              phx-click="take_down_published"
              data-confirm={
                gettext(
                  "Remove this tournament from the results site? Its public page, every earlier snapshot in its history, and any entries collected for it are deleted there permanently. Nothing on this machine is touched - the tournament, its players and its results stay exactly as they are - but this cannot be undone from here."
                )
              }
            >
              {gettext("Remove from the results site")}
            </button>
          </div>
        </div>
      </div>

      <%!-- The choice an import deliberately did not make. Presented here
            rather than during the import because one backup file can hold
            dozens of tournaments, and a machine being rebuilt from backups
            usually has not been told the results site's address yet - so
            import time is the worst moment to ask. Doing nothing is the safe
            branch and needs no button: an unadopted copy publishes to a new
            address under a new key, i.e. it is a different tournament. --%>
      <div :if={Publishing.claim(@tournament)} class="card">
        <h2>{gettext("A publishing key came with this file")}</h2>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "The backup this tournament was imported from can publish to - and delete - a tournament already on the results site:"
          )}
        </p>

        <p style="margin: 6px 0 0"><code>{claimed_address(@tournament)}</code></p>

        <p class="hint" style="margin: 6px 0 0">
          {gettext(
            "Until you take it over, this copy is a separate tournament: turning publishing on gives it a new address of its own. Take it over only if the machine that published it is gone, or you are certain nobody else is still publishing it - two machines holding the same key can overwrite and delete each other's work."
          )}
        </p>

        <div class="actions" style="margin-top: 8px; gap: 10px; flex-wrap: wrap">
          <button
            type="button"
            class="pe-btn"
            phx-click="adopt_openresults_claim"
            data-confirm={
              gettext(
                "Take over publishing that tournament? This copy starts publishing to that address and can delete it, and this copy's own public link changes to match. Anyone still publishing it from another machine will be overwriting you, and you them."
              )
            }
          >
            {gettext("Take over publishing it")}
          </button>

          <button
            type="button"
            class="pe-btn danger-link"
            phx-click="discard_openresults_claim"
            data-confirm={
              gettext(
                "Start fresh and throw the key away? This copy keeps its own link and publishes to a new address. Nothing already on the results site changes, and this machine will never be able to update or remove it."
              )
            }
          >
            {gettext("Start fresh")}
          </button>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Off in the test environment, like every other timer in this app: a poll
  # firing mid-test would make a real request from a process that owns no HTTP
  # stub, and the failure would land in whichever test happened to be running.
  defp connection_polling?,
    do:
      Application.get_env(:pairings_engine, :connection_poll_interval, @connection_poll) !=
        :disabled
end
