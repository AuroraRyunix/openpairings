defmodule PairingsEngineWeb.Router do
  use PairingsEngineWeb, :router

  import PairingsEngineWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PairingsEngineWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    # ...which sets no Content-Security-Policy of its own. See PairingsEngineWeb.CSP.
    plug PairingsEngineWeb.CSP
    # After :fetch_session (it reads and writes the session) and before any
    # rendering, so the very first byte is already in the right language.
    plug PairingsEngineWeb.Plugs.Locale
    # Local mode only, and only for a request that physically came from this
    # machine: establishes the owner's session so there is no login screen on
    # a single-user local install. Inert in every other configuration - see
    # `PairingsEngineWeb.UserAuth.local_owner_session/2`. Before the scope
    # fetch, so the scope it builds is the signed-in one on the first request
    # rather than the one after a redirect.
    plug :local_owner_session
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PairingsEngineWeb do
    pipe_through [:browser, :require_authenticated_user]

    # Support may look at Connections; only an administrator may act on it,
    # which the page's own handlers enforce. Admin is admin throughout.
    live_session :machine_settings,
      on_mount: [
        PairingsEngineWeb.LocaleHook,
        PairingsEngineWeb.DeployNotice,
        PairingsEngineWeb.PublishStatusHook,
        {PairingsEngineWeb.UserAuth, :require_authenticated},
        {PairingsEngineWeb.RequireRole, :support}
      ] do
      live "/fide", FideLive
    end

    live_session :administration,
      on_mount: [
        PairingsEngineWeb.LocaleHook,
        PairingsEngineWeb.DeployNotice,
        PairingsEngineWeb.PublishStatusHook,
        {PairingsEngineWeb.UserAuth, :require_authenticated},
        {PairingsEngineWeb.RequireRole, :admin}
      ] do
      live "/admin", AdminLive
    end
  end

  scope "/", PairingsEngineWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_tournaments,
      on_mount: [
        PairingsEngineWeb.LocaleHook,
        PairingsEngineWeb.DeployNotice,
        PairingsEngineWeb.PublishStatusHook,
        {PairingsEngineWeb.UserAuth, :require_authenticated}
      ] do
      live "/", TournamentsLive
      live "/t/:id/players", PlayersLive
      live "/t/:id/registrations", RegistrationsLive
      live "/t/:id/pairings", PairingsLive
      live "/t/:id/pairings/:round/explain", PairingExplainLive
      live "/t/:id/standings", StandingsLive
      live "/t/:id/history", HistoryLive
      live "/t/:id/audit", AuditLive, :index
      live "/t/:id/audit/explain", AuditLive, :explain
      live "/t/:id/print", PrintLive
      live "/t/:id/settings", SettingsTournamentLive
      live "/t/:id/settings/options", SettingsOptionsLive
      live "/t/:id/settings/results", SettingsResultsLive
      live "/t/:id/settings/scoring", SettingsScoringLive
      live "/t/:id/settings/dates", SettingsDatesLive
      live "/t/:id/settings/extra-points", ExtraPointsLive
      live "/t/:id/settings/fide", SettingsFideLive
      live "/t/:id/settings/about", SettingsAboutLive
      live "/t/:id/settings/export", SettingsExportLive
      live "/t/:id/settings/changelog", SettingsChangelogLive
      live "/t/:id/categories", CategoriesLive
      live "/t/:id/live", LiveRoundLive
      live "/t/:id/norms", NormsLive
      live "/invites/:token", InviteLive
    end

    get "/t/:id/print/players", PrintController, :player_list
    get "/t/:id/print/cards", PrintController, :player_cards
    get "/t/:id/print/card/:player_id", PrintController, :player_card
    get "/t/:id/print/placecards", PrintController, :place_cards
    get "/t/:id/print/pairings", PrintController, :pairing_list
    get "/t/:id/print/pairings-alpha", PrintController, :pairing_alpha
    get "/t/:id/print/standings", PrintController, :standings
    get "/t/:id/print/results", PrintController, :result_cards
    get "/t/:id/print/scoresheets", PrintController, :score_sheets
    get "/t/:id/print/crosstable", PrintController, :crosstable

    get "/t/:id/norms/it3", NormsController, :it3
    get "/t/:id/norms/fa1", NormsController, :fa1
    get "/t/:id/norms/ia1", NormsController, :ia1
    get "/t/:id/norms/it4", NormsController, :it4

    get "/t/:id/export/trf", ExportController, :trf
    get "/t/:id/export/swar", ExportController, :swar
    get "/t/:id/export/swar_html", ExportController, :swar_html
    get "/t/:id/export/pgn", ExportController, :pgn
    get "/t/:id/export/players", ExportController, :players
    get "/t/:id/export/json", ExportController, :json
    get "/export/tournaments.json", ExportController, :all_json

    # POST, not GET, and the only two download routes here that are. Both
    # LOCK the tournament on their way to producing the file - a hand-off is
    # a state change that happens to answer with an attachment - and a GET
    # that locks a tournament would be fired by a link prefetch, a crawler,
    # or a browser restoring tabs. See `PairingsEngine.Handoff`.
    post "/t/:id/export/handoff", ExportController, :hand_off
    post "/t/:id/export/handoff/return", ExportController, :hand_off_return

    # A backup is the whole database - every player, the entry form's email
    # addresses, and every publishing key. SSO-gated inside the controller,
    # exactly as changing the publishing settings is.
    get "/backups/:name", BackupController, :download
  end

  # Other scopes may use custom stacks.
  # scope "/api", PairingsEngineWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:pairings_engine, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PairingsEngineWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Called by the deploy script on the box itself, immediately before it
  # sleeps and then restarts the service, so every open page can warn before
  # its socket drops. Bearer-token authenticated and fails closed when
  # DEPLOY_NOTICE_TOKEN is unset - see PairingsEngineWeb.DeployController.
  scope "/internal", PairingsEngineWeb do
    pipe_through [:api]

    post "/deploy-notice", DeployController, :notice
    post "/deploy-notice/cancel", DeployController, :cancel

    # The plain announcement banner - not a restart, no countdown, and it
    # outlives a restart on purpose. Same token, because it is the same
    # privilege: it can put a banner on every screen.
    post "/notice", DeployController, :announce
    post "/notice/withdraw", DeployController, :withdraw
  end

  # The FIDE list, lent to the results site so its entry form can offer the
  # search this app's own form used to - see FideLookupController for why the
  # publishing token is the right secret and what the rate limit is actually
  # protecting. Under `/internal` because it is one machine asking another,
  # not a page anybody visits.
  scope "/internal", PairingsEngineWeb do
    pipe_through [:api]

    get "/fide/search", FideLookupController, :search
  end

  # Changing language. A controller rather than a LiveView event: the choice
  # lives in the session, and a LiveView holds a socket, not a conn.
  scope "/", PairingsEngineWeb do
    pipe_through [:browser]

    get "/locale/:locale", LocaleController, :update
  end

  ## Authentication routes

  scope "/", PairingsEngineWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [
        PairingsEngineWeb.LocaleHook,
        PairingsEngineWeb.DeployNotice,
        PairingsEngineWeb.PublishStatusHook,
        {PairingsEngineWeb.UserAuth, :require_authenticated}
      ] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email

      # NOT under `/users/settings`, and deliberately not inside
      # `UserLive.Settings`: that LiveView is `require_sudo_mode`, and
      # re-typing a password to tick a checkbox that hides five buttons is a
      # cost with nothing on the other side of it. Ordinary authentication,
      # in the same `live_session` as the rest of the account pages. See
      # `PairingsEngineWeb.UserLive.Features`.
      live "/users/features", UserLive.Features
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", PairingsEngineWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [
        PairingsEngineWeb.LocaleHook,
        PairingsEngineWeb.DeployNotice,
        # A local install signs its one owner in on sight, so these three
        # have nothing to do there and are sent home rather than shown. See
        # the hook's own comment; the links to them are already hidden.
        {PairingsEngineWeb.UserAuth, :reject_in_local_mode}
      ] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    # Neither of these needs the local-mode gate above, and both were left
    # ungated deliberately. The POST is already inert there: the form that
    # reaches it is behind the gate, the only account that exists is the one
    # already signed in, and a second cannot be created because
    # `/users/register` is gated. The DELETE is inert for its own reason -
    # the next request signs the same owner straight back in - and an escape
    # hatch that does nothing is better than one that refuses.
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  # 02cloud SSO (Keycloak, auth.zerotwo.cloud). Plain controller, not a
  # LiveView/live_session - it only ever redirects, so there's no page to
  # keep alive over a socket. See docs/AGENTS.md for the flow.
  scope "/auth/keycloak", PairingsEngineWeb do
    pipe_through [:browser]

    get "/", KeycloakAuthController, :new
    get "/callback", KeycloakAuthController, :callback
  end

  # The public read-only tournament pages this comment used to introduce were
  # removed on 2026-08-29 when publishing moved to OpenResults; the heading
  # outlived its routes. `public_slug` is still the address a tournament is
  # published under, it is just served by the other application now.
  ## The changelog needs no account. It describes the application, not
  # anybody's tournament, and it reads nothing but CHANGELOG.md from the repo
  # - there is no data behind it to protect. It was behind
  # `:require_authenticated_user` only because it was added next to the
  # tournament routes and inherited their pipeline.
  #
  # That became visible when the version number in the top bar was made to
  # link here: that link renders for signed-out visitors too, so it sent them
  # to a log-in screen for a public document.
  #
  # `mount_current_scope` rather than `require_authenticated`: a signed-in
  # arbiter still gets their top bar, an anonymous reader gets the page.
  scope "/", PairingsEngineWeb do
    pipe_through [:browser]

    live_session :public_pages,
      on_mount: [
        PairingsEngineWeb.LocaleHook,
        PairingsEngineWeb.DeployNotice,
        PairingsEngineWeb.PublishStatusHook,
        {PairingsEngineWeb.UserAuth, :mount_current_scope}
      ] do
      live "/changelog", ChangelogLive
    end
  end

  ## Public (no login required) arbiter tools - see docs/tools.md. Upload a
  # SWAR/TRF file, no account needed, and download the IT3/FA1/IA1 FIDE
  # report forms straight from it. Nothing here ever touches the database -
  # parsed files live only in `PairingsEngine.Tools.Session`'s in-memory
  # store, looked up by the `:token` in the download route below.
  scope "/", PairingsEngineWeb do
    pipe_through [:browser]

    get "/tools", ToolsController, :index

    live_session :tools,
      on_mount: [
        PairingsEngineWeb.LocaleHook,
        PairingsEngineWeb.DeployNotice,
        PairingsEngineWeb.PublishStatusHook,
        {PairingsEngineWeb.UserAuth, :mount_current_scope}
      ] do
      live "/tools/norms", ToolsNormsLive
    end

    get "/tools/download/:token/:form", ToolsController, :download
  end

  ## Mobile no-account result entry - see PairingsEngine.Mobile. An arbiter
  # generates a QR + numeric code from a tournament; a helper's phone enrolls
  # here (no account) and gets a result-entry-only session for that tournament.
  scope "/m", PairingsEngineWeb do
    pipe_through :browser

    get "/", MobileEnrollController, :new
    post "/", MobileEnrollController, :submit
    get "/e/:token", MobileEnrollController, :enroll
    get "/leave", MobileEnrollController, :leave

    live_session :mobile_results,
      on_mount: [
        PairingsEngineWeb.EnglishHook,
        PairingsEngineWeb.DeployNotice,
        {PairingsEngineWeb.MobileAuth, :require_enrollment}
      ] do
      live "/results", MobileResultsLive
    end
  end
end
