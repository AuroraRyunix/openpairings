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
      live "/t/:id/standings", StandingsLive
      live "/t/:id/print", PrintLive
      live "/t/:id/settings", SettingsLive
    end

    get "/t/:id/print/players", PrintController, :player_list
    get "/t/:id/print/cards", PrintController, :player_cards
    get "/t/:id/print/pairings", PrintController, :pairing_list
    get "/t/:id/print/standings", PrintController, :standings
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
end
