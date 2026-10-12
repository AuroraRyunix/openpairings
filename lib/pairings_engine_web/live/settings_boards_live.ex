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
  alias PairingsEngineWeb.BoardLinkAddress

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
      group: TournamentGroups.membership(tournament.id),
      target: BoardLink.openresults_target(tournament),
      relay: RelayKeys.status(tournament),
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
  def handle_event("new_code", %{"scope" => scope}, socket) when scope in ~w(tournament group) do
    %{current_scope: user, tournament: tournament} = socket.assigns

    result =
      if scope == "group",
        do: BoardLink.create_group_link(user, tournament),
        else: BoardLink.create_link(user, tournament)

    case result do
      {:ok, link, secret} ->
        {:noreply,
         socket
         |> assign(
           fresh: %{id: link.id, scope: scope, code: BoardLinkAddress.connect_code(secret)}
         )
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refusal(reason))}
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

  defp refusal(_other), do: gettext("Could not change this")

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
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">{gettext("Settings - Live boards")}</p>
        </div>
      </div>

      <.settings_subnav tournament={@tournament} active={:boards} />

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
            {gettext(
              "This copy answers on this computer only, so the box program has to run on this computer too: it calls %{address}. A box elsewhere on the network cannot reach it.",
              address: BoardLinkAddress.base_url()
            )}
          <% end %>
        </p>
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
                  <.icon name="hero-check-circle" class="size-4" />
                  {gettext("Yes. The box may send moves there.")}
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
                  <.icon name="hero-arrow-path" class="size-4" />
                  {gettext("Getting permission from the results site…")}
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
                  <.icon name="hero-exclamation-triangle" class="size-4" />
                  {gettext("Not yet. The results site did not give permission: %{reason}.",
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
            {ngettext("%{count} game.", "%{count} games.", @game_count)}
            {gettext(
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
          <strong>{gettext("The new code. It is shown this once.")}</strong>
          {gettext(
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

        <p>
          <code id={"#{@id}-code"} class="board-code">{@fresh.code}</code>
        </p>

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
        {gettext("New code")}
      </button>
    </div>
    """
  end

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
