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

  alias PairingsEngine.{
    Audit,
    HallDisplay,
    PublicDisplay,
    Publishing,
    Standings,
    Tiebreaks,
    Tournaments
  }

  alias PairingsEngine.Publishing.Installation
  alias PairingsEngine.Tournaments.Tournament
  alias PairingsEngineWeb.{PublicConsent, PublicLink}

  # Polled rather than pushed. The question is "can this machine publish right
  # now", and only asking produces an answer - there is no event to subscribe
  # to for "the wifi came back". Slow enough not to hammer the results site
  # from an idle settings page, fast enough that an arbiter who has just
  # plugged a cable back in sees it go green without reloading.
  @connection_poll :timer.seconds(10)

  # The longest "after N minutes" the pairings step takes - a day, the same
  # bound the account's default has.
  @max_delay 24 * 60

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
      # Public mode's steps move in the drain, not in this process.
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Publishing.queue_topic(tournament.id))
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Installation.topic())
      if connection_polling?(), do: send(self(), :poll_connection)
    end

    {:ok,
     socket
     |> assign(
       tournament: tournament,
       page_title: "#{tournament.name} · OpenResults",
       openresults_configured?: Publishing.configured?(),
       connection: nil,
       stale: false,
       consent: nil
     )
     |> assign_public_state()
     |> assign_ranking_tiebreaks()
     |> assign_hall_form()}
  end

  # Where this tournament is in public mode's steps, re-read whenever
  # anything that could move it is heard. Nil outside public mode, where
  # there are no steps.
  defp assign_public_state(socket) do
    public_state =
      if Publishing.public_mode?(), do: Publishing.public_state(socket.assigns.tournament)

    assign(socket, public_state: public_state)
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
        # The hall form is re-derived only when its own settings changed
        # (another tab saved them): any other broadcast - a result entered
        # elsewhere - must not throw away an announcement being typed.
        hall_changed? = tournament.public_hall != socket.assigns.tournament.public_hall

        socket =
          socket
          |> assign(tournament: tournament)
          |> assign_public_state()
          |> assign_ranking_tiebreaks()

        {:noreply, if(hall_changed?, do: assign_hall_form(socket), else: socket)}
    end
  end

  def handle_info({:publish_queue_changed, _id}, socket),
    do: {:noreply, assign_public_state(socket)}

  def handle_info(:installation_changed, socket), do: {:noreply, assign_public_state(socket)}

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

  # The consent dialog's question, fetched in a task - see
  # `PairingsEngineWeb.PublicConsent`. A server that does not offer public
  # publishing puts publishing back off at once: the dialog says so, and a
  # tournament left "on" that can never go anywhere would be a promise
  # nothing keeps.
  @impl true
  def handle_async(:public_server_info, result, socket) do
    socket = PublicConsent.received(socket, result)

    case socket.assigns.consent do
      {:failed, {:unconfigured, :token_required}, :first} ->
        {:noreply, switch_off_unconsented(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  # Public mode, before any consent: publishing goes back off and the queued
  # row goes with it. Only while nothing has been agreed - a computer that
  # already holds a key or a consent never reaches the dialog.
  defp switch_off_unconsented(socket) do
    tournament = socket.assigns.tournament

    if tournament.publish_to_openresults and needs_consent?() do
      case Tournaments.set_publish_to_openresults(tournament, false) do
        {:ok, updated} ->
          Publishing.dequeue(updated.id)
          socket |> assign(tournament: updated) |> assign_public_state()

        {:error, _reason} ->
          socket
      end
    else
      socket
    end
  end

  # Publishing on or off - what the old "Turn on"/"Turn off" button did,
  # consent question included.
  defp switch_publishing(socket, enabled?) do
    case Tournaments.set_publish_to_openresults(socket.assigns.tournament, enabled?) do
      {:ok, tournament} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "openresults.toggled", %{
          enabled: enabled?
        })

        socket = socket |> assign(tournament: tournament) |> assign_public_state()

        cond do
          enabled? and needs_consent?() ->
            # Publishing is requested - the row is queued and the page says
            # what it waits on - but nothing leaves until the arbiter has
            # answered the question this opens. See
            # `PairingsEngineWeb.PublicConsent`.
            {:noreply, PublicConsent.open(socket, :first)}

          # "The first copy is on its way" would not be true: the server has
          # stopped this installation, and the steps under the switch say so
          # with the button that answers it.
          enabled? and Publishing.public_mode?() and Installation.stopping_state?() ->
            {:noreply, socket}

          true ->
            toggled_note(socket, enabled?)
        end

      {:error, :archived} ->
        {:noreply, put_flash(socket, :error, error_text(:archived))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not change publishing"))}
    end
  end

  # The front-page flag, audited as the old "List it"/"Unlist it" button
  # audited it. A no-op when it already reads `listed?`.
  defp put_listed(socket, listed?) do
    tournament = socket.assigns.tournament

    if listed?(tournament) == listed? do
      {:ok, socket}
    else
      case Tournaments.set_public_listed(tournament, listed?) do
        {:ok, tournament} ->
          Audit.log(tournament.id, socket.assigns.current_scope, "openresults.listed", %{
            listed: listed?
          })

          {:ok, assign(socket, tournament: tournament)}

        {:error, :archived} ->
          {:error, put_flash(socket, :error, error_text(:archived))}

        {:error, _changeset} ->
          {:error, put_flash(socket, :error, gettext("Could not change the listing"))}
      end
    end
  end

  defp listed_note(socket, true),
    do:
      put_flash(
        socket,
        :info,
        gettext("This tournament will appear on the results site's front page.")
      )

  defp listed_note(socket, false),
    do:
      put_flash(
        socket,
        :info,
        gettext("This tournament is no longer listed. Its link still works.")
      )

  defp toggled_note(socket, enabled?) do
    note =
      if enabled?,
        do: "This tournament will be published. The first copy is on its way.",
        else:
          "This tournament will not be published again. Anything already sent stays where it is."

    {:noreply, put_flash(socket, :info, note)}
  end

  defp needs_consent? do
    Publishing.public_mode?() and not Installation.registered?() and
      not Installation.consented?() and not Installation.stopping_state?()
  end

  ## ---------- publishing ----------

  # "On the results site: Off · Link only · Listed" - the old "Published"
  # and "Listed on the front page" buttons as one control. Each stop is the
  # pair of flags it stands for (`presence/1`); moving between two stops
  # writes only the flag that differs, through the same setters and with
  # the same audit rows the two buttons wrote, so every consequence of
  # switching publishing on or off - the queued first copy, public mode's
  # consent question, the key, the steps under the control - is the one it
  # always was.
  #
  # The listing flag is written BEFORE publishing goes on, so the first
  # copy that leaves already says whether it belongs on the front page. Off
  # leaves the listing flag alone, as the old "Turn off" did: nothing more
  # is sent, and a copy already on the site stays as it is (see "The
  # address" below for taking it down).
  @impl true
  def handle_event("set_presence", %{"presence" => presence}, socket)
      when presence in ~w(off link listed) do
    tournament = socket.assigns.tournament
    target = String.to_existing_atom(presence)
    current = presence(tournament)

    cond do
      target == current ->
        {:noreply, socket}

      target == :off ->
        switch_publishing(socket, false)

      true ->
        with {:ok, socket} <- put_listed(socket, target == :listed) do
          if tournament.publish_to_openresults,
            do: {:noreply, listed_note(socket, target == :listed)},
            else: switch_publishing(socket, true)
        else
          {:error, socket} -> {:noreply, socket}
        end
    end
  end

  def handle_event("set_presence", _params, socket), do: {:noreply, socket}

  ## ---------- public mode: consent, registering again, trying again ----------

  def handle_event("public_consent_open", _params, socket) do
    {:noreply, PublicConsent.open(socket, :first)}
  end

  # Never silent: the arbiter pressed a button that says what it does, and
  # the same dialog asks again before anything is sent.
  def handle_event("public_register_again", _params, socket) do
    {:noreply, PublicConsent.open(socket, :again)}
  end

  def handle_event("public_consent_accept", _params, socket) do
    case PublicConsent.accept(socket) do
      {socket, %{} = info, purpose} ->
        Audit.log(
          socket.assigns.tournament.id,
          socket.assigns.current_scope,
          "openresults.public_consent_given",
          # Who runs the site and which site. Never the key: there is none
          # yet, and there never will be one in the audit trail.
          %{host: info.host, operator: info.operator, register_again: purpose == :again}
        )

        {:noreply,
         socket
         |> assign_public_state()
         |> put_flash(
           :info,
           gettext(
             "Thank you. This computer registers with %{host} and publishes as soon as it can - this page shows each step.",
             host: info.host
           )
         )}

      {socket, nil, nil} ->
        {:noreply, socket}
    end
  end

  def handle_event("public_consent_decline", _params, socket) do
    consent = socket.assigns.consent
    {socket, _purpose} = PublicConsent.dismiss(socket)

    case consent do
      # "Declining sends nothing and leaves publishing off."
      {:ask, info, :first} ->
        socket = switch_off_unconsented(socket)

        Audit.log(
          socket.assigns.tournament.id,
          socket.assigns.current_scope,
          "openresults.public_consent_declined",
          %{host: info.host}
        )

        {:noreply,
         put_flash(
           socket,
           :info,
           gettext("Nothing was sent. Publishing is off for this tournament.")
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("public_retry", _params, socket) do
    Publishing.retry(socket.assigns.tournament.id)

    {:noreply,
     socket
     |> assign_public_state()
     |> put_flash(:info, gettext("Trying again."))}
  end

  ## ---------- what the automation publishes by itself ----------

  # "Automatically: By hand · Pairings once paired · + results live ·
  # + standings when the round is finished" - `publish_mode`, see the
  # "Automatic publishing" section of `PairingsEngine.Tournaments`. Saved the
  # moment a stop is chosen; there is no Save button.
  def handle_event("set_auto_publish", %{"level" => level}, socket) do
    case parse_level(level) do
      nil -> {:noreply, socket}
      level -> save_auto_publish(socket, Tournament.publish_mode_for_level(level), nil)
    end
  end

  def handle_event("set_auto_publish", _params, socket), do: {:noreply, socket}

  # "after N minutes" beside the pairings step, saved as it is typed. A
  # value that is not a whole number of minutes is said, not saved.
  def handle_event("set_publish_delay", %{"delay" => delay}, socket) do
    case parse_delay(delay) do
      {minutes, ""} when minutes in 0..@max_delay ->
        if minutes == socket.assigns.tournament.publish_delay_minutes,
          do: {:noreply, socket},
          else: save_auto_publish(socket, socket.assigns.tournament.publish_mode, minutes)

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("The delay is a whole number of minutes, from 0 to %{max}.", max: @max_delay)
         )}
    end
  end

  def handle_event("set_publish_delay", _params, socket), do: {:noreply, socket}

  # "Before round 1, spectators see the starting ranking" - moved here from
  # the Standings page's "Initial standings" switch on 2026-09-28, and
  # audited under the same actions it wrote there.
  def handle_event("toggle_initial_standings", _params, socket) do
    tournament = socket.assigns.tournament
    on? = not Tournaments.initial_standings_public?(tournament)

    case Tournaments.set_initial_standings_public(tournament, on?) do
      {:ok, tournament} ->
        scope = socket.assigns.current_scope

        if on?,
          do: Audit.log(tournament.id, scope, "standings.published", %{through_round: 0}),
          else: Audit.log(tournament.id, scope, "standings.unpublished", %{from_round: 0})

        {:noreply, assign(socket, tournament: tournament)}

      {:error, :archived} ->
        {:noreply, put_flash(socket, :error, error_text(:archived))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not change this"))}
    end
  end

  # A page the retired "Standings"/"Round pairings" switch still keeps off.
  def handle_event("show_legacy_page", %{"key" => key}, socket) do
    case Tournaments.show_legacy_page(socket.assigns.tournament, key) do
      {:ok, tournament} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "openresults.display", %{
          hidden: tournament.public_display |> Map.keys() |> Enum.sort(),
          hidden_tiebreaks: Enum.sort(tournament.public_hidden_tiebreaks || [])
        })

        {:noreply, assign(socket, tournament: tournament)}

      {:error, :archived} ->
        {:noreply, put_flash(socket, :error, error_text(:archived))}

      {:error, _reason} ->
        {:noreply, socket}
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

  ## ---------- the hall display ----------

  # Saved on submit, never per keystroke: every save enqueues a publish, and
  # an announcement typed letter by letter would send one per letter.
  def handle_event("save_hall", %{"hall" => params}, socket) do
    case Tournaments.set_hall_display(socket.assigns.tournament, params) do
      {:ok, tournament} ->
        hall = HallDisplay.resolve(tournament.public_hall)

        # The settings, and whether there is an announcement - not its text,
        # which is on the results site for anyone to read and has no business
        # in the audit trail as well.
        Audit.log(
          tournament.id,
          socket.assigns.current_scope,
          "openresults.hall",
          hall
          |> Map.delete("announcement")
          |> Map.put("announcement", Map.has_key?(hall, "announcement"))
        )

        {:noreply,
         socket
         |> assign(tournament: tournament)
         |> assign_hall_form()
         |> put_flash(:info, gettext("Hall display saved."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, hall_form: to_form(changeset, as: :hall))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_text(reason))}
    end
  end

  def handle_event("save_hall", _params, socket), do: {:noreply, socket}

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

  defp save_auto_publish(socket, mode, delay) do
    case Tournaments.set_auto_publish(socket.assigns.tournament, mode, delay) do
      {:ok, tournament} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "openresults.auto_publish", %{
          mode: tournament.publish_mode,
          delay_minutes: tournament.publish_delay_minutes
        })

        {:noreply, assign(socket, tournament: tournament)}

      {:error, :archived} ->
        {:noreply, put_flash(socket, :error, error_text(:archived))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save the publish settings"))}
    end
  end

  defp parse_level(level) when is_integer(level) and level in 0..3, do: level

  defp parse_level(level) when is_binary(level) do
    case Integer.parse(level) do
      {n, ""} when n in 0..3 -> n
      _ -> nil
    end
  end

  defp parse_level(_level), do: nil

  defp parse_delay(delay) when is_integer(delay), do: {delay, ""}
  defp parse_delay(delay) when is_binary(delay), do: Integer.parse(String.trim(delay))
  defp parse_delay(_delay), do: :error

  # The stop "On the results site" shows.
  defp presence(%Tournament{publish_to_openresults: false}), do: :off
  defp presence(tournament), do: if(listed?(tournament), do: :listed, else: :link)

  defp presence_level(tournament) do
    case presence(tournament) do
      :off -> 0
      :link -> 1
      :listed -> 2
    end
  end

  # Whether any round's pairings are public - the moment the starting
  # ranking stops being this page's question, and raising the automation
  # starts to apply to something already out there.
  defp rounds_public?(tournament), do: Tournaments.latest_published_round_number(tournament) > 0

  # A setting as a track of stops - the Pairings page's per-round level
  # control (`PairingsEngineWeb.PairingsLive`'s `publish_level/1`) in its
  # settings form, same CSS (`.pe-level`, `.is-field`) and same keyboard
  # model, so "On the results site", "Automatically" and "Spectators see"
  # read as one family. `level` is the index of the chosen stop; each stop
  # carries its own `value` for `param`, and an optional `confirm`.
  attr :id, :string, required: true
  attr :caption, :string, required: true
  attr :label, :string, required: true
  attr :event, :string, required: true
  attr :param, :string, required: true
  attr :level, :integer, required: true
  attr :stops, :list, required: true

  defp setting_slider(assigns) do
    ~H"""
    <div
      id={@id}
      class="pe-level is-field"
      data-level={@level}
      data-stops={length(@stops)}
    >
      <span class="pe-level-caption" aria-hidden="true">{@caption}</span>
      <div
        id={"#{@id}-radios"}
        class="pe-level-track"
        role="radiogroup"
        aria-label={@label}
        phx-hook=".SettingSlider"
      >
        <span class="pe-level-range" aria-hidden="true"></span>
        <span class="pe-level-thumb" aria-hidden="true"></span>
        <button
          :for={{stop, index} <- Enum.with_index(@stops)}
          type="button"
          role="radio"
          id={"#{@id}-#{stop.value}"}
          class="pe-level-stop"
          aria-checked={to_string(index == @level)}
          aria-label={stop.name}
          tabindex={if index == @level, do: "0", else: "-1"}
          title={stop.hint}
          data-confirm={index != @level && stop[:confirm]}
          phx-click={@event}
          {%{"phx-value-#{@param}" => stop.value}}
        >
          <.icon name={stop.icon} class="pe-level-icon" />
          <span class="pe-level-text">{stop.label}</span>
        </button>
      </div>
    </div>
    """
  end

  defp presence_stops(tournament) do
    on? = tournament.publish_to_openresults

    [
      %{
        value: "off",
        icon: "hero-eye-slash-micro",
        label: gettext("Off"),
        name: gettext("Off - not published"),
        hint: gettext("Nothing is sent to the results site"),
        confirm:
          on? &&
            gettext(
              "Stop publishing this tournament? Nothing more is sent to the results site. A copy already there stays as it is - removing it is a separate step, under The address."
            )
      },
      %{
        value: "link",
        icon: "hero-link-micro",
        label: gettext("Link only"),
        name: gettext("Link only - published, not listed"),
        hint: gettext("Anyone with the address can follow it")
      },
      %{
        value: "listed",
        icon: "hero-globe-alt-micro",
        label: gettext("Listed"),
        name: gettext("Listed - published and on the front page"),
        hint: gettext("Also on the results site's front page")
      }
    ]
  end

  defp auto_publish_stops(tournament) do
    current = Tournament.auto_publish_level(tournament)
    public? = rounds_public?(tournament)

    [
      %{icon: "hero-hand-raised-micro", hint: gettext("Nothing goes public until you choose it")},
      %{
        icon: "hero-arrows-right-left-micro",
        hint: gettext("Who plays whom, once a round is paired")
      },
      %{icon: "hero-check-circle-micro", hint: gettext("Results as they are entered")},
      %{
        icon: "hero-numbered-list-micro",
        hint: gettext("The standings after a round, once every result in it is in")
      }
    ]
    |> Enum.with_index()
    |> Enum.map(fn {stop, level} ->
      label = auto_publish_label(Tournament.publish_mode_for_level(level))

      Map.merge(stop, %{
        value: level,
        label: label,
        name: label,
        confirm: (public? and level > current and level >= 2) && raise_confirm(level)
      })
    end)
  end

  # Raising the automation applies to the rounds already public too - said
  # before it happens, since results or standings go out at once.
  defp raise_confirm(2),
    do:
      gettext(
        "Results go live from now on - including the results of rounds whose pairings are already public. Continue?"
      )

  defp raise_confirm(3),
    do:
      gettext(
        "Results and standings go public by themselves from now on - including those of rounds already public and finished. Continue?"
      )

  defp auto_publish_about(0),
    do:
      gettext(
        "Nothing reaches spectators until you choose a round's level on the Pairings page, so you can check every round first. This is the default."
      )

  defp auto_publish_about(1),
    do:
      gettext(
        "A round's pairings go public once it is paired. Its results and the standings wait for you."
      )

  defp auto_publish_about(2),
    do:
      gettext(
        "A round's pairings go public once it is paired, and its results as they are entered. The standings wait for you."
      )

  defp auto_publish_about(3),
    do:
      gettext(
        "A round's pairings go public once it is paired, its results as they are entered, and the standings after it once every result in it - and in every round before it - is in."
      )

  defp legacy_page_text("standings"),
    do:
      gettext(
        "The standings page is still switched off, from before each round had its own level. It stays off until you show it; from then on the rounds' levels decide."
      )

  defp legacy_page_text("pairings"),
    do:
      gettext(
        "The round pairings pages are still switched off, from before each round had its own level. They stay off until you show them; from then on the rounds' levels decide."
      )

  defp legacy_page_button("standings"), do: gettext("Show the standings page")
  defp legacy_page_button("pairings"), do: gettext("Show the pairings pages")

  defp legacy_page_confirm("standings"),
    do:
      gettext(
        "Show the standings page on the results site? It shows the standings each round's level makes public."
      )

  defp legacy_page_confirm("pairings"),
    do:
      gettext(
        "Show the pairings pages on the results site? They show every round whose level makes its pairings public."
      )

  defp max_delay, do: @max_delay

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

  # The same pair of conditions the "Turn on/off" button's `disabled`
  # attribute used to encode on its own: nothing to do while there is no
  # server and nothing already publishing, but never hidden while the
  # tournament believes it is already publishing - losing "Turn off" on one
  # of those would be a trap, not a tidy-up.
  defp openresults_reachable?(tournament, configured?),
    do: configured? or tournament.publish_to_openresults

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

  defp hall_min(key), do: HallDisplay.range(key).first
  defp hall_max(key), do: HallDisplay.range(key).last

  defp assign_hall_form(socket) do
    changeset = HallDisplay.changeset(socket.assigns.tournament.public_hall)
    assign(socket, hall_form: to_form(changeset, as: :hall))
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
    ~H"""
    <%!-- `tournament` and `active` are not optional decoration here. Without
          them the top bar drops every tournament tab - Players, Pairings,
          Standings, Print, Advanced, Settings - and its Home link turns into
          "Tournaments", so opening this page reads as having left the
          tournament for a global settings screen. Every other settings page
          passes them; this one did not. --%>
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
          <p class="subtitle" style="margin: 0">{gettext("OpenResults")}</p>
        </div>
        <span class={["badge", @tournament.status == "setup" && "muted"]}>{@tournament.status}</span>
      </div>

      <.settings_subnav tournament={@tournament} active={:results} />

      <div
        :if={PairingsEngine.Tournaments.Tournament.team?(@tournament)}
        id="team-publish-note"
        class="card"
      >
        <h2>{gettext("Team tournament")}</h2>
        <p class="hint" style="margin-top: 0">
          {gettext(
            "Publishing sends the team standings, matches and board statistics OpenPairings computed - OpenResults never works out a team result on its own."
          )}
        </p>
      </div>

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

        <%!-- A switched-off feature owns its entrances - see
              `PairingsEngine.Features`'s moduledoc for the rule this
              follows. Both fields below exist to act on a results site;
              with none configured and nothing already publishing, there is
              nothing for either to do, so neither renders. The one
              exception is a tournament that already believes it is
              publishing: that pair MUST keep its "Turn off" button even
              with the connection gone, or there would be no way back. --%>
        <%= if openresults_reachable?(@tournament, @openresults_configured?) do %>
          <.setting_slider
            id="site-presence"
            caption={gettext("On the results site:")}
            label={gettext("Where this tournament is on the results site")}
            event="set_presence"
            param="presence"
            level={presence_level(@tournament)}
            stops={presence_stops(@tournament)}
          />

          <p id="site-presence-about" class="pe-level-about">
            <%= case presence(@tournament) do %>
              <% :off -> %>
                {gettext(
                  "Nothing is sent. Anything already on the results site stays there as it is."
                )}
              <% :link -> %>
                {gettext(
                  "Published at its own address, and not on the results site's front page - putting it there is a separate choice."
                )}
              <% :listed -> %>
                {gettext(
                  "Published, and listed on the results site's front page for anyone browsing it."
                )}
            <% end %>
          </p>

          <p :if={presence(@tournament) != :listed} class="pe-level-about">
            <strong>{gettext("Link only is not privacy.")}</strong>
            {gettext(
              "An unlisted tournament is still readable by anyone who has its address, and addresses get forwarded. It hides the event from someone browsing the site, not from someone who was sent the link."
            )}
          </p>

          <%!-- Public mode only: what "on" is still waiting for. Without it,
                a tournament switched on with no consent, no key or no
                address yet would read exactly like one that is live. --%>
          <PublicConsent.public_steps
            :if={@public_state}
            tournament={@tournament}
            state={@public_state}
          />
        <% else %>
          <p class="hint" style="margin-top: 18px">
            <.rich_text text={
              gettext("No results site is set up yet - connect one on the %[link] page.")
            }>
              <:part name="link">
                <.link navigate={~p"/fide"}>{gettext("Connections")}</.link>
              </:part>
            </.rich_text>
          </p>
        <% end %>
      </div>

      <%!-- What each round's level on the Pairings page gets moved up to
            without the arbiter pressing anything - the same four steps as
            that control, so the two read as one ladder. Replaced the
            "Publish each round" select, its delay field and its Save
            button on 2026-09-28; everything here saves as it is chosen. --%>
      <div class="card" id="auto-publish-card">
        <h2>{gettext("Publishing each round")}</h2>

        <p class="hint" style="margin-top: 0">
          <.rich_text text={
            gettext(
              "Each round has its own level on the Pairings page: what spectators see of it on %[link]. This moves every round up that ladder for you. You can always take a round back down by hand there, and it stays where you put it."
            )
          }>
            <:part name="link">
              <%= if PublicLink.public?(@tournament) do %>
                <code>{PublicLink.url(@tournament)}</code>
              <% else %>
                {gettext("the results site")}
              <% end %>
            </:part>
          </.rich_text>
        </p>

        <.setting_slider
          id="auto-publish"
          caption={gettext("Automatically:")}
          label={gettext("What is published automatically")}
          event="set_auto_publish"
          param="level"
          level={Tournament.auto_publish_level(@tournament)}
          stops={auto_publish_stops(@tournament)}
        />

        <%!-- The pairings step's optional delay, inline and autosaved. Kept
              when the automation is by hand, so switching back finds it. --%>
        <form
          :if={Tournament.auto_publish_level(@tournament) >= 1}
          id="publish-delay-form"
          class="auto-delay"
          phx-change="set_publish_delay"
          phx-submit="set_publish_delay"
        >
          <label for="publish-delay-input">{gettext("Pairings go public after")}</label>
          <input
            id="publish-delay-input"
            class="pe-input"
            type="number"
            name="delay"
            value={@tournament.publish_delay_minutes}
            min="0"
            max={max_delay()}
            step="1"
            inputmode="numeric"
            phx-debounce="600"
          />
          <span>{gettext("minutes (0: as soon as the round is paired)")}</span>
        </form>

        <p id="auto-publish-about" class="pe-level-about">
          {auto_publish_about(Tournament.auto_publish_level(@tournament))}
        </p>

        <%!-- Round 0, the one set of standings no round's level covers.
              Moved here from the Standings page on 2026-09-28: it is a
              setting about the time before the tournament starts, not a
              round to publish. --%>
        <div class="set-field solo" style="margin-top: 20px">
          <.publish_toggle
            id="initial-standings-toggle"
            label={gettext("Before round 1, spectators see the starting ranking")}
            state={
              if Tournaments.initial_standings_public?(@tournament),
                do: :public,
                else: :not_public
            }
            on_text={gettext("On")}
            off_text={gettext("Off")}
            disabled={rounds_public?(@tournament)}
            reason={
              gettext(
                "A round is public, so the players are too - the starting ranking only matters before that."
              )
            }
            confirm={gettext("Hide the starting ranking from spectators until round 1 is public?")}
            phx-click="toggle_initial_standings"
          />
          <p class="hint" style="margin: 6px 0 0">
            {gettext(
              "The players in start order, before a game has been played. Off: spectators see nothing until the first round's pairings are public."
            )}
          </p>
        </div>
      </div>

      <div class="card">
        <h2>{gettext("What the public page shows")}</h2>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "Untick anything this event's players would not expect on the open web. A club evening and an international open have different answers, and you are the one who knows which this is. Saved as you tick."
          )}
        </p>

        <p class="hint">
          {gettext(
            "Names, boards, results and placings are always shown on a page that is shown at all - they are the tournament. Whether a round's pairings, results and the standings after it are public is that round's level, above and on the Pairings page."
          )}
        </p>

        <%!-- The "Standings" and "Round pairings" switches were retired on
              2026-09-28. A tournament that had one off keeps that page off
              - the upgrade must not put it in front of spectators - and
              this is the way back. --%>
        <div
          :for={key <- PublicDisplay.legacy_hidden(@tournament.public_display)}
          id={"legacy-page-#{key}"}
          class="legacy-page-note"
        >
          <.icon name="hero-eye-slash-micro" />
          <p>{legacy_page_text(key)}</p>
          <button
            type="button"
            id={"show-legacy-page-#{key}"}
            class="pe-btn"
            phx-click="show_legacy_page"
            phx-value-key={key}
            data-confirm={legacy_page_confirm(key)}
          >
            {legacy_page_button(key)}
          </button>
        </div>

        <%!-- A grid of compact toggles grouped by what they decide, rather
              than a stacked list with a paragraph under each. The old shape
              took most of a screen for seven boxes; this holds seventeen in
              less room, and grouping is what makes seventeen legible at all.
              The hint moves to the title attribute - it is a reminder, not
              something to read seventeen times. --%>
        <form id="display-settings-form" phx-change="save_display">
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

      <%!-- The results site's hall display: a full-screen page for a TV or
            projector in the playing hall. Preferences for that screen only -
            it shows nothing the card above keeps off the public page.
            Saved with the button rather than as it is typed, because every
            save enqueues a publish. --%>
      <div class="card" id="hall-display-card">
        <h2>{gettext("Hall display")}</h2>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "A full-screen page on the results site for a TV or projector in the playing hall. It cycles through the round's pairings, a list to find your board by name, the results, the standings and your announcement - and shows only what spectators can already see."
          )}
        </p>

        <div :if={PublicLink.public?(@tournament)} class="set-field solo">
          <span class="set-label">{gettext("Its address")}</span>
          <p style="margin: 6px 0 0">
            <code id="hall-display-url">{PublicLink.url(@tournament, :hall)}</code>
          </p>
          <div class="actions" style="margin-top: 6px">
            <a
              id="hall-display-open"
              class="pe-btn"
              href={PublicLink.url(@tournament, :hall)}
              target="_blank"
              rel="noopener"
            >
              {gettext("Open the hall display")}
            </a>
          </div>
        </div>

        <p :if={not PublicLink.public?(@tournament)} class="hint">
          {gettext("Its address appears here once this tournament is published.")}
        </p>

        <.form for={@hall_form} id="hall-display-form" class="hall-form" phx-submit="save_hall">
          <div class="display-group-head">
            <strong>{gettext("What it cycles through")}</strong>
          </div>
          <div class="hall-views">
            <.input field={@hall_form[:pairings]} type="checkbox" label={gettext("Pairings")} />
            <.input
              field={@hall_form[:names]}
              type="checkbox"
              label={gettext("Find your board")}
            />
            <.input field={@hall_form[:results]} type="checkbox" label={gettext("Results")} />
            <.input field={@hall_form[:standings]} type="checkbox" label={gettext("Standings")} />
          </div>

          <div class="hall-numbers">
            <.input
              field={@hall_form[:page_seconds]}
              type="number"
              label={gettext("Seconds per page")}
              min={hall_min(:page_seconds)}
              max={hall_max(:page_seconds)}
              step="1"
              inputmode="numeric"
            />
            <.input
              field={@hall_form[:standings_top]}
              type="number"
              label={gettext("Standings: how many places")}
              min={hall_min(:standings_top)}
              max={hall_max(:standings_top)}
              step="1"
              inputmode="numeric"
            />
          </div>

          <.input
            field={@hall_form[:hold_new_round]}
            type="checkbox"
            label={gettext("Hold on the pairings until the first result of a new round is in")}
          />

          <.input
            field={@hall_form[:announcement]}
            type="textarea"
            label={gettext("Announcement")}
            rows="3"
          />
          <p class="hint hall-hint">
            {gettext(
              "Shown on the hall screen after the next publish. Up to %{max} characters; leave empty for none.",
              max: HallDisplay.max_announcement()
            )}
          </p>

          <div class="actions">
            <button type="submit" id="hall-display-save" class="pe-btn primary">
              {gettext("Save")}
            </button>
          </div>
        </.form>
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

        <p
          :if={not PublicLink.public?(@tournament) and not PublicLink.pending?(@tournament)}
          class="hint"
          style="color: var(--danger)"
        >
          {gettext(
            "This tournament is not published, and the form lives there - so opening it here has no effect until you publish."
          )}
        </p>

        <p :if={PublicLink.pending?(@tournament)} class="hint">
          {gettext(
            "The form opens on the results site once the first copy of this tournament has arrived there."
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

      <div :if={PublicLink.public?(@tournament) or Publishing.on_site?(@tournament)} class="card">
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
              down, and one switched off still does. In public mode a key
              alone is not enough: the site mints the address and the key
              together, and until a copy has arrived there is nothing there
              to withdraw (`Publishing.on_site?/1`; identical to the key in
              operator mode). --%>
        <div :if={Publishing.on_site?(@tournament)} style="margin-top: 14px">
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

      <PublicConsent.consent_dialog consent={@consent} />

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SettingSlider">
        // "On the results site" and "Automatically" (`setting_slider/1`) - the
        // Pairings page's ".PublishLevel" keyboard model: one tab stop, the
        // chosen one; the arrow keys, Home and End move focus between the
        // stops without choosing one, because every stop publishes or
        // withdraws something the moment it is chosen. Space or Enter
        // chooses (the stops are buttons), confirm included.
        const step = (key, index, count) => {
          switch (key) {
            case "ArrowRight":
            case "ArrowDown": return (index + 1) % count;
            case "ArrowLeft":
            case "ArrowUp": return (index - 1 + count) % count;
            case "Home": return 0;
            case "End": return count - 1;
            default: return null;
          }
        };

        export default {
          mounted() {
            this.onKeydown = (e) => {
              if (e.altKey || e.ctrlKey || e.metaKey) return;
              const stops = Array.from(this.el.querySelectorAll("[role=radio]"));
              const index = stops.indexOf(document.activeElement);
              if (index < 0) return;
              const next = step(e.key, index, stops.length);
              if (next === null) return;
              e.preventDefault();
              stops.forEach((stop, i) => { stop.tabIndex = i === next ? 0 : -1; });
              stops[next].focus();
            };
            this.el.addEventListener("keydown", this.onKeydown);
          },
          destroyed() {
            this.el.removeEventListener("keydown", this.onKeydown);
          }
        }
      </script>
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
