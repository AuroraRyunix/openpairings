defmodule PairingsEngineWeb.RegistrationQueue do
  @moduledoc """
  The entries waiting for a decision, as the Players page and the
  Registrations page both show them - and the two buttons on each.

  One module for both pages rather than a copy per page, because the rule
  that matters most here is that what the arbiter READS is what Accept
  CREATES: every entry is shown through `Registrations.Review.proposal/3`,
  the same function `Registrations.accept/2` builds the player from. Two
  renderings would be two chances for those to drift apart.

  Not a LiveComponent. The queue re-renders when the tournament changes,
  which both pages already listen for, and the two events are delegated
  from each page's own `handle_event/3` - see `handle_event/3` here. A
  component with its own process state would be a second copy of the list
  to keep fresh for no gain.

  ## What the arbiter sees on each entry

    * the player the entry would become, prefilled from the FIDE list and -
      with the Belgian lookup switched on - the KBSB/FRBE list, with a note
      wherever a list changed what the person typed;
    * **possible duplicates**: an existing player or another waiting entry
      with the same FIDE ID, national ID or name, or another waiting entry
      from the same email address. Only an existing player's FIDE ID blocks
      accepting; the rest is for the arbiter to judge;
    * the email address - this page is behind a login and it is the reason
      the field exists; it is shown nowhere else in the application.
  """
  use PairingsEngineWeb, :html

  alias PairingsEngine.{Audit, Features, Registrations, Tournaments}
  alias PairingsEngine.Registrations.{Registration, Review}

  # The same switch that governs the Players page's own KBSB autofill: an
  # arbiter with the Belgian pack off gets the FIDE list and stops there.
  @lookup_feature "bel_player_lookup"

  @events ~w(accept discard)

  @doc "The event names this module handles, for the pages to delegate."
  def events, do: @events

  @doc """
  Loads the queue into `socket.assigns.queue`, one item per waiting entry,
  with everything the screen shows worked out once.
  """
  def assign_queue(socket) do
    tournament = socket.assigns.tournament
    national? = Features.enabled?(socket.assigns.current_scope, @lookup_feature)

    pending = Registrations.pending(tournament.id)
    # Only looked up when there is something to compare against - the
    # Players page loads this on every change to the tournament, and an
    # empty queue should cost one query.
    players = if pending == [], do: [], else: Tournaments.list_players(tournament.id)

    items =
      Enum.map(pending, fn registration ->
        %{
          registration: registration,
          proposal: Review.proposal(registration, tournament, national_list: national?),
          duplicates: Review.duplicates(registration, players, pending),
          impossible: impossible_rounds(registration, tournament)
        }
      end)

    assign(socket,
      queue: items,
      queue_national?: national?,
      # Kept across reloads - a reload triggered by another screen must not
      # wipe the sentence the arbiter's own click just produced.
      queue_error: socket.assigns[:queue_error],
      queue_note: socket.assigns[:queue_note]
    )
  end

  @doc """
  Accept or discard, for whichever page the button was on. Returns
  `{:noreply, socket}` with the queue reloaded and a sentence in
  `:queue_note` or `:queue_error`.
  """
  def handle_event("accept", %{"id" => id}, socket) do
    with_entry(socket, id, fn registration ->
      case Registrations.accept(registration, national_list: socket.assigns.queue_national?) do
        {:ok, player} ->
          Audit.log(
            socket.assigns.tournament.id,
            socket.assigns.current_scope,
            "registration.accepted",
            %{player_name: player.name, player_id: player.id}
          )

          {:noreply,
           socket
           |> assign(
             queue_error: nil,
             queue_note:
               gettext("Added %{name} to the entry list, marked not yet arrived.",
                 name: player.name
               ) <> bye_note(registration)
           )
           |> assign_queue()}

        {:error, message} ->
          {:noreply,
           assign(socket,
             queue_error: gettext("Could not accept this entry: %{reason}.", reason: message),
             queue_note: nil
           )}
      end
    end)
  end

  def handle_event("discard", %{"id" => id}, socket) do
    with_entry(socket, id, fn registration ->
      case Registrations.discard(registration) do
        {:ok, discarded} ->
          Audit.log(
            socket.assigns.tournament.id,
            socket.assigns.current_scope,
            "registration.discarded",
            %{player_name: Registration.name(discarded)}
          )

          {:noreply,
           socket
           |> assign(
             queue_error: nil,
             queue_note:
               gettext("Turned down %{name}. No player was created.",
                 name: Registration.name(discarded)
               )
           )
           |> assign_queue()}

        {:error, message} ->
          {:noreply,
           assign(socket,
             queue_error: gettext("Could not discard this entry: %{reason}.", reason: message),
             queue_note: nil
           )}
      end
    end)
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The id comes off a button in the client's DOM, so it is scoped to this
  # tournament on the way in rather than trusted - `Registrations.get/2` is
  # the only door, exactly as `Tournaments.get_player/2` is for a player.
  defp with_entry(socket, id, fun) do
    case Registrations.get(socket.assigns.tournament.id, id) do
      nil ->
        {:noreply,
         assign(socket, queue_error: gettext("That entry is no longer here."), queue_note: nil)}

      registration ->
        fun.(registration)
    end
  end

  # Said at the moment of accepting rather than left on the entry, because
  # this is the one thing about an accepted entry an arbiter may want to
  # undo, and the rounds are no longer on screen afterwards.
  defp bye_note(registration) do
    case Registrations.requested_rounds(registration) do
      [] ->
        ""

      rounds ->
        " " <>
          gettext("They asked to sit out round %{rounds}.", rounds: Enum.join(rounds, ", "))
    end
  end

  # Rounds asked for that this tournament does not have. Shown rather than
  # quietly dropped: "rounds 3 and 9" in a seven-round event means the
  # person misread something, and the arbiter should see that before the
  # request silently becomes "round 3".
  defp impossible_rounds(registration, tournament) do
    Enum.reject(
      Registrations.requested_rounds(registration),
      &(&1 >= 1 and &1 <= (tournament.rounds_count || 0))
    )
  end

  ## ---------- the list ----------

  @doc """
  The waiting entries, each with its decision buttons.

  `compact` is the Players page's version: the same facts and the same
  buttons, less explanation around them - the Registrations page carries
  that.
  """
  attr :queue, :list, required: true
  attr :id, :string, default: "registration-queue"
  attr :compact, :boolean, default: false

  def pending_list(assigns) do
    ~H"""
    <div id={@id} class="reg-queue">
      <div
        :for={item <- @queue}
        id={"registration-#{item.registration.id}"}
        class="set-field solo reg-entry"
      >
        <span class="set-label">
          {item.proposal.attrs["name"] || Registration.name(item.registration)}
          <span :if={item.proposal.attrs["title"]} class="badge muted">
            {item.proposal.attrs["title"]}
          </span>
        </span>

        <p :if={details(item.proposal.attrs) != ""} class="hint reg-line">
          {details(item.proposal.attrs)}
        </p>

        <p :if={Registration.email(item.registration)} class="hint reg-line">
          {Registration.email(item.registration)}
        </p>

        <p :for={note <- item.proposal.notes} class="hint reg-line reg-source">
          {note_text(note)}
        </p>

        <ul
          :if={item.duplicates != []}
          class="reg-duplicates"
          id={"duplicates-#{item.registration.id}"}
        >
          <li :for={hit <- item.duplicates} class={"reg-duplicate reg-duplicate-#{hit.reason}"}>
            {duplicate_text(hit)}
          </li>
        </ul>

        <p
          :if={Registrations.requested_rounds(item.registration) != []}
          class="hint reg-line"
        >
          {gettext("Asked to sit out round")} {Enum.join(
            Registrations.requested_rounds(item.registration),
            ", "
          )}
        </p>

        <%!-- A request this tournament cannot honour is called out rather
              than quietly trimmed on accept. --%>
        <p :if={item.impossible != []} class="error-note reg-line">
          {gettext("This tournament has no round")} {Enum.join(item.impossible, ", ")} - {gettext(
            "that part of the request will be dropped."
          )}
        </p>

        <p :if={not @compact} class="hint reg-line">
          {gettext("Submitted")} {received_label(item.registration.received_at)}
        </p>

        <div class="actions" style="margin-top: 8px; gap: 10px">
          <button
            type="button"
            id={"accept-registration-#{item.registration.id}"}
            class="pe-btn primary"
            phx-click="accept"
            phx-value-id={item.registration.id}
            phx-disable-with={gettext("Adding…")}
          >
            {gettext("Accept")}
          </button>
          <button
            type="button"
            id={"discard-registration-#{item.registration.id}"}
            class="pe-btn danger-link"
            phx-click="discard"
            phx-value-id={item.registration.id}
          >
            {gettext("Discard")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  # One line of what the player would be created with, minus the email -
  # that gets its own line, because it is the one field here that is
  # personal data and burying it in a comma-separated run would make it easy
  # to paste somewhere it must not go.
  defp details(attrs) do
    [
      attrs["fide_rating"] && Integer.to_string(attrs["fide_rating"]),
      attrs["federation"],
      attrs["club"],
      attrs["fide_id"] && "FIDE #{attrs["fide_id"]}",
      attrs["national_id"] && gettext("national ID %{id}", id: attrs["national_id"]),
      attrs["national_rating"] && attrs["national_rating"] > 0 &&
        gettext("national rating %{rating}", rating: attrs["national_rating"]),
      attrs["birth_year"] && "b. #{attrs["birth_year"]}"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp note_text({:fide_list, _name}),
    do: gettext("On this computer's FIDE list - rating, title and federation come from there.")

  defp note_text({:fide_not_listed, id}),
    do:
      gettext(
        "FIDE ID %{id} is not on this computer's FIDE list - check the number, or sync the list.",
        id: id
      )

  defp note_text({:fide_name_differs, name}),
    do:
      gettext(
        "The FIDE list has this FIDE ID as %{name} - check it is the same person before accepting.",
        name: name
      )

  defp note_text({:rating_from_list, list, typed}),
    do:
      gettext("Rating %{list} from the FIDE list; the entry said %{typed}.",
        list: list,
        typed: typed
      )

  defp note_text({:national_list, id}),
    do:
      gettext(
        "Found on the KBSB list as member %{id} - club and national rating come from there.",
        id: id
      )

  defp note_text({:national_not_listed, id}),
    do: gettext("National ID %{id} is not on this computer's KBSB list.", id: id)

  defp duplicate_text(%{kind: :player, name: name, reason: reason}),
    do: gettext("Already on the entry list? %{name} - %{why}", name: name, why: why(reason))

  defp duplicate_text(%{kind: :entry, name: name, reason: reason}),
    do: gettext("Also waiting: %{name} - %{why}", name: name, why: why(reason))

  defp why(:fide_id), do: gettext("same FIDE ID")
  defp why(:national_id), do: gettext("same national ID")
  defp why(:name), do: gettext("same name")
  defp why(:email), do: gettext("same email address")

  @doc false
  def received_label(nil), do: gettext("unknown")
  def received_label(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
end
