defmodule PairingsEngineWeb.FideLive do
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Accounts.User
  alias PairingsEngine.Kbsb
  alias PairingsEngine.Fide.Sync, as: FideSync
  alias PairingsEngine.Kbsb.Sync, as: KbsbSync
  alias PairingsEngine.Kbsb.Api, as: KbsbApi

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, FideSync.topic())
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, KbsbSync.topic())
    end

    {:ok,
     socket
     |> assign(
       page_title: "Rating lists",
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
     )}
  end

  @impl true
  def handle_info({:fide_sync, _state}, socket) do
    {:noreply, assign(socket, status: FideSync.status())}
  end

  def handle_info({:kbsb_sync, _state}, socket) do
    {:noreply, assign(socket, kbsb_status: KbsbSync.status())}
  end

  @impl true
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active="fide">
      <h1>{gettext("Rating lists")}</h1>
      <p class="subtitle">
        {gettext(
          "Local copies of the FIDE and Belgian national (KBSB/FRBE) rating lists, used to look up players when registering them."
        )}
      </p>

      <div class="card">
        <h2>{gettext("FIDE database")}</h2>
        <p>
          <strong>{format_count(@status.player_count)}</strong>
          players in the local database.
          <%= if @status.last_sync do %>
            {gettext("Last updated:")} <strong>{@status.last_sync}</strong> (UTC).
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
          <p class="ok-note">{if @status.progress != "", do: @status.progress, else: "Working…"}</p>
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
            title={if !@sso?, do: "Sign in with SSO to update the FIDE rating list"}
          >
            {cond do
              busy?(@status) -> "Updating…"
              @status.player_count > 0 -> "Update from FIDE"
              true -> "Download rating list"
            end}
          </button>
          <button :if={busy?(@status) and @sso?} class="pe-btn" phx-click="cancel">
            Cancel
          </button>
        </div>
      </div>

      <div class="card">
        <h2>{gettext("Belgian national rating list (KBSB/FRBE)")}</h2>
        <p>
          <strong>{format_count(@kbsb_status.player_count)}</strong>
          players in the local database.
          <%= if @kbsb_status.last_sync do %>
            {gettext("Last updated:")} <strong>{@kbsb_status.last_sync}</strong> (UTC).
          <% else %>
            The database is empty - {if @kbsb_api_configured,
              do: "sync it from the data platform to get started.",
              else: "no source is configured."}
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
              {if @kbsb_status.progress != "", do: @kbsb_status.progress, else: "Working…"}
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
              {if busy?(@kbsb_status), do: "Syncing…", else: "Sync from data platform"}
            </button>
            <button :if={busy?(@kbsb_status)} type="button" class="pe-btn" phx-click="cancel_kbsb">
              Cancel
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
                {kp.national_id} · {kp.club_name} · {kp.national_rating || "unrated"}{if kp.fide_id,
                  do: " · FIDE #{kp.fide_id}"}
              </span>
            </div>
          </div>
        </form>
      </div>
    </Layouts.app>
    """
  end
end
