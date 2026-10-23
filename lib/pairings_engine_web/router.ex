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
    # After the scope, which it reads: a language stored on the signed-in
    # account wins over the session's. Inert for an account without one.
    plug PairingsEngineWeb.Plugs.AccountLocale
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Manubrium's queue (`MobileAppController.sync/2`): JSON in and out, but a
  # write made from a page with a session, so it gets the session and the
  # CSRF check a form post gets - not `:api`'s bare pipe. English, like the
  # rest of `/m`: the answers are sentences the phone shows. The answer is
  # JSON and never a document, so its policy allows nothing at all.
  pipeline :mobile_sync do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" => "default-src 'none'; frame-ancestors 'none'"
    }

    plug PairingsEngineWeb.Plugs.English
  end

  # The Manubrium app's API (`/api/manubrium/v1`, docs/manubrium.md "Full
  # app"): JSON in and out, a bearer token and nothing else - no session,
  # no cookie, no CSRF token, because nothing here is a browser. English,
  # like the hall pages: the refusals are sentences the phone shows.
  pipeline :manubrium_api do
    plug :accepts, ["json"]

    plug :put_secure_browser_headers, %{
      "content-security-policy" => "default-src 'none'; frame-ancestors 'none'"
    }

    plug PairingsEngineWeb.Plugs.English
  end

  # The bearer check, rate limits included. In its own pipeline so a route
  # cannot be added to the scope below without it.
  pipeline :manubrium_device do
    plug PairingsEngineWeb.ManubriumApi.Auth
  end

  # Marks a response as one of Manubrium's pages, so the root layout links
  # the manifest and registers the service worker there and nowhere else.
  pipeline :manubrium do
    plug :put_manubrium
  end

  # Player-facing controller pages, after `:browser`: English for this request
  # whatever `Plugs.Locale` resolved, without touching the session it wrote.
  # The controller-side twin of `EnglishHook` - see `Plugs.English`.
  pipeline :english do
    plug PairingsEngineWeb.Plugs.English
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
        PairingsEngineWeb.UpdateNotice,
        PairingsEngineWeb.FideDownloadNotice,
        {PairingsEngineWeb.UserAuth, :require_authenticated},
        {PairingsEngineWeb.RequireRole, :support}
      ] do
      live "/fide", FideLive
      live "/rating-lists", RatingListsLive
    end

    live_session :administration,
      on_mount: [
        PairingsEngineWeb.LocaleHook,
        PairingsEngineWeb.DeployNotice,
        PairingsEngineWeb.PublishStatusHook,
        PairingsEngineWeb.UpdateNotice,
        PairingsEngineWeb.FideDownloadNotice,
        {PairingsEngineWeb.UserAuth, :require_authenticated},
        {PairingsEngineWeb.RequireRole, :admin}
      ] do
      live "/admin", AdminLive
      live "/admin/rating-inbox", RatingInboxLive
    end
  end

  scope "/", PairingsEngineWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_tournaments,
      on_mount: [
        PairingsEngineWeb.LocaleHook,
        PairingsEngineWeb.DeployNotice,
        PairingsEngineWeb.PublishStatusHook,
        PairingsEngineWeb.UpdateNotice,
        PairingsEngineWeb.FideDownloadNotice,
        PairingsEngineWeb.EnrollmentRevokedHook,
        {PairingsEngineWeb.UserAuth, :require_authenticated}
      ] do
      live "/", TournamentsLive
      live "/t/:id/players", PlayersLive
      live "/t/:id/teams", TeamsLive
      live "/t/:id/registrations", RegistrationsLive
      live "/t/:id/pairings", PairingsLive
      live "/t/:id/postponed", PostponedLive
      live "/t/:id/incidents", IncidentsLive
      live "/t/:id/pairings/:round/explain", PairingExplainLive
      live "/t/:id/pairings/:round/matches/:match", MatchLive
      live "/t/:id/standings", StandingsLive

      # The team tables beside Standings (cross table, match sheets, rosters,
      # board prizes): read-only views of a team event, so they sit with
      # Standings in the signed-in session. A tournament that is not paired as
      # teams is sent back to Standings by the LiveView.
      live "/t/:id/team-sheets", TeamSheetsLive, :cross_table
      live "/t/:id/team-sheets/match-sheets", TeamSheetsLive, :match_sheets
      live "/t/:id/team-sheets/rosters", TeamSheetsLive, :rosters
      live "/t/:id/team-sheets/board-prizes", TeamSheetsLive, :board_prizes
      live "/t/:id/history", HistoryLive
      live "/t/:id/audit", AuditLive, :index
      live "/t/:id/audit/explain", AuditLive, :explain
      live "/t/:id/print", PrintLive
      live "/t/:id/settings", SettingsTournamentLive
      live "/t/:id/settings/group", SettingsGroupLive
      live "/t/:id/settings/options", SettingsOptionsLive
      live "/t/:id/settings/restrictions", SettingsRestrictionsLive
      live "/t/:id/settings/results", SettingsResultsLive
      live "/t/:id/settings/boards", SettingsBoardsLive
      live "/t/:id/games/:game", BoardGameLive
      live "/t/:id/settings/scoring", SettingsScoringLive
      live "/t/:id/settings/dates", SettingsDatesLive
      live "/t/:id/settings/rooms", SettingsRoomsLive
      live "/t/:id/settings/extra-points", ExtraPointsLive
      live "/t/:id/settings/fide", SettingsFideLive
      live "/t/:id/settings/norms", SettingsNormsLive
      live "/t/:id/settings/about", SettingsAboutLive
      live "/t/:id/settings/export", SettingsExportLive
      live "/t/:id/settings/changelog", SettingsChangelogLive
      live "/t/:id/categories", CategoriesLive
      live "/t/:id/live", LiveRoundLive
      live "/t/:id/norms", NormsLive
      live "/invites/:token", InviteLive

      # Accreditation badges (docs/badges.md). Signed-in only, and in this
      # live_session rather than `:require_authenticated_user` because an event
      # imports from a tournament and the two link to each other: sharing the
      # session keeps that a live navigation instead of a full page load. The
      # user is always signed in on a local install, so it works there too.
      live "/badges", BadgeEventsLive, :index
      live "/badges/:id", BadgeStudioLive, :index
      live "/badges/:id/settings", BadgeStudioLive, :settings
      live "/badges/:id/badge/:badge_id", BadgeStudioLive, :edit
    end

    get "/badges/:id/print", BadgeController, :print
    get "/badges/:id/photo/:badge_id", BadgeController, :photo
    get "/badges/:id/logo/:slot", BadgeController, :logo
    get "/t/:id/badges", BadgeController, :for_tournament

    get "/t/:id/print/players", PrintController, :player_list
    get "/t/:id/print/cards", PrintController, :player_cards
    get "/t/:id/print/card/:player_id", PrintController, :player_card
    get "/t/:id/print/placecards", PrintController, :place_cards
    get "/t/:id/print/pairings", PrintController, :pairing_list
    get "/t/:id/print/pairings-alpha", PrintController, :pairing_alpha
    get "/t/:id/print/next-round-preview", PrintController, :next_round_preview
    get "/t/:id/print/standings", PrintController, :standings
    get "/t/:id/print/results", PrintController, :result_cards
    get "/t/:id/print/scoresheets", PrintController, :score_sheets
    get "/t/:id/print/crosstable", PrintController, :crosstable
    get "/t/:id/print/team-pairings", PrintController, :team_pairings
    get "/t/:id/print/team-standings", PrintController, :team_standings
    get "/t/:id/print/team-crosstable", TeamPrintController, :cross_table
    get "/t/:id/print/team-match-sheets", TeamPrintController, :match_sheets
    get "/t/:id/print/team-rosters", TeamPrintController, :rosters
    get "/t/:id/print/board-prizes", TeamPrintController, :board_prizes
    get "/t/:id/print/postponed", PrintController, :postponed_notices
    get "/t/:id/print/schedule", SchedulePrintController, :schedule
    get "/t/:id/print/team-schedule", SchedulePrintController, :team_schedule
    get "/t/:id/print/team-cards", SchedulePrintController, :team_cards

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
    get "/t/:id/export/postponed/:pairing_id/calendar", ExportController, :postponed_calendar
    get "/t/:id/export/receipts/:receipt_id/json", ExportController, :receipt_json
    get "/export/tournaments.json", ExportController, :all_json

    # POST, not GET, and the only two download routes here that are. Both
    # LOCK the tournament on their way to producing the file - a hand-off is
    # a state change that happens to answer with an attachment - and a GET
    # that locks a tournament would be fired by a link prefetch, a crawler,
    # or a browser restoring tabs. See `PairingsEngine.Handoff`.
    post "/t/:id/export/handoff", ExportController, :hand_off
    post "/t/:id/export/handoff/return", ExportController, :hand_off_return

    # The same, for the TRF "for sending": with its "finalise results for TRF
    # sending" box ticked it marks every exported result as sent, and a
    # link prefetch must not be able to do that. The plain GET export above
    # stays exactly as it was.
    post "/t/:id/export/trf", ExportController, :trf_send
    get "/t/:id/export/postponed-trf", ExportController, :postponed_trf
    post "/t/:id/export/postponed-trf", ExportController, :postponed_trf_send

    # A backup is the whole database - every player, the entry form's email
    # addresses, and every publishing key. SSO-gated inside the controller,
    # exactly as changing the publishing settings is.
    get "/backups/:name", BackupController, :download

    # The rating period inbox's TRF copy of a sent round; admin-gated in the
    # controller, like the backup above (the page itself is in
    # the administration session).
    get "/admin/rating-inbox/receipts/:id/trf", RatingInboxController, :trf
  end

  ## Plugin pages (see `PairingsEngine.Plugin`). Only in a build that compiles
  # a plugin in - the hosted edition. Everywhere else `plugin_routes` is empty
  # and none of this exists: no scope, no live_session, no route.
  #
  # Signed in, with the same on_mount hooks as the tournament pages, because a
  # plugin's pages are tournament work (a league series is a team
  # tournament); each page enforces any narrower right itself, the way
  # `PairingsEngineWeb.MatchLive` does. Its own live_session rather than
  # `:require_authenticated_tournaments`: live_session names are unique, and
  # that block is aliased to `PairingsEngineWeb`, which would prefix a
  # plugin's module names. The price is a full page load between a plugin's
  # pages and the core's, which is the right side of the trade.
  #
  # Every path is under `/p/<plugin id>`, so a plugin cannot shadow a core
  # route.
  plugin_routes = PairingsEngine.Plugins.routes()

  if plugin_routes != [] do
    scope "/" do
      pipe_through [:browser, :require_authenticated_user]

      live_session :plugins,
        on_mount: [
          PairingsEngineWeb.LocaleHook,
          PairingsEngineWeb.DeployNotice,
          PairingsEngineWeb.PublishStatusHook,
          PairingsEngineWeb.UpdateNotice,
          PairingsEngineWeb.FideDownloadNotice,
          {PairingsEngineWeb.UserAuth, :require_authenticated},
          # Plug-ins are for administrators only (the menu, the overview and
          # every plugin page): an arbiter without the role is sent home.
          {PairingsEngineWeb.RequireRole, :admin}
        ] do
        for {path, live_module, action} <- plugin_routes do
          live path, live_module, action
        end
      end
    end
  end

  # A plugin's plain plugs (`http_routes/0`): no pipeline at all, because
  # their callers are programs - a print station, a hall announcer - which
  # keep neither cookies nor CSRF tokens. Under `/p/<id>` like the pages, so
  # they cannot shadow a core route either; and the plugin, not this file,
  # decides who gets an answer.
  for {verb, path, plug, plug_opts} <- PairingsEngine.Plugins.http_routes() do
    match verb, path, plug, plug_opts
  end

  # The public pages that left for the results site on 2026-08-29. Their old
  # links forward there instead of dying; after the plug-in routes, so a
  # plug-in's own `/p/<id>/...` always wins. See `OldPublicPageController`.
  for page <- ~w(pairings standings register) do
    get "/p/:slug/#{page}", PairingsEngineWeb.OldPublicPageController, :show,
      private: %{old_page: page}
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

  # The board link: a box in the playing hall asking who sits where and
  # reporting what its boards saw (`PairingsEngine.BoardLink`,
  # docs/board-link-api.md). The `:api` pipeline and nothing else - no
  # session, no CSRF token, because nothing here is a browser. The bearer
  # secret and both rate limits are in the controller's own plug, so a route
  # added to this scope cannot be added without them.
  #
  # Core, not a plug-in: the desktop edition speaks it too - to a box on the
  # same PC through this router, and to a box elsewhere in the hall through
  # `PairingsEngineWeb.BoardLan.Router`, which has these four routes and no
  # others. A route added here must be added there, or a network box does
  # not get it; `PairingsEngineWeb.BoardLanTest` compares the two.
  scope "/api/boards/v1", PairingsEngineWeb do
    pipe_through [:api]

    get "/link", BoardLinkController, :link
    post "/box", BoardLinkController, :box
    get "/tournaments/:id", BoardLinkController, :tournament
    post "/tournaments/:id/games", BoardLinkController, :games
  end

  # Manubrium, the full app: a phone runs a tournament through these. The
  # connect trade is the one route without a token - the one-time connect
  # code it carries is the credential, and refused ones are rate limited by
  # address in `PairingsEngine.Manubrium.redeem/3`. Everything else carries
  # the device token (`:manubrium_device`). On a desktop copy the phones'
  # network listener (`PairingsEngineWeb.PhoneLan`) serves these too.
  scope "/api/manubrium/v1", PairingsEngineWeb.ManubriumApi do
    pipe_through [:manubrium_api]

    post "/connect", AccountController, :connect
  end

  scope "/api/manubrium/v1", PairingsEngineWeb.ManubriumApi do
    pipe_through [:manubrium_api, :manubrium_device]

    get "/me", AccountController, :me
    delete "/me", AccountController, :sign_out

    get "/tournament-options", TournamentController, :options
    get "/tournaments", TournamentController, :index
    post "/tournaments", TournamentController, :create
    get "/tournaments/:id", TournamentController, :show
    get "/tournaments/:id/standings", TournamentController, :standings
    get "/tournaments/:id/incidents", TournamentController, :incidents
    post "/tournaments/:id/sync", TournamentController, :sync
    post "/tournaments/:id/rounds", TournamentController, :pair
    get "/tournaments/:id/rounds/:number", TournamentController, :round
    delete "/tournaments/:id/rounds/:number", TournamentController, :unpair
    put "/tournaments/:id/rounds/:number/publish", TournamentController, :publish

    post "/tournaments/:id/rounds/:number/boards/:pairing_id/clear",
         TournamentController,
         :clear

    # A Lite phone's result: the arbiter's word on it.
    post "/tournaments/:id/rounds/:number/boards/:pairing_id/confirm",
         RoundEditController,
         :confirm

    post "/tournaments/:id/rounds/:number/boards/:pairing_id/reject",
         RoundEditController,
         :reject

    # Hand edits to a paired round, and finishing them.
    post "/tournaments/:id/rounds/:number/edits", RoundEditController, :edit
    post "/tournaments/:id/rounds/:number/edits/finish", RoundEditController, :finish
    post "/tournaments/:id/rounds/:number/edits/discard", RoundEditController, :discard

    patch "/tournaments/:id/settings", SettingsController, :update

    patch "/tournaments/:id/incidents/:incident_id", IncidentController, :update
    delete "/tournaments/:id/incidents/:incident_id", IncidentController, :delete
    post "/tournaments/:id/incidents/:incident_id/photo", IncidentController, :attach_photo
    get "/tournaments/:id/incidents/:incident_id/photo", IncidentController, :photo

    get "/tournaments/:id/players", PlayerController, :index
    get "/tournaments/:id/player-search", PlayerController, :search
    post "/tournaments/:id/players", PlayerController, :create
    patch "/tournaments/:id/players/:player_id", PlayerController, :update
    put "/tournaments/:id/players/:player_id/byes", PlayerController, :byes

    # The hall boxes' connect codes (Alnasl).
    get "/tournaments/:id/board-links", BoardLinkController, :index
    post "/tournaments/:id/board-links", BoardLinkController, :create
    delete "/tournaments/:id/board-links/:link_id", BoardLinkController, :delete
  end

  # Trading a grant for an account code (`BoardConnectController.grant/2`).
  # Its own scope, outside the four above: it is not a request a code makes
  # - the grant is the credential, and the controller checks it and rate
  # limits it - and it is deliberately NOT on the desktop copy's network
  # listener, whose router mirrors the scope above and nothing else. An
  # account code is for this listener only, as every non-network code is.
  scope "/api/boards/v1", PairingsEngineWeb do
    pipe_through [:api]

    post "/grant", BoardConnectController, :grant
  end

  # The consent page of that flow: a box sends the arbiter's browser here to
  # ask for an account code. `:require_authenticated_user` because it hands
  # out a credential for everything the account may edit: somebody signed
  # out is sent to sign in and brought back to this very address, query
  # string and all. Controller routes rather than a LiveView, because "Allow"
  # must end in a redirect to another site with a CSP widened for that one
  # page (`CSP.allow_form_action/2`), which a socket cannot do. `:browser`
  # brings the CSRF token the two buttons post with.
  scope "/boards", PairingsEngineWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/connect", BoardConnectController, :new
    post "/connect", BoardConnectController, :create
  end

  # An incident's photo, for the desk's incidents page: signed in, and the
  # controller asks `get_authorized_tournament/2` like every desk page -
  # so not an arbiter, not a phone, and never a public page.
  scope "/t", PairingsEngineWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/:id/incidents/:incident_id/photo", IncidentPhotoController, :show
  end

  # Installed theme packs' stylesheets and fonts (`PairingsEngine.ThemePacks`).
  # No pipeline: they are files, the sign-in page needs them as much as any
  # other, and a session would change nothing about what is served. The
  # controller's whitelist is the whole of the access control.
  scope "/themes", PairingsEngineWeb do
    get "/:id/theme.css", ThemePackController, :css
    get "/:id/fonts/:file", ThemePackController, :font
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
        PairingsEngineWeb.UpdateNotice,
        PairingsEngineWeb.FideDownloadNotice,
        {PairingsEngineWeb.UserAuth, :require_authenticated}
      ] do
      # The account page. Ordinary authentication for the page itself: the
      # preferences, defaults and federation switches on it cannot lock
      # anybody out, so they do not make anyone re-type a password. The
      # sections that can - address, password, sessions, the download, and
      # deleting the account - each check a recent sign-in themselves, in
      # the page's handlers and again in `AccountController`. See
      # `PairingsEngineWeb.UserLive.Settings`.
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email

      # The federation switches used to be their own page here. They are a
      # section of the account page now; this address still works (the
      # account menu links it on a local install) and opens the page at
      # that section.
      live "/users/features", UserLive.Settings, :features
    end

    post "/users/update-password", UserSessionController, :update_password

    # The account page's download and its delete - both need a conn, see
    # `PairingsEngineWeb.AccountController`. The download is a GET because it
    # changes nothing; deleting is a POST with the typed confirmation.
    get "/users/settings/export", AccountController, :export
    post "/users/settings/delete", AccountController, :delete
  end

  # The top-bar theme and accent pickers writing through to the account.
  # `:browser` only, not `:require_authenticated_user`: it is a background
  # call from a picker, and that plug would answer a signed-out one with a
  # redirect and a flash left waiting for the next page. The controller
  # ignores anything it will not act on. See `AccountController.appearance/2`.
  scope "/", PairingsEngineWeb do
    pipe_through [:browser]

    post "/users/preferences/appearance", AccountController, :appearance
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
  ## The changelog and the manual (`/help`) need no account. They describe the application, not
  # anybody's tournament, and they read nothing but CHANGELOG.md and priv/manual from the repo
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
        PairingsEngineWeb.UpdateNotice,
        PairingsEngineWeb.FideDownloadNotice,
        {PairingsEngineWeb.UserAuth, :mount_current_scope}
      ] do
      live "/changelog", ChangelogLive
      live "/help", HelpLive
      live "/help/other/:program", HelpLive
      live "/help/other/:program/:page", HelpLive
      live "/help/:chapter", HelpLive
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
        PairingsEngineWeb.UpdateNotice,
        PairingsEngineWeb.FideDownloadNotice,
        {PairingsEngineWeb.UserAuth, :mount_current_scope}
      ] do
      live "/tools/norms", ToolsNormsLive
    end

    get "/tools/download/:token/:form", ToolsController, :download
  end

  ## Mobile no-account result entry - see PairingsEngine.Mobile. An arbiter
  # generates a QR + numeric code from a tournament; a helper's phone enrolls
  # here (no account) and gets a result-entry-only session for that tournament.
  #
  # English throughout, like the result entry it leads to: `:english` pins the
  # controller routes, `EnglishHook` the live_session.
  #
  # Manubrium Lite, the same pages surviving a wifi drop (docs/manubrium.md):
  # the service worker is the same for everybody and needs no session; the
  # queue is a write and gets the session and CSRF check. No manifest: Lite
  # is a browser page, not something to install.
  scope "/m", PairingsEngineWeb do
    get "/sw.js", MobileAppController, :service_worker
  end

  scope "/m", PairingsEngineWeb do
    pipe_through [:mobile_sync]

    post "/sync", MobileAppController, :sync
  end

  scope "/m", PairingsEngineWeb do
    pipe_through [:browser, :english, :manubrium]

    get "/", MobileEnrollController, :new
    post "/", MobileEnrollController, :submit
    get "/e/:token", MobileEnrollController, :enroll
    post "/e/:token", MobileEnrollController, :redeem
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

  # An arbiter's own phone, signed in to their account: `require_authenticated_user`
  # because the code made here is bound to that account (what it enters is
  # audited under it). Kept out of the phones' LAN listener's path list - a
  # desktop copy has no accounts but its owner, who signs in on loopback only.
  scope "/m", PairingsEngineWeb do
    pipe_through [:browser, :english, :manubrium, :require_authenticated_user]

    get "/connect", MobileConnectController, :index
    post "/connect/:id", MobileConnectController, :here
    post "/connect/:id/code", MobileConnectController, :code
  end

  defp put_manubrium(conn, _opts), do: Plug.Conn.assign(conn, :manubrium, true)
end
