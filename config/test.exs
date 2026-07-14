import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :pbkdf2_elixir, :rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :pairings_engine, PairingsEngine.Repo,
  database:
    Path.expand("../pairings_engine_test#{System.get_env("MIX_TEST_PARTITION")}.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox,
  # SQLite only allows one writer at a time; several async test modules
  # (each on its own sandboxed connection) can legitimately contend for a
  # write lock under ExUnit's default parallelism. The 2000ms adapter
  # default was occasionally too short for that, surfacing as a flaky
  # `Exqlite.Error: Database busy` — give contending writers more time to
  # queue instead of erroring out.
  busy_timeout: 15_000,
  # In the default rollback-journal mode a mere READER blocks every writer,
  # and the SQL Sandbox keeps a transaction open per checked-out connection
  # for the whole test — so one long-lived sandbox read transaction starves
  # unrelated writes past even the generous busy_timeout above. WAL mode
  # lets readers and the single writer coexist, which removes that whole
  # contention class.
  journal_mode: :wal

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :pairings_engine, PairingsEngineWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "pvH767c4NpJA7cEv3gBFslC2O29nDsnCZNvv7fSnGIm7h/wTvwcIc3G7KdCyu4mm",
  server: false

# Disable swoosh api client as it is only required for production adapters.
config :swoosh, :api_client, false

# In test we don't send emails
config :pairings_engine, PairingsEngine.Mailer, adapter: Swoosh.Adapters.Test

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
