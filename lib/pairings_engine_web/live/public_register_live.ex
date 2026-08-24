defmodule PairingsEngineWeb.PublicRegisterLive do
  @moduledoc """
  Public (no login required) self-registration form - reachable at
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
  `Tournaments.register_public_player/2` re-checks anyway - a form rendered
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
       birth_year: "",
       federation: "",
       results: [],
       picked: nil,
       bye_rounds: [],
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
  def handle_event("search", params, socket) do
    q = params["q"] || ""

    # The name, birth year and country fields all live in the one form, so
    # every keystroke in any of them re-delivers all three - capture them
    # together rather than adding a second form, so nothing typed into
    # birth year/country is lost if the person fills those in first.
    {:noreply,
     assign(socket,
       query: q,
       birth_year: params["birth_year"] || "",
       federation: params["federation"] || "",
       results: Fide.search(q),
       error: nil
     )}
  end

  def handle_event("pick", %{"fide-id" => fide_id}, socket) do
    picked = Enum.find(socket.assigns.results, &(to_string(&1.fide_id) == fide_id))
    # A FIDE match supplies its own birth year/federation, so whatever was
    # typed into the manual-entry fields before picking is no longer needed.
    {:noreply,
     assign(socket,
       picked: picked,
       results: [],
       query: "",
       birth_year: "",
       federation: "",
       error: nil
     )}
  end

  # Clicking outside the field puts the overlay away. The typed query is
  # kept: the panel is a suggestion list, and closing it must not throw away
  # what someone has written, since a player who is not on the FIDE list
  # fills the name in by hand and never picks from it at all.
  # Byes are toggled one at a time rather than read off the search form.
  # That form is `phx-change="search"`, so a checkbox inside it would fire a
  # FIDE lookup on every tick, and the round the player just chose would
  # have to survive a code path that exists to rebuild the results list.
  def handle_event("toggle_bye", %{"round" => round}, socket) do
    case Integer.parse(round) do
      {n, ""} when n >= 1 ->
        rounds = socket.assigns.bye_rounds

        rounds =
          if n in rounds, do: List.delete(rounds, n), else: Enum.sort([n | rounds])

        {:noreply, assign(socket, bye_rounds: rounds)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("close_results", _params, socket) do
    {:noreply, assign(socket, results: [])}
  end

  def handle_event("clear", _params, socket) do
    {:noreply,
     assign(socket,
       picked: nil,
       query: "",
       birth_year: "",
       federation: "",
       results: [],
       error: nil
     )}
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

  # Keyed by client address only. There is no per-person key available - a
  # name is not an identity and the whole point of the page is that the
  # registrant has no account - so the address is all there is to count.
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
          %{
            "name" => String.trim(socket.assigns.query),
            "birth_year" => String.trim(socket.assigns.birth_year || ""),
            "federation" => socket.assigns.federation |> to_string() |> String.trim()
          }

        fp ->
          standard = socket.assigns.tournament && socket.assigns.tournament.standard

          %{
            "name" => fp.name,
            "fide_id" => fp.fide_id,
            "fide_rating" => Fide.rating_for_tempo(fp, standard),
            "title" => fp.title,
            "federation" => fp.federation,
            "birth_year" => fp.birth_year
          }
      end

    attrs = Map.put(attrs, "absent_rounds", Enum.join(socket.assigns.bye_rounds, ","))

    cond do
      attrs["name"] in [nil, ""] ->
        {:noreply, assign(socket, error: "Please enter your name.")}

      # Not picked from the FIDE list, so there's no other source for these
      # two - without at least a birth year and federation the arbiter has
      # no way to tell two "J. Smith"s apart on the entry list.
      is_nil(socket.assigns.picked) and
          (attrs["birth_year"] == "" or attrs["federation"] == "") ->
        {:noreply,
         assign(socket,
           error: "Not on the FIDE list? Please also fill in your birth year and federation."
         )}

      is_nil(socket.assigns.picked) and not valid_birth_year?(attrs["birth_year"]) ->
        {:noreply, assign(socket, error: "Please enter a birth year as 4 digits, e.g. 1990.")}

      true ->
        do_register(socket, attrs)
    end
  end

  defp valid_birth_year?(value) do
    case Integer.parse(value) do
      {year, ""} -> year in 1900..Date.utc_today().year
      _ -> false
    end
  end

  defp do_register(socket, attrs) do
    case Tournaments.register_public_player(socket.assigns.slug, attrs) do
      {:ok, player} ->
        # Counted only on a real entry: a blank name or a rejected
        # duplicate must not burn the venue's allowance.
        record_registration(socket)

        {:noreply,
         assign(socket,
           registered: player,
           picked: nil,
           bye_rounds: [],
           query: "",
           birth_year: "",
           federation: "",
           error: nil
         )}

      {:error, :closed} ->
        {:noreply, assign(socket, error: "Registration has just closed for this tournament.")}

      {:error, :duplicate_fide_id} ->
        {:noreply, assign(socket, error: "Somebody with that FIDE ID is already registered.")}

      {:error, _changeset} ->
        {:noreply, assign(socket, error: "Sorry, that could not be saved. Please try again.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- The one public page that opts into the restart banner. The
          read-only pages deliberately do not: they are embedded in club
          websites, where a countdown from somebody else's server reads as
          that site being broken, and a spectator has no work to lose. A
          half-typed entry here is exactly the work a restart costs. --%>
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
          get to the venue and they'll confirm you - you won't be paired until they do.
        </p>

        <p :if={@registered.absent_rounds not in [nil, ""]}>
          You asked to sit out <strong>round {@registered.absent_rounds}</strong>, scoring {bye_award(
            @tournament
          )}. Confirming your arrival does not cancel that -
          the rounds you picked stay set.
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
          <button type="button" class="pe-btn" phx-click="clear">Not me - search again</button>
        </div>

        <div :if={is_nil(@picked)}>
          <label for="reg-name">Your name</label>
          <%!-- The input has to live inside a form: LiveView only delivers
                phx-change from a form context, so a bare input silently
                never fires and the FIDE dropdown never appears. PlayersLive's
                identical search works because it sits inside its own
                add-player form. phx-submit here lets Enter register too. --%>
          <form id="reg-search" phx-change="search" phx-submit="submit">
            <%!-- The matches hang UNDER the input as an overlay rather than
                  pushing the rest of the form down the page. Typing a name
                  used to reflow everything below it on every keystroke,
                  which moved the birth-year and federation fields out from
                  under the cursor mid-form. --%>
            <%!-- Deliberately NOT marked up as an ARIA combobox/listbox.
                  Those roles promise arrow-key navigation and an
                  aria-activedescendant that follows it, and none of that is
                  wired here - a screen reader would announce a listbox whose
                  arrows do nothing, which is worse than plain controls.
                  These are real <button>s in document order, so Tab reaches
                  them and Enter activates them. The live region below says
                  how many appeared, since the panel opening is otherwise
                  silent. ArbiterCombo makes the same call. --%>
            <div class="reg-name-wrap" phx-click-away="close_results">
              <input
                id="reg-name"
                type="text"
                name="q"
                value={@query}
                class="pe-input"
                autocomplete="off"
                phx-debounce="250"
                placeholder="Start typing your last name… e.g. Carlsen"
              />

              <div :if={@results != []} id="reg-results" class="search-results">
                <button
                  :for={fp <- Enum.take(@results, 8)}
                  type="button"
                  phx-click="pick"
                  phx-value-fide-id={fp.fide_id}
                >
                  <span>{if fp.title != "", do: "#{fp.title} "}{fp.name}</span>
                  <span class="meta">{result_meta(fp)}</span>
                </button>
              </div>
            </div>

            <p class="sr-only" aria-live="polite">
              {match_announcement(@results)}
            </p>

            <div style="display: flex; gap: 12px; margin-top: 10px; max-width: 420px">
              <div style="flex: 1">
                <label for="reg-birth-year">Birth year</label>
                <input
                  id="reg-birth-year"
                  type="text"
                  inputmode="numeric"
                  name="birth_year"
                  value={@birth_year}
                  class="pe-input"
                  style="width: 100%"
                  autocomplete="off"
                  phx-debounce="250"
                  placeholder="1990"
                />
              </div>

              <div style="flex: 1">
                <label for="reg-federation">Federation</label>
                <input
                  id="reg-federation"
                  type="text"
                  name="federation"
                  value={@federation}
                  class="pe-input"
                  style="width: 100%"
                  autocomplete="off"
                  phx-debounce="250"
                  placeholder="BEL"
                />
              </div>
            </div>
            <p class="subtitle" style="margin: 4px 0 0">
              Pick yourself from the list that appears as you type and these two fields fill
              themselves in. Not on the FIDE list? Then birth year and federation are required,
              so the arbiter can tell you apart from anyone with the same name.
            </p>
          </form>
        </div>

        <div :if={@tournament.rounds_count > 0} class="reg-byes">
          <h3>Rounds you cannot play</h3>

          <p class="subtitle">
            Tick any round you already know you will miss. Leave them all clear if you can
            play the whole tournament - the arbiter can change this later either way.
          </p>

          <div class="reg-bye-grid">
            <label
              :for={n <- 1..@tournament.rounds_count}
              class={["reg-bye", n in @bye_rounds && "on"]}
            >
              <input
                type="checkbox"
                checked={n in @bye_rounds}
                phx-click="toggle_bye"
                phx-value-round={n}
              />
              <span>Round {n}</span>
            </label>
          </div>

          <%!-- Read from the tournament rather than stated as a constant.
                An arbiter who sets requested byes to half a point has changed
                what this sentence must say, and a registrant deciding whether
                to ask for one is exactly who needs the true answer. --%>
          <p class="subtitle" style="margin-top: 8px">
            A round you sit out scores <strong>{bye_award(@tournament)}</strong> here.
          </p>
        </div>

        <div class="actions" style="margin-top: 12px">
          <button type="button" class="pe-btn primary" phx-click="submit">Register</button>
        </div>
      </div>
    </Layouts.public>
    """
  end

  # What a bye pays, in words rather than as a bare float. "0.5" on a form
  # aimed at players is a worse answer than "half a point", and "0.0" reads
  # like a bug rather than a policy.
  #
  # Read from the tournament, never assumed. FIDE's default is zero and most
  # opens change it, so the only honest sentence is the one this tournament
  # can actually pay - and it has to include the ALLOWANCE, because "half a
  # point" and "half a point for your first two" are different offers to
  # somebody deciding how many rounds to skip.
  defp bye_award(tournament) do
    value =
      case tournament.abs_value || tournament.points_loss do
        v when v == 0.0 -> "no points"
        v when v == 0.5 -> "half a point"
        v when v == 1.0 -> "a full point"
        v -> "#{:erlang.float_to_binary(v / 1, decimals: 1)} points"
      end

    value <> allowance(tournament)
  end

  defp allowance(%{abs_nbfois: n, abs_jusque: r}) do
    case {n, r} do
      {nil, nil} -> ""
      {n, nil} -> ", for your first #{n}"
      {nil, r} -> ", up to round #{r}"
      {n, r} -> ", for your first #{n} and up to round #{r}"
    end
  end

  # The panel opening is a purely visual event, so it is announced. Empty
  # string when there is nothing to say - an aria-live region that keeps
  # repeating "0 matches" while somebody types their name is noise.
  defp match_announcement([]), do: ""
  defp match_announcement([_one]), do: "1 matching player, listed below the field."

  defp match_announcement(results),
    do: "#{min(length(results), 8)} matching players, listed below the field."

  # Federation alone cannot separate namesakes, so a row carries birth year
  # and rating too - the same fields ArbiterCombo shows, for the same reason.
  defp result_meta(fp) do
    [
      fp.federation != "" && fp.federation,
      fp.birth_year && "b. #{fp.birth_year}",
      fp.standard_rating && fp.standard_rating > 0 && "#{fp.standard_rating}"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end
end
