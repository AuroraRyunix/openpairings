defmodule PairingsEngineWeb.PublicRegisterLive do
  @moduledoc """
  Public (no login required) self-registration form — reachable at
  `/p/:slug/register` where `:slug` is the tournament's unguessable
  `public_slug`, the same one the read-only public pages use (see
  docs/public-pages.md).

  The one public page that WRITES. Three things follow from that.

  It is off unless deliberately opened. `registration_open` defaults to
  false and is toggled only by `Tournaments.set_registration_open/2`, never
  by an ordinary settings save, so no tournament starts accepting strangers
  by accident.

  Everyone who registers lands **absent**. Filling in a web form announces
  an intention to play; it is not the same as being in the room. The
  arbiter clears the flag on the Players page when the player actually
  turns up. Backwards, this would pair a no-show and hand their opponent a
  forfeit win.

  Closing the form takes effect immediately, everywhere. The page
  subscribes to the tournament topic, so an already-open form flips to the
  closed notice the moment the arbiter shuts it, and
  `Tournaments.register_public_player/2` re-checks anyway — a form rendered
  a minute ago cannot smuggle an entry in afterwards.
  """

  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.Components.PublicTournamentMeta

  alias PairingsEngine.{Fide, RateLimit, Tournaments}
  alias PairingsEngineWeb.ClientIp

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    # Deliberately the read-only lookup: a CLOSED form should say so on the
    # tournament's own page rather than 404, which is indistinguishable
    # from a mistyped link.
    tournament =
      Tournaments.get_tournament_by_public_slug(slug) ||
        raise Ecto.NoResultsError, queryable: Tournaments.Tournament

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     socket
     |> assign(
       tournament: tournament,
       slug: slug,
       client_ip: ClientIp.from_socket(socket),
       page_title: "#{tournament.name} · Register",
       query: "",
       results: [],
       picked: nil,
       registered: nil,
       error: nil
     )}
  end

  @impl true
  def handle_info({:tournament_changed, _id, _hint}, socket) do
    case Tournaments.get_tournament_by_public_slug(socket.assigns.slug) do
      nil -> {:noreply, assign(socket, tournament: nil)}
      tournament -> {:noreply, assign(socket, tournament: tournament)}
    end
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, assign(socket, query: q, results: Fide.search(q), error: nil)}
  end

  def handle_event("pick", %{"fide-id" => fide_id}, socket) do
    picked = Enum.find(socket.assigns.results, &(to_string(&1.fide_id) == fide_id))
    {:noreply, assign(socket, picked: picked, results: [], query: "", error: nil)}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, assign(socket, picked: nil, query: "", results: [], error: nil)}
  end

  # Unrated players and anyone not on the FIDE list still have to be able
  # to enter, so a typed name with no match is accepted exactly as typed.
  def handle_event("submit", _params, socket) do
    if registration_allowed?(socket) do
      do_submit(socket)
    else
      {:noreply,
       assign(socket,
         error: "Too many sign-ups from here just now. Please try again in a few minutes."
       )}
    end
  end

  # Keyed by client address only. There is no per-person key available — a
  # name is not an identity and the whole point of the page is that the
  # registrant has no account — so the address is all there is to count.
  defp registration_allowed?(socket) do
    case socket.assigns.client_ip do
      nil -> true
      ip -> RateLimit.allow?(:public_register, ip)
    end
  end

  defp record_registration(socket) do
    case socket.assigns.client_ip do
      nil -> :ok
      ip -> RateLimit.record(:public_register, ip)
    end
  end

  defp do_submit(socket) do
    attrs =
      case socket.assigns.picked do
        nil ->
          %{"name" => String.trim(socket.assigns.query)}

        fp ->
          %{
            "name" => fp.name,
            "fide_id" => fp.fide_id,
            "fide_rating" => fp.standard_rating,
            "title" => fp.title,
            "federation" => fp.federation,
            "birth_year" => fp.birth_year
          }
      end

    if attrs["name"] in [nil, ""] do
      {:noreply, assign(socket, error: "Please enter your name.")}
    else
      case Tournaments.register_public_player(socket.assigns.slug, attrs) do
        {:ok, player} ->
          # Counted only on a real entry: a blank name or a rejected
          # duplicate must not burn the venue's allowance.
          record_registration(socket)
          {:noreply, assign(socket, registered: player, picked: nil, query: "", error: nil)}

        {:error, :closed} ->
          {:noreply, assign(socket, error: "Registration has just closed for this tournament.")}

        {:error, :duplicate_fide_id} ->
          {:noreply, assign(socket, error: "Somebody with that FIDE ID is already registered.")}

        {:error, _changeset} ->
          {:noreply, assign(socket, error: "Sorry, that could not be saved. Please try again.")}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.public flash={@flash}>
      <div :if={@tournament} class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          
          <p class="subtitle" style="margin: 0">Registration</p>
        </div>
      </div>
       <.public_tournament_meta :if={@tournament} tournament={@tournament} />
      <div :if={is_nil(@tournament)} class="card empty">
        <p><strong>This tournament is no longer available.</strong></p>
      </div>
      
      <div :if={@tournament && !@tournament.registration_open} class="card empty">
        <p><strong>Registration is closed.</strong></p>
        
        <p>
          The organiser has closed sign-ups for this tournament. If you think that's a
          mistake, contact the arbiter directly.
        </p>
      </div>
      
      <div :if={@registered} class="card">
        <h2>You're registered</h2>
        
        <p>
          <strong>{@registered.name}</strong> has been added to the entry list.
        </p>
        
        <p>
          You are marked <strong>not yet arrived</strong>. Report to the arbiter when you
          get to the venue and they'll confirm you — you won't be paired until they do.
        </p>
      </div>
      
      <div :if={@tournament && @tournament.registration_open && is_nil(@registered)} class="card">
        <h2>Add your name</h2>
        
        <p :if={@error} class="pe-error" role="alert">{@error}</p>
        
        <div :if={@picked} class="picked-player">
          <p style="margin: 0 0 8px">
            <strong>{@picked.name}</strong> <span :if={@picked.title != ""}>{@picked.title}</span>
            <span :if={@picked.standard_rating}>· {@picked.standard_rating}</span>
            <span :if={@picked.federation != ""}>· {@picked.federation}</span>
          </p>
           <button type="button" class="pe-btn" phx-click="clear">Not me — search again</button>
        </div>
        
        <div :if={is_nil(@picked)}>
          <label for="reg-name">Your name</label>
          <input
            id="reg-name"
            type="text"
            name="q"
            value={@query}
            class="pe-input"
            style="width: 100%; max-width: 420px"
            autocomplete="off"
            phx-change="search"
            phx-debounce="250"
            placeholder="Start typing your last name… e.g. Carlsen"
          />
          <p class="subtitle" style="margin: 4px 0 0">
            Pick yourself from the FIDE list below. Not on it? Just type your name and
            press Register.
          </p>
          
          <ul :if={@results != []} class="fide-results" style="margin: 8px 0 0; padding: 0">
            <li :for={fp <- Enum.take(@results, 8)} style="list-style: none; margin: 4px 0">
              <button
                type="button"
                class="pe-btn"
                phx-click="pick"
                phx-value-fide-id={fp.fide_id}
              >
                {fp.name} <span :if={fp.standard_rating}>· {fp.standard_rating}</span>
                <span :if={fp.federation != ""}>· {fp.federation}</span>
              </button>
            </li>
          </ul>
        </div>
        
        <div class="actions" style="margin-top: 12px">
          <button type="button" class="pe-btn primary" phx-click="submit">Register</button>
        </div>
      </div>
    </Layouts.public>
    """
  end
end
