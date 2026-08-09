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
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PairingsEngineWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_tournaments,
      on_mount: [{PairingsEngineWeb.UserAuth, :require_authenticated}] do
      live "/", TournamentsLive
      live "/fide", FideLive
      live "/t/:id/players", PlayersLive
      live "/t/:id/pairings", PairingsLive
      live "/t/:id/pairings/:round/explain", PairingExplainLive
      live "/t/:id/standings", StandingsLive
      live "/t/:id/audit", AuditLive, :index
      live "/t/:id/audit/explain", AuditLive, :explain
      live "/t/:id/print", PrintLive
      live "/t/:id/settings", SettingsTournamentLive
      live "/t/:id/settings/options", SettingsOptionsLive
      live "/t/:id/settings/dates", SettingsDatesLive
      live "/t/:id/settings/extra-points", ExtraPointsLive
      live "/t/:id/settings/fide", SettingsFideLive
      live "/t/:id/categories", CategoriesLive
      live "/t/:id/live", LiveRoundLive
      live "/t/:id/norms", NormsLive
      live "/invites/:token", InviteLive
    end

    get "/t/:id/print/players", PrintController, :player_list
    get "/t/:id/print/cards", PrintController, :player_cards
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

  ## Authentication routes

  scope "/", PairingsEngineWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{PairingsEngineWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", PairingsEngineWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{PairingsEngineWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  # 02cloud SSO (Keycloak, auth.zerotwo.cloud). Plain controller, not a
  # LiveView/live_session — it only ever redirects, so there's no page to
  # keep alive over a socket. See docs/AGENTS.md for the flow.
  scope "/auth/keycloak", PairingsEngineWeb do
    pipe_through [:browser]

    get "/", KeycloakAuthController, :new
    get "/callback", KeycloakAuthController, :callback
  end

  ## Public (no login required) read-only tournament pages — see docs/public-pages.md.
  # Reachable via a tournament's unguessable `public_slug`, not its numeric
  # id. No `:require_authenticated_user` — deliberately public.
  scope "/", PairingsEngineWeb do
    pipe_through [:browser]

    live_session :public_tournament_pages,
      on_mount: [{PairingsEngineWeb.UserAuth, :mount_current_scope}] do
      live "/p/:slug/pairings", PublicPairingsLive
      live "/p/:slug/standings", PublicStandingsLive
      # The only public page that WRITES. Gated a second time on
      # `registration_open` inside the LiveView and again inside
      # `Tournaments.register_public_player/2`, so reaching this route is
      # not by itself permission to enter.
      live "/p/:slug/register", PublicRegisterLive
    end
  end

  ## Public (no login required) arbiter tools — see docs/tools.md. Upload a
  # SWAR/TRF file, no account needed, and download the IT3/FA1/IA1 FIDE
  # report forms straight from it. Nothing here ever touches the database —
  # parsed files live only in `PairingsEngine.Tools.Session`'s in-memory
  # store, looked up by the `:token` in the download route below.
  scope "/", PairingsEngineWeb do
    pipe_through [:browser]

    get "/tools", ToolsController, :index

    live_session :tools,
      on_mount: [{PairingsEngineWeb.UserAuth, :mount_current_scope}] do
      live "/tools/norms", ToolsNormsLive
    end

    get "/tools/download/:token/:form", ToolsController, :download
  end

  ## Mobile no-account result entry — see PairingsEngine.Mobile. An arbiter
  # generates a QR + numeric code from a tournament; a helper's phone enrolls
  # here (no account) and gets a result-entry-only session for that tournament.
  scope "/m", PairingsEngineWeb do
    pipe_through :browser

    get "/", MobileEnrollController, :new
    post "/", MobileEnrollController, :submit
    get "/e/:token", MobileEnrollController, :enroll
    get "/leave", MobileEnrollController, :leave

    live_session :mobile_results,
      on_mount: [{PairingsEngineWeb.MobileAuth, :require_enrollment}] do
      live "/results", MobileResultsLive
    end
  end
end
