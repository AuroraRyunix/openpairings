defmodule PairingsEngineWeb.Router do
  use PairingsEngineWeb, :router

  import PairingsEngineWeb.UserAuth
  import PairingsEngineWeb.CSP, only: [allow_framing: 2]

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

  # Runs AFTER `:browser`, and re-opens `frame-ancestors` for the routes
  # that are safe to put in someone else's page. Nothing else about the
  # policy changes -- see `PairingsEngineWeb.CSP`'s "Framing" section for
  # which routes qualify and why the rest must not.
  pipeline :embeddable do
    plug :allow_framing
  end

  scope "/", PairingsEngineWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_tournaments,
      on_mount: [
        PairingsEngineWeb.LocaleHook,
        PairingsEngineWeb.DeployNotice,
        {PairingsEngineWeb.UserAuth, :require_authenticated}
      ] do
      live "/", TournamentsLive
      live "/fide", FideLive
      live "/changelog", ChangelogLive
      live "/t/:id/players", PlayersLive
      live "/t/:id/pairings", PairingsLive
      live "/t/:id/pairings/:round/explain", PairingExplainLive
      live "/t/:id/standings", StandingsLive
      live "/t/:id/history", HistoryLive
      live "/t/:id/audit", AuditLive, :index
      live "/t/:id/audit/explain", AuditLive, :explain
      live "/t/:id/print", PrintLive
      live "/t/:id/settings", SettingsTournamentLive
      live "/t/:id/settings/options", SettingsOptionsLive
      live "/t/:id/settings/scoring", SettingsScoringLive
      live "/t/:id/settings/dates", SettingsDatesLive
      live "/t/:id/settings/extra-points", ExtraPointsLive
      live "/t/:id/settings/fide", SettingsFideLive
      live "/t/:id/settings/about", SettingsAboutLive
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
    get "/t/:id/export/pgn", ExportController, :pgn
    get "/t/:id/export/json", ExportController, :json
    get "/export/tournaments.json", ExportController, :all_json
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
        {PairingsEngineWeb.UserAuth, :require_authenticated}
      ] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", PairingsEngineWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [
        PairingsEngineWeb.LocaleHook,
        PairingsEngineWeb.DeployNotice,
        {PairingsEngineWeb.UserAuth, :mount_current_scope}
      ] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

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

  ## Public (no login required) read-only tournament pages - see docs/public-pages.md.
  # Reachable via a tournament's unguessable `public_slug`, not its numeric
  # id. No `:require_authenticated_user` - deliberately public.
  # Read-only, and embeddable: a club site can iframe the pairing list or
  # the standings. They stay in ONE `live_session` because they link to
  # each other with `<.link navigate>`, which only stays a live navigation
  # inside a session.
  scope "/", PairingsEngineWeb do
    pipe_through [:browser, :embeddable]

    live_session :public_tournament_pages,
      on_mount: [
        PairingsEngineWeb.EnglishHook,
        PairingsEngineWeb.DeployNotice,
        {PairingsEngineWeb.UserAuth, :mount_current_scope}
      ] do
      live "/p/:slug/pairings", PublicPairingsLive
      live "/p/:slug/standings", PublicStandingsLive
    end
  end

  # The only public page that WRITES, and embeddable since 2026-08-22 - a
  # club wants the entry form on its own site, not a link away from it.
  #
  # It was excluded on the rule "no forms in a third-party frame", which is
  # the right default and the wrong call here. Clickjacking steals AUTHORITY
  # the victim already holds: an invisible frame, a stray click, and
  # something happens as them. This form holds none. It needs a name, a
  # birth year and a federation TYPED IN, it runs under an anonymous scope,
  # and it grants a framing page nothing it could not do by fetching the
  # same URL itself. What a visitor types goes to this server either way,
  # so framing cannot harvest it.
  #
  # What stops abuse is unchanged, and none of it is the frame policy:
  # `registration_open` is checked in the LiveView and again in
  # `Tournaments.register_public_player/2`, and `RateLimit.allow?` caps
  # entries per IP. Reaching this route was never permission to enter.
  scope "/", PairingsEngineWeb do
    pipe_through [:browser, :embeddable]

    live_session :public_registration,
      on_mount: [
        PairingsEngineWeb.EnglishHook,
        PairingsEngineWeb.DeployNotice,
        {PairingsEngineWeb.UserAuth, :mount_current_scope}
      ] do
      live "/p/:slug/register", PublicRegisterLive
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
