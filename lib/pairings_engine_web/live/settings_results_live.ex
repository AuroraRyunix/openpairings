defmodule PairingsEngineWeb.SettingsResultsLive do
  @moduledoc """
  The "Results site" settings page (`/t/:id/settings/results`) - everything
  about this tournament's public existence, in one place.

  ## Why it is one page

  These controls were spread across two others and read as unrelated: the
  publish switch and the share link sat under Tournament next to the logo
  uploader, while the entry form sat under Options next to pairing
  preferences. They are not unrelated. Every one of them answers some part
  of "what does the public see", and an arbiter about to put an event online
  wants that question answered on one screen rather than assembled from two.

  It also gives the ticks somewhere to live. "Show clubs" is meaningless
  beside a logo uploader and obvious beside "publish this tournament".

  ## What is deliberately still elsewhere

  Reviewing entries. That is a working screen with a list and decisions on
  it, not a setting, and it lives with the players it creates. There is a
  link to it from here.
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport

  alias PairingsEngine.{Audit, PublicDisplay, Publishing, Tournaments}
  alias PairingsEngineWeb.PublicLink

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     socket
     |> assign(
       tournament: tournament,
       page_title: "#{tournament.name} · Results site",
       openresults_configured?: Publishing.configured?(),
       stale: false
     )}
  end

  @impl true
  def handle_info({:tournament_changed, _id, _hint}, socket) do
    case Tournaments.get_authorized_tournament(
           socket.assigns.current_scope,
           socket.assigns.tournament.id
         ) do
      nil -> {:noreply, push_navigate(socket, to: ~p"/")}
      tournament -> {:noreply, assign(socket, tournament: tournament)}
    end
  end

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

  # The whole form, not one checkbox: `phx-change` on the form sends every
  # ticked box and omits every unticked one, which is exactly what
  # `PublicDisplay.cast/1` reads. Handling one box at a time would mean
  # tracking state this page does not need to hold.
  def handle_event("save_display", params, socket) do
    display = Map.get(params, "display", %{})

    case Tournaments.set_public_display(socket.assigns.tournament, display) do
      {:ok, tournament} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "openresults.display", %{
          hidden: tournament.public_display |> Map.keys() |> Enum.sort()
        })

        {:noreply, assign(socket, tournament: tournament)}

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

  defp listed?(tournament), do: tournament.public_listed != false

  defp show?(tournament, key), do: PublicDisplay.show?(tournament.public_display, key)

  defp hidden_count(tournament) do
    Enum.count(PublicDisplay.keys(), &(not show?(tournament, &1)))
  end

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
    assigns = assign(assigns, display_fields: PublicDisplay.fields())

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">{gettext("Results site")}</p>
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

        <p
          :if={not @openresults_configured?}
          class="hint"
          style="margin: 6px 0 0; color: var(--danger)"
        >
          {gettext("No results site is set up on this machine yet - see Connections.")}
        </p>

        <div class="set-field solo">
          <span class="set-label">{gettext("Published")}</span>
          <div class="actions" style="margin-top: 6px; align-items: center; gap: 10px">
            <span>{if @tournament.publish_to_openresults, do: "On", else: "Off"}</span>
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
            <span>{if listed?(@tournament), do: "Listed", else: "Unlisted"}</span>
            <button type="button" class="pe-btn" phx-click="toggle_listed">
              {if listed?(@tournament), do: "Unlist it", else: "List it"}
            </button>
          </div>
        </div>
      </div>

      <div class="card">
        <h2>{gettext("What the public page shows")}</h2>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "Untick anything this event's players would not expect on the open web. A club evening and an international open have different answers, and you are the one who knows which this is."
          )}
        </p>

        <p class="hint">
          {gettext(
            "Names, board numbers, results and placings are always shown - they are the tournament. If those should not be public, do not publish."
          )}
        </p>

        <form phx-change="save_display">
          <div :for={field <- @display_fields} class="set-field solo" style="margin-top: 12px">
            <label style="display: flex; gap: 10px; align-items: flex-start; cursor: pointer">
              <input
                type="checkbox"
                name={"display[#{field.key}]"}
                value="true"
                checked={show?(@tournament, field.key)}
                style="margin-top: 3px"
              />
              <span>
                <strong>{field.label}</strong>
                <span class="hint" style="display: block; margin: 2px 0 0">{field.hint}</span>
              </span>
            </label>
          </div>
        </form>

        <p :if={hidden_count(@tournament) > 0} class="hint" style="margin-top: 14px">
          {gettext("Hidden: %{n} of %{total}. Saved as you tick.",
            n: hidden_count(@tournament),
            total: length(@display_fields)
          )}
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
            <span>{if @tournament.registration_open, do: "Open", else: "Closed"}</span>
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
end
