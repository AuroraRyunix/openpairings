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
  # One connection, so the pool cannot contend with itself. SQLite allows a
  # single writer per database, and the sandbox holds an open transaction on
  # every checked-out connection for the length of its test, so several
  # connections plus ExUnit's parallelism meant tests genuinely raced for the
  # write lock. That surfaced as `Exqlite.Error: Database busy` raised from
  # an unrelated test's setup - reliably 1-5 tests per full run by the end,
  # nearly always in the Settings LiveView files, because a LiveView
  # receiving a late PubSub broadcast at teardown kept its connection busy
  # into the next test's checkout. Neither of the two settings below fixed
  # that (the error arrives instantly, long before any timeout could expire);
  # serialising the pool did, 8 clean full runs against a baseline that
  # failed every run. Tests still declare `async: true` and DBConnection
  # queues them on the one connection, which costs the suite nothing
  # measurable (~6.5s either way).
  pool_size: 1,
  pool: Ecto.Adapters.SQL.Sandbox,
  # Kept as a backstop for whatever contention a single connection can still
  # see (checkin/checkout overlap, the odd non-sandboxed connection): wait for
  # the lock rather than erroring out at the adapter's 2000ms default.
  busy_timeout: 30_000,
  # In the default rollback-journal mode a mere READER blocks every writer,
  # and the SQL Sandbox keeps a transaction open per checked-out connection
  # for the whole test - so one long-lived sandbox read transaction starves
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

# Route PairingsEngine.Keycloak's Req calls through a Req.Test stub instead of
# the real network - see Req.Test's moduledoc for the `plug: {Req.Test, name}`
# convention. Individual tests set behaviour with Req.Test.stub/2.
config :pairings_engine, :keycloak_req_plug, PairingsEngine.KeycloakTest

# Same convention for the OpenResults publisher.
config :pairings_engine, :publishing_req_plug, PairingsEngine.PublishingTest

# The publish drain is the only worker that schedules work from `init`, and a
# timer firing mid-test would query the database from a process that does not
# own the sandbox connection. Tests call `Publishing.drain/0` directly.
config :pairings_engine, :publishing_drain_interval, :disabled
config :pairings_engine, :registration_poll_interval, :disabled
config :pairings_engine, :backup_interval, :disabled

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

config :pairings_engine, :connection_poll_interval, :disabled
