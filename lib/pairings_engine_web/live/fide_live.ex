defmodule PairingsEngineWeb.FideLive do
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.Components.ConnectionStatus

  alias PairingsEngine.Accounts.User
  alias PairingsEngine.Kbsb
  alias PairingsEngine.Fide.Sync, as: FideSync
  alias PairingsEngine.Kbsb.Sync, as: KbsbSync
  alias PairingsEngine.Kbsb.Api, as: KbsbApi
  alias PairingsEngine.Publishing

  # See the same constant on the OpenResults settings page for why this is a
  # poll and not a subscription.
  @connection_poll :timer.seconds(10)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, FideSync.topic())
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, KbsbSync.topic())
      if connection_polling?(), do: send(self(), :poll_connection)
    end

    {:ok,
     socket
     |> assign(
       page_title: "Connections",
       status: FideSync.status(),
       kbsb_status: KbsbSync.status(),
       kbsb_query: "",
       kbsb_results: [],
       # Read once at mount: this comes from the server's environment, so it
       # cannot change while the page is open. False hides the sync button
       # entirely rather than offering an action that can only fail.
       kbsb_api_configured: KbsbApi.configured?(),
       # Local self-registration is open to anyone - the full FIDE list
       # download (~41 MB, once a click) is exactly the kind of thing that's
       # cheap to trigger and expensive to serve, so it's restricted to
       # accounts we actually vouch for (SSO), same reasoning as
       # `PairingsEngine.Accounts.User.sso?/1`'s own moduledoc.
       sso?: User.sso?(socket.assigns.current_scope.user)
     )
     |> assign_publishing()}
  end

  # The OpenResults settings are machine-wide, so they are read from storage
  # rather than held in a form struct: two arbiters on two devices are not
  # editing the same field, and a reload should show what the machine
  # actually has rather than what this socket last typed.
  defp assign_publishing(socket) do
    assign(socket,
      publish_endpoint: Publishing.endpoint() || "",
      publish_token_set?: is_binary(Publishing.token()) and Publishing.token() != "",
      publish_configured?: Publishing.configured?(),
      publish_pending: Publishing.pending_count(),
      publish_test: nil,
      connection: nil
    )
  end

  # In a task, never in this process. `Publishing.status/0` is a network round
  # trip with a fifteen-second timeout, and running it here would freeze the
  # page - every click, every toggle - for as long as an unreachable results
  # site takes to give up. Mount used to call it directly, which meant a
  # settings page took fifteen seconds to appear on exactly the machine whose
  # connection somebody had come to check.
  def handle_info(:poll_connection, socket) do
    parent = self()

    Task.Supervisor.start_child(PairingsEngine.TaskSupervisor, fn ->
      # Rescued because this is a network call and the page must survive
      # anything it does. A check that blows up should leave the last known
      # state on screen, not take the settings page down with it.
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

  @impl true
  def handle_info({:fide_sync, _state}, socket) do
    {:noreply, assign(socket, status: FideSync.status())}
  end

  def handle_info({:kbsb_sync, _state}, socket) do
    {:noreply, assign(socket, kbsb_status: KbsbSync.status())}
  end

  @impl true
  def handle_event("save_publishing", params, socket) do
    if socket.assigns.sso? do
      save_publishing(params, socket)
    else
      {:noreply, put_flash(socket, :error, publishing_restricted())}
    end
  end

  def handle_event("clear_publishing_token", _params, socket) do
    if socket.assigns.sso? do
      Publishing.put_token(nil)

      {:noreply,
       socket
       |> assign_publishing()
       |> put_flash(
         :info,
         gettext("Token removed. Nothing will be published until a new one is set.")
       )}
    else
      {:noreply, put_flash(socket, :error, publishing_restricted())}
    end
  end

  def handle_event("test_publishing", _params, socket) do
    if socket.assigns.sso? do
      {:noreply, assign(socket, publish_test: Publishing.check())}
    else
      {:noreply, put_flash(socket, :error, publishing_restricted())}
    end
  end

  def handle_event("sync", _params, socket) do
    if socket.assigns.sso? do
      FideSync.start_sync()
      {:noreply, assign(socket, status: FideSync.status())}
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "Downloading the full FIDE rating list is limited to SSO-signed-in accounts."
       )}
    end
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    if socket.assigns.sso? do
      FideSync.cancel_sync()
    end

    {:noreply, assign(socket, status: FideSync.status())}
  end

  def handle_event("sync_kbsb_api", _params, socket) do
    KbsbSync.start_api_import()
    {:noreply, assign(socket, kbsb_status: KbsbSync.status())}
  end

  def handle_event("cancel_kbsb", _params, socket) do
    KbsbSync.cancel_import()
    {:noreply, assign(socket, kbsb_status: KbsbSync.status())}
  end

  def handle_event("kbsb_search", %{"q" => q}, socket) do
    {:noreply, assign(socket, kbsb_query: q, kbsb_results: Kbsb.search(q))}
  end

  defp busy?(%{status: s}), do: s in [:downloading, :importing]

  defp percent(%{status: :downloading, loaded_bytes: loaded, total_bytes: total})
       when total > 0 do
    Float.round(loaded / total * 100, 1)
  end

  defp percent(%{status: :importing, imported_rows: done, total_rows: total}) when total > 0 do
    Float.round(done / total * 100, 1)
  end

  defp percent(_), do: nil

  defp format_count(n) do
    n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  end

  # Where a copy of every published tournament goes is a machine-wide setting,
  # and repointing it at another server would quietly ship player names,
  # ratings and clubs there. That is an operator's decision, not an account
  # holder's, so it sits behind the same SSO gate as the FIDE download rather
  # than being merely hidden - a hidden button still accepts a crafted event.
  #
  # Deliberately NOT extended to a tournament's own publish switch. The split
  # is: an operator decides WHERE this machine publishes, and the arbiter
  # running an event decides WHETHER theirs goes. Gating the second would stop
  # an arbiter publishing their own tournament on a machine somebody else
  # configured, which is the ordinary case rather than the dangerous one.
  defp publishing_restricted,
    do: gettext("Where this machine publishes is limited to SSO-signed-in accounts.")

  defp save_publishing(params, socket) do
    Publishing.put_endpoint(blank_to_nil(params["endpoint"]))

    # An empty token box means "leave it alone", not "clear it". The value is
    # never rendered back (it is a secret), so a save from a page that showed
    # a blank box would otherwise wipe a working token every time somebody
    # edited the address beside it.
    case blank_to_nil(params["token"]) do
      nil -> :ok
      token -> Publishing.put_token(token)
    end

    # Saved settings are tested immediately rather than leaving the arbiter to
    # press Test as a second step. "Saved" on its own answers the wrong
    # question: nobody types an address to find out whether it was stored,
    # they type it to find out whether it works, and a typo that saves
    # perfectly well is the whole failure mode here.
    #
    # Synchronous, like the Test button beside it. A publish is queued and
    # retried precisely so nobody waits on the network - but this is somebody
    # who just clicked Save and is looking at the form, and an answer they
    # have to ask for again is worse than a moment's wait.
    socket = socket |> assign_publishing() |> assign(publish_test: nil)

    case Publishing.configured?() and Publishing.check() do
      false ->
        {:noreply,
         put_flash(
           socket,
           :info,
           gettext("Saved. Nothing is published until both an address and a token are set.")
         )}

      {:ok, _message} ->
        {:noreply, put_flash(socket, :info, gettext("Saved, and the results site answered."))}

      {:error, message} ->
        # An :error flash rather than :info: the settings ARE saved, but a
        # green tick over an address that does not answer is the reason
        # somebody discovers this at a tournament instead of now.
        {:noreply,
         socket
         |> assign(publish_test: {:error, message})
         |> put_flash(:error, gettext("Saved, but the results site did not answer."))}
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
      active="fide"
    >
      <h1>{gettext("Connections")}</h1>
      <p class="subtitle">
        {gettext(
          "Everything this machine talks to: the FIDE and Belgian national (KBSB/FRBE) rating lists it looks players up in, and the results site it publishes to."
        )}
      </p>

      <div class="card">
        <h2>{gettext("FIDE database")}</h2>
        <p>
          <.rich_text text={gettext("%[count] players in the local database.")}>
            <:part name="count"><strong>{format_count(@status.player_count)}</strong></:part>
          </.rich_text>
          <%= if @status.last_sync do %>
            <.rich_text text={gettext("Last updated: %[when] (UTC).")}>
              <:part name="when"><strong>{@status.last_sync}</strong></:part>
            </.rich_text>
          <% else %>
            {gettext("The database is empty - download the rating list to get started.")}
          <% end %>
        </p>

        <div :if={busy?(@status)} class="progress-block">
          <div class="progress-track">
            <div
              class={["progress-fill", percent(@status) == nil && "indeterminate"]}
              style={percent(@status) && "width: #{percent(@status)}%"}
            />
          </div>
          <p class="ok-note">
            {if @status.progress != "", do: @status.progress, else: gettext("Working…")}
          </p>
        </div>
        <p :if={@status.status == :error} class="error-note">
          {gettext("Update failed:")} {@status.error}
        </p>

        <p class="hint">
          {gettext(
            "FIDE publishes a new list every month (~1.9 million players, download is around 41 MB). Updating takes a minute or two."
          )}
        </p>
        <p :if={!@sso?} class="hint">
          {gettext(
            "Downloading the full list is limited to SSO-signed-in accounts, so it can't be triggered by just anyone with a local account."
          )}
        </p>
        <div class="actions">
          <button
            class="pe-btn primary"
            phx-click="sync"
            disabled={busy?(@status) or !@sso?}
            title={if !@sso?, do: gettext("Sign in with SSO to update the FIDE rating list")}
          >
            {cond do
              busy?(@status) -> gettext("Updating…")
              @status.player_count > 0 -> gettext("Update from FIDE")
              true -> gettext("Download rating list")
            end}
          </button>
          <button :if={busy?(@status) and @sso?} class="pe-btn" phx-click="cancel">
            {gettext("Cancel")}
          </button>
        </div>
      </div>

      <div class="card">
        <h2>{gettext("Belgian national rating list (KBSB/FRBE)")}</h2>
        <p>
          <.rich_text text={gettext("%[count] players in the local database.")}>
            <:part name="count"><strong>{format_count(@kbsb_status.player_count)}</strong></:part>
          </.rich_text>
          <%= if @kbsb_status.last_sync do %>
            <.rich_text text={gettext("Last updated: %[when] (UTC).")}>
              <:part name="when"><strong>{@kbsb_status.last_sync}</strong></:part>
            </.rich_text>
          <% else %>
            {if @kbsb_api_configured,
              do: gettext("The database is empty - sync it from the data platform to get started."),
              else: gettext("The database is empty - no source is configured.")}
          <% end %>
        </p>

        <p :if={!@kbsb_api_configured} class="hint">
          {gettext(
            "No roster source is configured. Set KBSB_API_URL and KBSB_API_KEY on the server to sync the Belgian roster from the KBSB data platform - see docs/kbsb-sync.md."
          )}
        </p>

        <div :if={@kbsb_api_configured}>
          <p class="hint">
            {gettext(
              "Pulls the current roster from the Odoo-synced database, including each player's club name and number. Replaces the local copy entirely, and can be re-run any time."
            )}
          </p>

          <div :if={busy?(@kbsb_status)} class="progress-block">
            <div class="progress-track">
              <div
                class={["progress-fill", percent(@kbsb_status) == nil && "indeterminate"]}
                style={percent(@kbsb_status) && "width: #{percent(@kbsb_status)}%"}
              />
            </div>
            <p class="ok-note">
              {if @kbsb_status.progress != "", do: @kbsb_status.progress, else: gettext("Working…")}
            </p>
          </div>
          <p :if={@kbsb_status.status == :error} class="error-note">
            {gettext("Sync failed:")} {@kbsb_status.error}
          </p>

          <div class="actions">
            <button
              type="button"
              class="pe-btn primary"
              phx-click="sync_kbsb_api"
              disabled={busy?(@kbsb_status)}
            >
              {if busy?(@kbsb_status),
                do: gettext("Syncing…"),
                else: gettext("Sync from data platform")}
            </button>
            <button :if={busy?(@kbsb_status)} type="button" class="pe-btn" phx-click="cancel_kbsb">
              {gettext("Cancel")}
            </button>
          </div>
        </div>

        <form class="field search-wrap" style="margin-top: 16px" phx-change="kbsb_search">
          <span style="display:block;font-size:13px;font-weight:600;color:var(--text-soft);margin-bottom:4px">
            {gettext("Search the local KBSB database (national ID or last name)")}
          </span>
          <input
            type="text"
            name="q"
            value={@kbsb_query}
            phx-debounce="250"
            autocomplete="off"
            placeholder={gettext("Start typing a last name or matricule…")}
            class="pe-input"
          />
          <div :if={@kbsb_results != []} class="search-results">
            <div :for={kp <- @kbsb_results} class="kbsb-result-row">
              <span>{kp.last_name}{if kp.first_name != "", do: ", #{kp.first_name}"}</span>
              <span class="meta">
                {kp.national_id} · {kp.club_name} · {kp.national_rating || gettext("unrated")}{if kp.fide_id,
                  do: " · FIDE #{kp.fide_id}"}
              </span>
            </div>
          </div>
        </form>
      </div>

      <div class="card">
        <h2>{gettext("Public results site (OpenResults)")}</h2>

        <%!-- Answered before the settings below it, because "is this working"
              is the question somebody arrives on this page with, and reading
              the address back does not answer it. --%>
        <div style="margin-bottom: 14px">
          <.connection_status status={@connection} />
        </div>
        <p>
          {gettext(
            "Where published tournaments are sent so spectators can follow them. This machine stays the source of truth: it sends a copy, and nothing is ever sent back."
          )}
        </p>
        <p>
          {gettext(
            "Set this once for the machine. Each tournament then has its own switch in its Settings, off until you turn it on."
          )}
        </p>

        <form phx-submit="save_publishing">
          <label class="field">
            <span>{gettext("Address")}</span>
            <input
              type="text"
              name="endpoint"
              value={@publish_endpoint}
              placeholder="https://openresults.zerotwo.cloud"
              class="pe-input"
              autocomplete="off"
            />
          </label>

          <label class="field">
            <span>{gettext("Token")}</span>
            <input
              type="password"
              name="token"
              value=""
              placeholder={
                if @publish_token_set?,
                  do: gettext("a token is set - type a new one to replace it"),
                  else: gettext("paste the server's token")
              }
              class="pe-input"
              autocomplete="off"
            />
            <span class="hint" style="display: block">
              {gettext("Never shown once saved. Leave this empty to keep the one already stored.")}
            </span>
          </label>

          <div class="row" style="gap: 8px; margin-top: 12px">
            <button type="submit" class="pe-btn pe-btn-primary">{gettext("Save")}</button>
            <button
              :if={@publish_configured?}
              type="button"
              class="pe-btn"
              phx-click="test_publishing"
            >
              {gettext("Test connection")}
            </button>
            <button
              :if={@publish_token_set?}
              type="button"
              class="pe-btn"
              phx-click="clear_publishing_token"
            >
              {gettext("Remove token")}
            </button>
          </div>
        </form>

        <p :if={@publish_test} class="hint" style="margin-top: 12px">
          <%= case @publish_test do %>
            <% {:ok, message} -> %>
              <strong style="color: var(--color-success)">{message}</strong>
            <% {:error, message} -> %>
              <strong style="color: var(--danger)">{message}</strong>
          <% end %>
        </p>

        <p :if={not @publish_configured?} class="hint" style="margin-top: 12px">
          {gettext("Nothing is published until both an address and a token are set.")}
        </p>

        <p :if={@publish_pending > 0} class="hint" style="margin-top: 12px">
          <.rich_text text={
            gettext(
              "%[count] tournament(s) waiting to be sent. They go out on their own; a tournament stays in the queue until the server confirms it."
            )
          }>
            <:part name="count"><strong>{@publish_pending}</strong></:part>
          </.rich_text>
        </p>
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
