defmodule PairingsEngineWeb.SettingsBoardsLive do
  @moduledoc """
  Settings, Live boards (`/t/:id/settings/boards`): the connect codes for a
  hall box (`PairingsEngine.BoardLink`), what each box said the last time it
  called, whether the box may send moves to the results site, and the games
  the boards have reported.

  The box's permission for the results site is fetched by this machine
  (`PairingsEngine.BoardLink.RelayKeys`), so the card says where that stands
  in words and has two buttons: "Try again" after a refusal and "Replace".
  The words "relay key" are small print here on purpose - it is plumbing.
  Pasting one is offered only where the results site said it cannot hand one
  out.

  Anybody who may open the tournament may open the page; every button goes
  through `PairingsEngine.BoardLink`, which asks again who is pressing it and
  refuses on an archived or handed-off tournament.

  A secret is on screen exactly once: in `@fresh`, from the click that made
  it until the page is left or reloaded. It is not in the database to be
  shown twice.
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport

  alias PairingsEngine.{Audit, BoardLink, Mobile, TournamentGroups, Tournaments}
  alias PairingsEngine.BoardLink.RelayKeys
  alias PairingsEngineWeb.{BoardLan, BoardLinkAddress}

  # Often enough that "connected" on this page is not a memory.
  @tick_ms 15_000

  # A box polls every few seconds; one that has said nothing for this long
  # is not there.
  @present_s 60

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
      BoardLink.subscribe(tournament.id)
      Process.send_after(self(), :tick, @tick_ms)
    end

    {:ok,
     socket
     |> assign(
       tournament: tournament,
       page_title: "#{tournament.name} · Settings · Live boards",
       fresh: nil,
       relay_form: to_form(%{"key" => ""}, as: :relay)
     )
     |> load()}
  end

  defp load(socket) do
    tournament = socket.assigns.tournament
    games = BoardLink.summaries(tournament.id)

    assign(socket,
      links: BoardLink.list_links(tournament),
      account_links: BoardLink.account_links(tournament.id),
      group: TournamentGroups.membership(tournament.id),
      target: BoardLink.openresults_target(tournament),
      relay: RelayKeys.status(tournament),
      # A desktop copy's listener for boxes on the network. Asking is also
      # what makes it look again: a code made or withdrawn a moment ago has
      # opened or closed the port by the time this returns.
      lan: BoardLan.status(),
      game_count: map_size(games),
      rounds: Tournaments.list_rounds(tournament.id),
      now: DateTime.utc_now()
    )
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
        {:noreply, socket |> assign(tournament: tournament) |> load()}
    end
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, load(socket)}
  end

  # A code, a box - or the results site's answer about the box's permission,
  # which lands in the tournament's own row: read it again.
  def handle_info({:board_link, _id}, socket) do
    case Tournaments.get_authorized_tournament(
           socket.assigns.current_scope,
           socket.assigns.tournament.id
         ) do
      nil -> {:noreply, socket}
      tournament -> {:noreply, socket |> assign(tournament: tournament) |> load()}
    end
  end

  def handle_info({:board_game, _id, _game, :state}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("new_code", %{"scope" => scope} = params, socket)
      when scope in ~w(tournament group) do
    %{current_scope: user, tournament: tournament} = socket.assigns

    # "For a box on the network" is asked of the listener now, not read off
    # the page: the button was drawn a while ago, and a code with an address
    # nothing answers on is the one thing this page must not hand out.
    lan = if params["where"] == "lan", do: BoardLan.status()

    cond do
      lan && not BoardLan.usable?(lan) ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Boxes on the network cannot connect right now."))
         |> load()}

      true ->
        opts = if lan, do: [lan: lan.base_url], else: []

        result =
          if scope == "group",
            do: BoardLink.create_group_link(user, tournament, opts),
            else: BoardLink.create_link(user, tournament, opts)

        case result do
          {:ok, link, secret} ->
            {:noreply,
             socket
             |> assign(
               fresh: %{
                 id: link.id,
                 scope: scope,
                 where: if(lan, do: :lan, else: :here),
                 address: (lan && lan.base_url) || BoardLinkAddress.base_url(),
                 code: BoardLinkAddress.connect_code(secret, lan && lan.base_url),
                 name_code:
                   lan && lan.name_url && BoardLinkAddress.connect_code(secret, lan.name_url)
               }
             )
             |> load()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, refusal(reason))}
        end
    end
  end

  # "Let boards on this network connect", and the address and port it
  # answers on. A desktop copy only: the card is not drawn anywhere else,
  # and a click that arrives anyway is asked the same question again here,
  # because a `phx-click` is whatever the browser cares to send.
  def handle_event("lan_switch", _params, socket) do
    %{current_scope: user, tournament: tournament, lan: lan} = socket.assigns

    with true <- BoardLan.available?(),
         {:ok, tournament} <- writable(user, tournament),
         {:ok, status} <- BoardLan.switch(not lan.enabled?) do
      Audit.log(tournament.id, user, "boards.lan_switched", %{
        enabled: status.enabled?,
        address: status.address,
        port: status.port
      })

      {:noreply, load(socket)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, refusal(reason))}
      false -> {:noreply, socket}
    end
  end

  def handle_event("lan_choose", %{"lan" => %{"address" => address, "port" => port}}, socket) do
    %{current_scope: user, tournament: tournament} = socket.assigns

    with true <- BoardLan.available?(),
         {:ok, tournament} <- writable(user, tournament),
         {:ok, status} <- BoardLan.choose(address, port) do
      Audit.log(tournament.id, user, "boards.lan_switched", %{
        enabled: status.enabled?,
        address: status.address,
        port: status.port,
        moved: true
      })

      {:noreply, load(socket)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, refusal(reason))}
      false -> {:noreply, socket}
    end
  end

  def handle_event("revoke_code", %{"id" => id}, socket) do
    %{current_scope: user, tournament: tournament} = socket.assigns

    with {id, ""} <- Integer.parse(id),
         {:ok, link} <- BoardLink.revoke_link(user, tournament, id) do
      fresh = socket.assigns.fresh
      fresh = if fresh && fresh.id == link.id, do: nil, else: fresh
      {:noreply, socket |> assign(fresh: fresh) |> load()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, refusal(reason))}
      _not_an_id -> {:noreply, socket}
    end
  end

  def handle_event("hide_code", _params, socket), do: {:noreply, assign(socket, fresh: nil)}

  def handle_event("save_relay_key", %{"relay" => %{"key" => key}}, socket) do
    %{current_scope: user, tournament: tournament} = socket.assigns

    case BoardLink.set_relay_key(user, tournament, key) do
      {:ok, tournament} ->
        {:noreply,
         socket
         |> assign(tournament: tournament, relay_form: to_form(%{"key" => ""}, as: :relay))
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refusal(reason))}
    end
  end

  def handle_event("retry_relay_key", _params, socket) do
    %{current_scope: user, tournament: tournament} = socket.assigns

    case BoardLink.retry_relay_key(user, tournament) do
      {:ok, tournament} -> {:noreply, socket |> assign(tournament: tournament) |> load()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, refusal(reason))}
    end
  end

  def handle_event("replace_relay_key", _params, socket) do
    %{current_scope: user, tournament: tournament} = socket.assigns

    case BoardLink.replace_relay_key(user, tournament) do
      {:ok, tournament} -> {:noreply, socket |> assign(tournament: tournament) |> load()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, refusal(reason))}
    end
  end

  def handle_event("clear_relay_key", _params, socket) do
    %{current_scope: user, tournament: tournament} = socket.assigns

    case BoardLink.set_relay_key(user, tournament, nil) do
      {:ok, tournament} -> {:noreply, socket |> assign(tournament: tournament) |> load()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, refusal(reason))}
    end
  end

  # The same switch as on Settings, OpenResults - offered here because this
  # is where somebody connecting a box is looking. Connecting a box does not
  # flip it: a link on the public page is a statement to spectators, and
  # those are the arbiter's to make.
  def handle_event("toggle_live_boards", _params, socket) do
    tournament = socket.assigns.tournament

    if tournament.publish_to_openresults do
      on? = not tournament.public_live_boards

      case Tournaments.set_live_boards(tournament, on?) do
        {:ok, tournament} ->
          Audit.log(tournament.id, socket.assigns.current_scope, "openresults.live_boards", %{
            enabled: on?
          })

          {:noreply, socket |> assign(tournament: tournament) |> load()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, refusal(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  # The switch is the installation's, but it is pressed on a tournament's
  # page and written to that tournament's trail: whoever presses it must be
  # somebody who may open this tournament at all.
  defp writable(user, tournament) do
    case Tournaments.get_authorized_tournament(user, tournament.id) do
      nil -> {:error, :not_found}
      tournament -> {:ok, tournament}
    end
  end

  defp refusal(:archived), do: error_text(:archived)
  defp refusal(:handed_off), do: error_text(:handed_off)

  defp refusal(:too_many_codes),
    do:
      gettext("There are already %{max} codes. Withdraw one you no longer use first.",
        max: BoardLink.max_links()
      )

  defp refusal(:not_grouped), do: gettext("This tournament is not in a group.")

  defp refusal(:relay_key_shape),
    do: gettext("That does not look like a relay key: 16 to 200 characters, no spaces.")

  defp refusal(:not_an_address),
    do: gettext("That is not one of this computer's network addresses any more. Pick another.")

  defp refusal(:bad_port),
    do:
      gettext(
        "That port cannot be used: a number from 1024 to 65535, and not the one this program itself is on."
      )

  defp refusal(_other), do: gettext("Could not change this")

  # What the network listener is doing, in a sentence.
  defp lan_state(%{state: :listening} = lan),
    do: gettext("Answering boxes at %{address}.", address: lan.base_url)

  defp lan_state(%{state: :idle} = lan),
    do:
      gettext(
        "Ready at %{address}, and closed until there is a code for a box on the network: no code, no open port. Make one below.",
        address: lan.base_url
      )

  defp lan_state(%{state: :port_taken} = lan),
    do:
      gettext(
        "Port %{port} is in use by another program on this computer, so boxes cannot connect. Pick another port below. Nothing else is affected.",
        port: lan.port
      )

  defp lan_state(%{state: :address_gone, addresses: []} = lan),
    do:
      gettext(
        "This computer no longer has the address %{old}, and has no network address at all right now. Boxes cannot find it. Connect the network; if it comes back with another address, pick it below and make new codes.",
        old: lan.address
      )

  defp lan_state(%{state: :address_gone} = lan),
    do:
      gettext(
        "This computer's address changed from %{old} to %{new}: boxes with the old code cannot find it. Pick the new address below and make a new code, or give this computer a fixed address so that it does not happen again.",
        old: lan.address,
        new: Enum.join(lan.addresses, ", ")
      )

  defp lan_state(%{state: :no_address}),
    do:
      gettext(
        "This computer has no address on a local network right now, so there is nothing for a box to connect to. Plug in the cable or join the hall's network; this page looks again by itself."
      )

  defp lan_state(%{state: :failed} = lan),
    do:
      gettext(
        "Could not start answering on %{address}, port %{port}. Try another port; if Windows asked whether to allow this program on the network and the answer was no, allow it in Windows' firewall settings.",
        address: lan.address,
        port: lan.port
      )

  defp lan_state(_off), do: nil

  # A network code whose address is no longer the one this computer answers
  # on, or nil. The box holding it is calling an address where nothing is.
  defp stranded(%{reach: "lan"} = link, lan, now) do
    cond do
      BoardLink.expired?(link, now) ->
        nil

      not lan.enabled? ->
        gettext("The switch above is off, so the box with this code cannot connect.")

      is_nil(lan.base_url) ->
        gettext(
          "Made for %{address}, where this computer is not answering right now. See above.",
          address: link.address
        )

      link.address == lan.base_url ->
        nil

      true ->
        gettext(
          "Made for %{old}; this computer now answers at %{new}. The box with this code cannot find it: make a new code.",
          old: link.address,
          new: lan.base_url
        )
    end
  end

  defp stranded(_link, _lan, _now), do: nil

  # Why the results site said no, in the arbiter's language. The site's own
  # code is the fallback: a new one should read as a code, not as nothing.
  defp relay_reason("unsupported"),
    do: gettext("it is an older version that cannot do this by itself")

  defp relay_reason("unauthorized"),
    do: gettext("it does not accept the credentials this copy publishes with")

  defp relay_reason("not_owner"),
    do: gettext("it says this tournament belongs to another publisher")

  defp relay_reason(code) when code in ~w(key_required key_mismatch),
    do: gettext("it does not accept this tournament's publishing key")

  defp relay_reason("installation_suspended"),
    do: gettext("this copy's access to the results site is suspended")

  defp relay_reason("installation_revoked"),
    do: gettext("this copy's access to the results site has been withdrawn")

  defp relay_reason("tournament_hidden"),
    do: gettext("the operator of the results site has hidden this tournament")

  defp relay_reason("address_blocked"),
    do: gettext("requests from this address are blocked there")

  defp relay_reason("relay_key_limit"),
    do:
      gettext(
        "the tournament already holds as many as it may; the site's administrator can withdraw some"
      )

  defp relay_reason(code), do: gettext("it answered %{code}", code: code || "?")

  # Why it has not arrived yet, or nil when there is nothing to say: the
  # first try is under way.
  defp relay_waiting("unreachable"),
    do: gettext("The results site cannot be reached right now. This is tried again by itself.")

  defp relay_waiting("tournament_not_published"),
    do:
      gettext(
        "The results site does not show this tournament yet. This is tried again by itself once it does."
      )

  defp relay_waiting(nil), do: nil

  defp relay_waiting(_busy),
    do: gettext("The results site is busy or paused. This is tried again by itself.")

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
        active={:boards}
        subtitle={gettext("Settings - Live boards")}
        show_status={false}
      >
        <div class="card" id="boards-intro">
          <h2>{gettext("Live boards")}</h2>

          <p class="hint" style="margin-top: 0">
            <.rich_text text={
              gettext(
                "A box in the playing hall reads the electronic boards. Give it a code from this page and it fetches the pairings by itself, starts each round when you pair it, and reports back what the boards saw. A board never enters a result: you do, and the Pairings page shows the board's beside yours. See %[link]."
              )
            }>
              <:part name="link">
                <.link
                  id="boards-manual-link"
                  href={PairingsEngineWeb.Components.ManualLink.path(:board_link)}
                  target="_blank"
                  rel="noopener"
                >
                  {gettext("the manual")}
                </.link>
              </:part>
            </.rich_text>
          </p>

          <p class="hint" id="boards-address">
            <%= if BoardLinkAddress.reachable_from_other_machines?() do %>
              {gettext("The box calls this server at %{address}.",
                address: BoardLinkAddress.base_url()
              )}
            <% else %>
              <%= if BoardLan.usable?(@lan) do %>
                {gettext(
                  "A box program on this computer calls %{address}. A box elsewhere on the hall's network calls %{lan}, which answers the boards and nothing else.",
                  address: BoardLinkAddress.base_url(),
                  lan: @lan.base_url
                )}
              <% else %>
                {gettext(
                  "This copy answers on this computer only: a box program on this computer calls %{address}. A box elsewhere on the network cannot reach it until you switch on \"Let boards on this network connect\" below.",
                  address: BoardLinkAddress.base_url()
                )}
              <% end %>
            <% end %>
          </p>
        </div>

        <div :if={@lan.available?} class="card" id="boards-lan" data-state={@lan.state}>
          <h2>{gettext("Boxes elsewhere on this network")}</h2>

          <p class="hint" style="margin-top: 0">
            {gettext(
              "For a box that is not on this computer: a Raspberry Pi beside the boards, a second laptop. This is a setting of this computer, for every tournament on it."
            )}
          </p>

          <div class="set-field solo">
            <.publish_toggle
              id="boards-lan-toggle"
              label={gettext("Let boards on this network connect")}
              state={if @lan.enabled?, do: :public, else: :not_public}
              on_text={gettext("On")}
              off_text={gettext("Off")}
              phx-click="lan_switch"
              confirm={
                gettext(
                  "Switch this off? Boxes on the network are disconnected at once. Their codes are kept and work again when you switch it back on."
                )
              }
            />
          </div>

          <p id="boards-lan-warning">
            <.icon name="hero-exclamation-triangle" class="size-4" /> {gettext(
              "What this does: it opens one extra door on this computer, on the network address you choose, that answers the board box and nothing else. Your tournaments, these pages and everything else stay reachable from this computer only, as before. The door is plain http: the code of a box travels over the network readable. On a cable between two machines, or a network of your own, that is fine. On a wifi the players are on too, anybody who knows how can read the code and then see the pairings and send in moves as if they were a board. They cannot enter a result; a board never does. Prefer a cable or your own network, and withdraw the code after the event."
            )}
          </p>

          <%= if @lan.enabled? do %>
            <p
              id="boards-lan-state"
              role={if @lan.state in [:idle, :listening], do: "status", else: "alert"}
              class={@lan.state not in [:idle, :listening] && "board-mismatch-text"}
            >
              {lan_state(@lan)}
            </p>

            <.form
              :if={@lan.addresses != []}
              for={to_form(%{"address" => @lan.address, "port" => @lan.port}, as: :lan)}
              id="boards-lan-form"
              phx-submit="lan_choose"
              class="group-inline-form"
            >
              <.input
                type="select"
                name="lan[address]"
                id="boards-lan-address"
                label={gettext("This computer's address for boxes")}
                options={@lan.addresses}
                value={if @lan.address in @lan.addresses, do: @lan.address, else: hd(@lan.addresses)}
              />
              <.input
                type="number"
                name="lan[port]"
                id="boards-lan-port"
                label={gettext("Port")}
                value={@lan.port}
                min="1024"
                max="65535"
              />
              <button type="submit" class="pe-btn" id="boards-lan-save">{gettext("Use these")}</button>
            </.form>

            <p class="hint" id="boards-lan-addresses">
              {ngettext(
                "This computer has one address on a local network. A code for a box on the network carries it.",
                "This computer is on %{count} local networks. Pick the address of the one the box is on: only that one is opened, and a code for a box on the network carries it.",
                length(@lan.addresses)
              )} {gettext(
                "If the network gives this computer another address tomorrow, the codes made today point nowhere; this page says so when it happens. A fixed address for this computer, set in the router or in Windows, prevents it."
              )}
            </p>

            <p class="hint" id="boards-lan-firewall">
              {gettext(
                "Windows will ask. The first time this is used, Windows shows \"Windows Security: do you want to allow this app to communicate on these networks?\". Tick Private networks and choose Allow. This program cannot answer that for you. If you chose Cancel, or never saw the question, boxes get no answer: allow OpenPairings under Windows Security, Firewall, Allow an app through firewall."
              )}
            </p>

            <p class="hint" id="boards-lan-limits" style="margin-bottom: 0">
              {gettext(
                "It answers addresses on a local network only, accepts only codes made for a box on the network, and closes by itself when no such code exists. Such a code works until it is withdrawn."
              )}
            </p>
          <% end %>
        </div>

        <.codes_card
          id="tournament-codes"
          scope="tournament"
          title={gettext("Codes for this tournament")}
          hint={gettext("One code per box. A code reaches this tournament and nothing else.")}
          links={@links.tournament}
          fresh={@fresh}
          now={@now}
          tournament={@tournament}
          lan={@lan}
        />
        <.codes_card
          :if={@group}
          id="group-codes"
          scope="group"
          title={gettext("Codes for the group %{name}", name: @group.group.name)}
          hint={
            gettext(
              "One scan sets the box up for every tournament of the group that the maker of the code may open - also one added to the group later. Which table plays in which tournament is decided on the box."
            )
          }
          links={@links.group}
          fresh={@fresh}
          now={@now}
          tournament={@tournament}
          lan={@lan}
        />
        <.account_links_card
          :if={@account_links != []}
          links={@account_links}
          current_scope={@current_scope}
          now={@now}
        />
        <div class="card" id="boards-results-site">
          <h2>{gettext("The results site")}</h2>

          <%= if @target do %>
            <p class="hint" style="margin-top: 0" id="boards-target">
              {gettext(
                "Connected to %{server} as %{slug}. The box sends the moves there and learns both over the link.",
                server: @target["server_url"],
                slug: @target["slug"]
              )}
            </p>

            <div class="set-field solo">
              <.publish_toggle
                id="boards-live-toggle"
                label={gettext("Live link on the results site")}
                state={if @tournament.public_live_boards, do: :public, else: :not_public}
                on_text={gettext("On")}
                off_text={gettext("Off")}
                phx-click="toggle_live_boards"
              />
              <p class="hint" style="margin: 6px 0 0">
                {gettext(
                  "Connecting a box does not switch this on. It puts a Live link on the public pages, and that is yours to say."
                )}
              </p>
            </div>

            <h3 style="margin-top: 20px">{gettext("May the box send moves there?")}</h3>

            <div id="boards-permission" data-state={@relay.state}>
              <%= case @relay.state do %>
                <% :held -> %>
                  <p id="relay-key-held" style="margin-top: 0">
                    <.icon name="hero-check-circle" class="size-4" /> {gettext(
                      "Yes. The box may send moves there."
                    )}
                  </p>

                  <p class="hint" id="relay-key-origin">
                    <%= if @relay.origin == :fetched do %>
                      {gettext(
                        "This copy fetched the permission from the results site on %{date} (relay key ending in %{hint}) and hands it to the box over the link. Nothing to copy.",
                        date: Calendar.strftime(@relay.at, "%d-%m-%Y %H:%M UTC"),
                        hint: @relay.hint
                      )}
                    <% else %>
                      {gettext(
                        "With a relay key that was pasted here (ending in %{hint}). The box receives it over the link.",
                        hint: @relay.hint
                      )}
                    <% end %>
                  </p>

                  <p :if={@relay.replacing?} class="hint" id="relay-key-replacing" role="status">
                    {gettext(
                      "Getting a new permission from the results site… The box keeps the old one until the new one is here."
                    )}
                  </p>

                  <p :if={@relay.problem && !@relay.replacing?} class="hint" id="relay-key-problem">
                    {gettext("The results site did not hand out a new one: %{reason}.",
                      reason: relay_reason(@relay.problem)
                    )}
                  </p>

                  <button
                    :if={!@relay.replacing?}
                    type="button"
                    id="relay-key-replace"
                    class="pe-btn"
                    phx-click="replace_relay_key"
                    data-confirm={
                      gettext(
                        "Replace the box's permission? The results site hands out a new one and stops accepting the old one. A box that is connected picks the new one up within seconds; one that is switched off picks it up when it is back."
                      )
                    }
                    disabled={!is_nil(@tournament.archived_at)}
                  >
                    {gettext("Replace the box's permission")}
                  </button>
                <% :fetching -> %>
                  <p id="relay-key-fetching" style="margin-top: 0" role="status">
                    <.icon name="hero-arrow-path" class="size-4" /> {gettext(
                      "Getting permission from the results site…"
                    )}
                  </p>

                  <p :if={relay_waiting(@relay.reason)} class="hint" id="relay-key-waiting">
                    {relay_waiting(@relay.reason)}
                  </p>

                  <p class="hint">
                    {gettext(
                      "Until it is here the box reads the boards and reports to this page, and sends nothing to the results site."
                    )}
                  </p>
                <% :refused -> %>
                  <p id="relay-key-refused" style="margin-top: 0" role="alert">
                    <.icon name="hero-exclamation-triangle" class="size-4" /> {gettext(
                      "Not yet. The results site did not give permission: %{reason}.",
                      reason: relay_reason(@relay.reason)
                    )}
                  </p>

                  <p class="hint">
                    {gettext(
                      "The box reads the boards and reports to this page, and sends nothing to the results site."
                    )}
                  </p>

                  <button
                    type="button"
                    id="relay-key-retry"
                    class="pe-btn"
                    phx-click="retry_relay_key"
                    disabled={!is_nil(@tournament.archived_at)}
                  >
                    {gettext("Try again")}
                  </button>
                <% _idle -> %>
                  <p class="hint" id="relay-key-idle" style="margin-top: 0">
                    {gettext(
                      "Not asked yet. This copy asks the results site for the box's permission by itself as soon as there is a connect code on this page, or the live link above is on. There is nothing to copy or paste."
                    )}
                  </p>
              <% end %>
            </div>

            <div :if={@relay.fallback?} id="relay-key-fallback" style="margin-top: 16px">
              <p class="hint" style="margin-top: 0">
                {gettext(
                  "This results site is an older version that cannot hand out the box's permission by itself. Until it is updated, ask its administrator for a relay key for this tournament (Tournaments, the tournament, Relay keys) and paste it here once; the box receives it over the link. It is kept on this machine, is not in an export, and is not shown again."
                )}
              </p>

              <.form
                for={@relay_form}
                id="relay-key-form"
                phx-submit="save_relay_key"
                class="group-inline-form"
              >
                <.input
                  field={@relay_form[:key]}
                  type="password"
                  label={gettext("Relay key")}
                  autocomplete="off"
                  placeholder="orrk_…"
                />
                <button
                  type="submit"
                  class="pe-btn"
                  id="relay-key-save"
                  disabled={!is_nil(@tournament.archived_at)}
                >
                  {gettext("Save")}
                </button>
              </.form>

              <button
                :if={@relay.state == :held and @relay.origin == :pasted}
                type="button"
                id="relay-key-clear"
                class="pe-btn danger-link"
                phx-click="clear_relay_key"
                data-confirm={
                  gettext(
                    "Remove the relay key? The box stops receiving it, and can no longer send moves to the results site once it notices."
                  )
                }
                disabled={!is_nil(@tournament.archived_at)}
              >
                {gettext("Remove the pasted relay key")}
              </button>
            </div>
          <% else %>
            <p class="hint" style="margin-top: 0" id="boards-no-target">
              <.rich_text text={
                gettext(
                  "Put the tournament on the results site first: Settings, %[link]. Until then the box has nowhere to send the moves; it still reads the boards and reports here. Once the tournament is there, this copy arranges the box's permission by itself."
                )
              }>
                <:part name="link">
                  <.link navigate={~p"/t/#{@tournament.id}/settings/results"}>
                    {gettext("OpenResults")}
                  </.link>
                </:part>
              </.rich_text>
            </p>
          <% end %>
        </div>

        <div class="card" id="boards-games">
          <h2>{gettext("Games the boards reported")}</h2>

          <%= if @game_count == 0 do %>
            <p class="hint" style="margin-top: 0" id="boards-no-games">
              {gettext("None yet.")}
            </p>
          <% else %>
            <p style="margin-top: 0" id="boards-game-count">
              {ngettext("%{count} game.", "%{count} games.", @game_count)} {gettext(
                "Each is kept with the tournament and is in its export. Open one from its row on the Pairings page."
              )}
            </p>

            <p>
              <.link
                id="boards-pgn-all"
                class="pe-btn"
                href={~p"/t/#{@tournament.id}/export/pgn?moves=1"}
              >
                {gettext("PGN, whole tournament")}
              </.link>

              <.link
                :for={round <- @rounds}
                id={"boards-pgn-round-#{round.number}"}
                class="pe-btn"
                href={~p"/t/#{@tournament.id}/export/pgn?moves=1&round=#{round.number}"}
              >
                {gettext("Round %{n}", n: round.number)}
              </.link>
            </p>

            <p class="hint" style="margin-bottom: 0">
              {gettext(
                "The result in a file is the one you entered, or * until you have. The moves are as the box reported them."
              )}
            </p>
          <% end %>
        </div>
      </.settings_page>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :scope, :string, required: true
  attr :title, :string, required: true
  attr :hint, :string, required: true
  attr :links, :list, required: true
  attr :fresh, :any, required: true
  attr :now, :any, required: true
  attr :tournament, :map, required: true
  attr :lan, :map, required: true

  defp codes_card(assigns) do
    ~H"""
    <div class="card" id={@id}>
      <h2>{@title}</h2>

      <p class="hint" style="margin-top: 0">{@hint}</p>

      <div
        :if={@fresh && @fresh.scope == @scope}
        id={"#{@id}-fresh"}
        class="board-code-fresh"
        role="status"
      >
        <p style="margin-top: 0">
          <strong>{gettext("The new code. It is shown this once.")}</strong> {gettext(
            "Scan it with the box, or copy the line into the box's setup page. Once you leave this page it cannot be shown again - make another if you lose it."
          )}
        </p>

        <div class="enroll-qr">
          <div
            class="enroll-qr-inner"
            role="img"
            aria-label={gettext("QR code of the connect code")}
            id={"#{@id}-qr"}
          >
            {Phoenix.HTML.raw(
              String.replace(Mobile.qr_svg(@fresh.code), "<svg", ~s(<svg aria-hidden="true"),
                global: false
              )
            )}
          </div>
        </div>

        <p id={"#{@id}-where"}>
          <strong>
            <%= cond do %>
              <% @fresh.where == :lan -> %>
                {gettext(
                  "For a box on the network. It leads to %{address}: this computer, from any machine on the same local network.",
                  address: @fresh.address
                )}
              <% @lan.available? -> %>
                {gettext(
                  "For a box program on this computer. It leads to %{address}, which no other machine can reach.",
                  address: @fresh.address
                )}
              <% true -> %>
                {gettext("It leads to %{address}.", address: @fresh.address)}
            <% end %>
          </strong>

          <span :if={@fresh.where == :lan}>
            {gettext(
              "It works until it is withdrawn, and only while \"Let boards on this network connect\" is on."
            )}
          </span>
        </p>

        <p>
          <code id={"#{@id}-code"} class="board-code">{@fresh.code}</code>
        </p>

        <div :if={@fresh.name_code} id={"#{@id}-name-code"}>
          <p class="hint">
            {gettext(
              "The same code with this computer's name instead of its address. A name still works after the network gives this computer another address, but only if the box can look the name up, which depends on the network and on the box. Try the code above first; use this one if the address keeps changing."
            )}
          </p>

          <p>
            <code class="board-code">{@fresh.name_code}</code>
          </p>
        </div>

        <button type="button" class="pe-btn" id={"#{@id}-hide"} phx-click="hide_code">
          {gettext("Done, hide it")}
        </button>
      </div>

      <table :if={@links != []} class="pe-table board-links" id={"#{@id}-list"}>
        <thead>
          <tr>
            <th scope="col">{gettext("Code")}</th>

            <th scope="col">{gettext("Box")}</th>

            <th scope="col">{gettext("Last contact")}</th>

            <th scope="col" class="num">{gettext("Boards")}</th>

            <th scope="col" aria-label={gettext("Actions")}></th>
          </tr>
        </thead>

        <tbody>
          <tr :for={link <- @links} id={"board-link-#{link.id}"}>
            <td>
              <code>…{link.secret_hint}</code>
              <span class="hint">{Calendar.strftime(link.inserted_at, "%d-%m-%Y %H:%M")} UTC</span>
              <%= if link.reach == "lan" do %>
                <span class="badge" id={"board-link-reach-#{link.id}"}>{gettext("Network")}</span>
                <span class="hint" id={"board-link-expiry-#{link.id}"}>
                  <%= if BoardLink.expired?(link, @now) do %>
                    <span class="board-mismatch-text">
                      {gettext("Expired. Withdraw it and make a new one.")}
                    </span>
                  <% else %>
                    <%= if link.expires_at do %>
                      {gettext("%{address}, until %{date}",
                        address: link.address,
                        date: Calendar.strftime(link.expires_at, "%d-%m-%Y")
                      )}
                    <% else %>
                      {link.address}
                    <% end %>
                  <% end %>
                </span>

                <span
                  :if={stranded(link, @lan, @now)}
                  class="board-mismatch-text"
                  id={"board-link-stranded-#{link.id}"}
                  role="alert"
                >
                  {stranded(link, @lan, @now)}
                </span>
              <% end %>
            </td>

            <td id={"board-link-box-#{link.id}"}>
              <%= if link.box_name || link.box_version do %>
                {link.box_name || gettext("A box")}
                <span :if={link.box_version} class="hint">{link.box_version}</span>
              <% else %>
                <span class="hint">-</span>
              <% end %>
            </td>

            <td id={"board-link-seen-#{link.id}"}>
              <%= cond do %>
                <% is_nil(link.last_seen_at) -> %>
                  <span class="hint">{gettext("Never used")}</span>
                <% present?(link, @now) -> %>
                  <span class="badge">{gettext("Connected")}</span>
                <% true -> %>
                  {ago(link.last_seen_at, @now)}
              <% end %>
            </td>

            <td class="num" id={"board-link-boards-#{link.id}"}>
              {boards_here(link, @tournament)}
            </td>

            <td>
              <button
                type="button"
                id={"board-link-revoke-#{link.id}"}
                class="pe-btn danger-link"
                phx-click="revoke_code"
                phx-value-id={link.id}
                data-confirm={
                  gettext(
                    "Withdraw this code? The box that uses it is disconnected at its next request and needs a new code."
                  )
                }
                disabled={!is_nil(@tournament.archived_at)}
              >
                {gettext("Withdraw")}
              </button>
            </td>
          </tr>
        </tbody>
      </table>

      <p :if={@links == []} class="hint" id={"#{@id}-none"}>{gettext("No code yet.")}</p>

      <button
        type="button"
        id={"#{@id}-new"}
        class="pe-btn primary"
        phx-click="new_code"
        phx-value-scope={@scope}
        disabled={!is_nil(@tournament.archived_at)}
      >
        <%= if @lan.available? do %>
          {gettext("New code for a box on this computer")}
        <% else %>
          {gettext("New code")}
        <% end %>
      </button>

      <button
        :if={BoardLan.usable?(@lan)}
        type="button"
        id={"#{@id}-new-lan"}
        class="pe-btn primary"
        phx-click="new_code"
        phx-value-scope={@scope}
        phx-value-where="lan"
        disabled={!is_nil(@tournament.archived_at)}
      >
        {gettext("New code for a box on the network")}
      </button>
    </div>
    """
  end

  # Read-only: the account-wide links that also reach this tournament. They
  # are withdrawn on the account page, by the account they belong to. Only
  # the main listener ever sees them: the network listener accepts nothing
  # but its own codes, and this page is not served there.
  attr :links, :list, required: true
  attr :current_scope, :map, required: true
  attr :now, :any, required: true

  defp account_links_card(assigns) do
    ~H"""
    <div class="card" id="account-codes">
      <h2>{gettext("Account-wide links")}</h2>

      <p class="hint" style="margin-top: 0">
        {gettext(
          "These board boxes are connected to a whole account and reach this tournament along with the rest of that account's current tournaments. They are listed here, not managed: an account withdraws its own on its account page."
        )}
      </p>

      <ul class="acct-boards" id="account-code-list">
        <li :for={link <- @links} id={"account-code-#{link.id}"} class="acct-board">
          <div class="acct-board-text">
            <span class="acct-board-name">
              {link.label || link.box_name || gettext("A board box")}
            </span>
            <span class="acct-board-meta" id={"account-code-meta-#{link.id}"}>
              {gettext("Account %{email}", email: link.user.email)} · {gettext("made %{date}",
                date: Calendar.strftime(link.inserted_at, "%Y-%m-%d")
              )} · {account_seen(link, @now)}
            </span>
          </div>

          <%= if link.user_id == @current_scope.user.id do %>
            <.link
              id={"account-code-withdraw-#{link.id}"}
              navigate={~p"/users/settings"}
              class="pe-btn danger-link"
            >
              {gettext("Withdraw on your account page")}
            </.link>
          <% else %>
            <span class="hint" id={"account-code-other-#{link.id}"}>
              {gettext("Withdrawn by that account")}
            </span>
          <% end %>
        </li>
      </ul>
    </div>
    """
  end

  defp account_seen(%{last_seen_at: nil}, _now), do: gettext("Never used")
  defp account_seen(link, now), do: gettext("last seen %{ago}", ago: ago(link.last_seen_at, now))

  defp present?(link, now), do: DateTime.diff(now, link.last_seen_at) < @present_s

  defp ago(then, now) do
    case DateTime.diff(now, then) do
      s when s < 120 -> gettext("%{n} s ago", n: max(s, 0))
      s when s < 7200 -> gettext("%{n} min ago", n: div(s, 60))
      s when s < 172_800 -> gettext("%{n} h ago", n: div(s, 3600))
      s -> gettext("%{n} days ago", n: div(s, 86_400))
    end
  end

  # What the box said it has on this tournament, or a dash when it has not
  # said.
  defp boards_here(link, tournament) do
    case link.box_boards do
      %{} = boards -> Map.get(boards, Integer.to_string(tournament.id), "-")
      _unsaid -> "-"
    end
  end
end
