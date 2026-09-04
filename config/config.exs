# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :pairings_engine, :scopes,
  user: [
    default: true,
    module: PairingsEngine.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: PairingsEngine.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :pairings_engine,
  ecto_repos: [PairingsEngine.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :pairings_engine, PairingsEngineWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PairingsEngineWeb.ErrorHTML, json: PairingsEngineWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: PairingsEngine.PubSub,
  live_view: [signing_salt: "cZX+zVhI"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  pairings_engine: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  pairings_engine: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Where PairingsEngine.Federations.BEL.SwarUpload PUTs a generated SWAR
# results page (step 1) and where it asks the federation to index what it
# just staged (step 2). Fixed for every installation - the Belgian
# federation runs exactly one results site - so this lives in plain config
# rather than in the `meta` table PairingsEngine.Publishing.endpoint/0
# reads, which exists specifically because THAT address varies per
# installation.
config :pairings_engine, :bel_swar_upload,
  upload_url: "https://frbe-kbsb.be/sites/manager/Swar/apiTournamentUpload.php",
  index_url: "https://frbe-kbsb.be/sites/manager/Swar/SwarTournamentUpload.php"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

config :phoenix_live_view, :colocated_assets, disable_symlink_warning: true
