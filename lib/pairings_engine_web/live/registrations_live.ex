defmodule PairingsEngineWeb.RegistrationsLive do
  @moduledoc """
  Entries from the results site, and the arbiter's decision on each
  (`/t/:id/registrations`).

  The arbiter's half of a deliberately one-way arrangement: OpenResults
  accepts submissions from a public form and holds them, this page pulls
  that queue, and nothing becomes a player until somebody presses Accept.
  `PairingsEngine.Registrations` has the reasoning; this file is the screen.

  Three things about the screen itself.

  **The pull is a button, not a timer.** Publishing drains on a timer
  because nobody is waiting for it. An entry list is the opposite: the
  arbiter opens this page because they want to know what has come in, and a
  background poll that had already fetched would leave them unable to tell
  "nothing new" from "not checked since Tuesday". So the button says when it
  last ran and what it found.

  **A failure is a sentence.** Every error out of the context is already in
  words, and this page prints them as-is. Nothing here renders a struct or
  crashes: the arbiter is standing in a hall with bad wifi, which is the
  ordinary case rather than the exceptional one.

  **Decided entries stay on the page.** A discarded entry is not deleted -
  it must not come back at the next pull, and the arbiter may still need the
  email address to tell somebody the field is full. That email is shown
  here, on an authenticated page, and nowhere else in the application.
  """

  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{Publishing, Registrations, Tournaments}
  alias PairingsEngine.Registrations.Registration
  alias PairingsEngineWeb.RegistrationQueue

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
       page_title: "#{tournament.name} · Entries",
       configured?: Publishing.configured?(),
       last_pull: nil,
       error: nil,
       note: nil
     )
     |> load_entries()}
  end

  @impl true
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
        {:noreply, socket |> assign(tournament: tournament) |> load_entries()}
    end
  end

  @impl true
  def handle_event("pull", _params, socket) do
    case Registrations.pull(socket.assigns.tournament) do
      {:ok, %{new: new, total: total}} ->
        {:noreply,
         socket
         |> assign(
           error: nil,
           note: pull_note(new, total),
           last_pull: DateTime.utc_now(),
           queue_error: nil,
           queue_note: nil
         )
         |> load_entries()}

      {:error, message} ->
        # Straight through, because the context already phrased it for a
        # human. Wrapping it in "an error occurred:" would only push the
        # actionable half further from the eye.
        {:noreply, assign(socket, error: message, note: nil)}
    end
  end

  # Accept and Discard live in `PairingsEngineWeb.RegistrationQueue`, shared
  # with the Players page's queue so both screens create exactly what they
  # show.
  def handle_event(event, params, socket) when event in ["accept", "discard"] do
    {:noreply, socket} = RegistrationQueue.handle_event(event, params, socket)
    {:noreply, socket |> assign(error: nil, note: nil) |> load_entries()}
  end

  def handle_event("restore", %{"id" => id}, socket) do
    with_entry(socket, id, fn registration ->
      case Registrations.restore(registration) do
        {:ok, restored} ->
          {:noreply,
           socket
           |> assign(error: nil, note: "#{Registration.name(restored)} is waiting again.")
           |> load_entries()}

        {:error, message} ->
          {:noreply,
           assign(socket, error: "Could not restore this entry: #{message}.", note: nil)}
      end
    end)
  end

  # The id comes off a button in the client's DOM, so it is scoped to this
  # tournament on the way in rather than trusted - `Registrations.get/2` is
  # the only door, exactly as `Tournaments.get_player/2` is for a player.
  defp with_entry(socket, id, fun) do
    case Registrations.get(socket.assigns.tournament.id, id) do
      nil ->
        {:noreply, assign(socket, error: "That entry is no longer here.", note: nil)}

      registration ->
        fun.(registration)
    end
  end

  defp load_entries(socket) do
    socket
    |> RegistrationQueue.assign_queue()
    |> assign(decided: Registrations.decided(socket.assigns.tournament.id))
  end

  defp pull_note(0, 0), do: "Nothing has been submitted for this tournament yet."
  defp pull_note(0, total), do: "Nothing new. All #{total} entries have already been dealt with."
  defp pull_note(1, _total), do: "1 new entry."
  defp pull_note(new, _total), do: "#{new} new entries."

  defp received_label(at), do: RegistrationQueue.received_label(at)

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
      active="players"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">{gettext("Entries from the results site")}</p>
        </div>
      </div>

      <div :if={not @tournament.publish_to_openresults} class="card empty">
        <p>
          <strong>{gettext("This tournament is not published to the results site.")}</strong>
        </p>
        <p class="hint">
          {gettext(
            "The public entry form lives on that site, so there is nothing to collect until this tournament is published there. Turn it on in Settings."
          )}
        </p>
        <div class="actions">
          <.link class="pe-btn" navigate={~p"/t/#{@tournament.id}/settings"}>
            {gettext("Open Settings")}
          </.link>
        </div>
      </div>

      <div :if={@tournament.publish_to_openresults} class="card">
        <h2>{gettext("Check for new entries")}</h2>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "The results site holds what its public form collected. It cannot add anyone to this tournament - it only keeps the requests until you fetch them. Nobody below is a player yet."
          )}
        </p>

        <p :if={not @configured?} class="error-note">
          {gettext("No results site is set up on this machine yet - see Connections.")}
        </p>

        <div class="actions" style="align-items: center; gap: 10px">
          <button type="button" class="pe-btn primary" phx-click="pull" disabled={not @configured?}>
            {gettext("Fetch entries")}
          </button>
          <span :if={@last_pull} class="hint">
            {gettext("Last checked")} {received_label(@last_pull)}
          </span>
        </div>

        <p :if={@error} class="error-note" role="alert">{@error}</p>
        <p :if={@note} class="ok-note">{@note}</p>
      </div>

      <div :if={@tournament.publish_to_openresults} class="card">
        <h2>{gettext("Waiting for a decision")} ({length(@queue)})</h2>

        <p :if={@queue == []} class="hint" style="margin-bottom: 0">
          {gettext("Nothing is waiting. Fetch above to check the results site again.")}
        </p>

        <p :if={@queue_error} class="error-note" role="alert">{@queue_error}</p>
        <p :if={@queue_note} class="ok-note">{@queue_note}</p>

        <RegistrationQueue.pending_list queue={@queue} />

        <p :if={@queue != []} class="hint" style="margin-bottom: 0">
          {gettext(
            "Accepting adds the player marked not yet arrived, exactly as the form on this machine does. Filling in a web form is an intention to play, not an arrival - clear the flag on the Players page when they turn up."
          )}
        </p>
      </div>

      <div :if={@tournament.publish_to_openresults and @decided != []} class="card">
        <h2>{gettext("Already decided")} ({length(@decided)})</h2>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "Kept so that a fetch cannot bring a turned-down entry back, and so you can still reach somebody you had to turn away."
          )}
        </p>

        <div :for={registration <- @decided} class="set-field solo" style="margin-top: 12px">
          <span class="set-label">
            {Registration.name(registration)}
            <span class="hint">
              · {if registration.status == "accepted",
                do: gettext("accepted"),
                else: gettext("discarded")}
            </span>
          </span>

          <p :if={Registration.email(registration)} class="hint" style="margin: 2px 0 0">
            {Registration.email(registration)}
          </p>

          <p :if={registration.player} class="hint" style="margin: 2px 0 0">
            <.link navigate={~p"/t/#{@tournament.id}/players"}>
              {gettext("On the entry list as")} {registration.player.name}
            </.link>
          </p>

          <div :if={registration.status == "discarded"} class="actions" style="margin-top: 6px">
            <button
              type="button"
              class="pe-btn"
              phx-click="restore"
              phx-value-id={registration.id}
            >
              {gettext("Put back")}
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
