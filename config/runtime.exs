import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# Load .env file for local development and testing.
# This is safe to call in all environments; it only loads if the file exists
# and does not overwrite variables already set in the actual process environment
# (e.g. systemd Environment= lines on a production server).
env_file = Path.join(File.cwd!(), ".env")

if File.exists?(env_file) do
  env_file
  |> File.stream!()
  |> Stream.map(&String.trim/1)
  |> Stream.reject(&(String.length(&1) == 0 or String.starts_with?(&1, "#")))
  |> Enum.each(fn line ->
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        # Only set if not already in the actual process environment
        unless System.get_env(key) do
          System.put_env(key, value)
        end

      _ ->
        :ok
    end
  end)
end

# Configure outgoing email.
#
# SMTP credentials (Gmail) come from the .env loader above or from the real
# process environment (systemd `Environment=` lines on the server). When both
# are present we use real Gmail SMTP. In :prod email is MANDATORY - magic-link
# login depends on it and there is no local mailbox in production - so we refuse
# to boot without it rather than fail confusingly at the first login attempt.
# In :dev/:test without credentials we leave the adapter from dev.exs/test.exs
# (local mailbox / test adapter) untouched.
smtp_username = System.get_env("SMTP_USERNAME")
smtp_password = System.get_env("SMTP_PASSWORD")

smtp_configured? =
  is_binary(smtp_username) and String.trim(smtp_username) != "" and
    is_binary(smtp_password) and String.trim(smtp_password) != ""

cond do
  smtp_configured? and config_env() != :test ->
    config :pairings_engine, PairingsEngine.Mailer,
      adapter: Swoosh.Adapters.SMTP,
      relay: "smtp.gmail.com",
      port: 587,
      username: smtp_username,
      password: smtp_password,
      tls: :always,
      auth: :always,
      ssl: false,
      retries: 2,
      tls_options: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        server_name_indication: ~c"smtp.gmail.com"
      ]

    # The SMTP adapter (gen_smtp) needs no HTTP API client.
    config :swoosh, :api_client, false

  config_env() == :prod and System.get_env("PHX_SERVER") ->
    # Only the running web server (systemd sets PHX_SERVER=true) enforces this;
    # build tasks like `mix ecto.migrate` don't send mail, so they needn't carry
    # the SMTP password on their command line.
    raise """
    SMTP_USERNAME and SMTP_PASSWORD must be set in production.

    OpenPairings sends magic-link login emails and has no local mailbox in
    production, so it will not start without a working mail sender. Provide the
    credentials as systemd `Environment=` lines (the deploy script does this for
    you) or in a `.env` file next to the app.
    """

  true ->
    # dev/test without SMTP credentials: keep the mailbox/test adapter as-is.
    :ok
end

# Where PairingsEngine.Fide.Sync fetches the monthly rating-list zip.
#
# Defaults to FIDE itself; set FIDE_LIST_URL to a mirror or pass-through proxy
# when the host can't reach ratings.fide.com directly - it blocks a number of
# hosting ranges, which leaves a VPS retrying a download that can never
# succeed. Whatever this points at is unpacked straight into `fide_players`,
# so it is trusted exactly as much as FIDE is: only set it to something you
# control. See `PairingsEngine.Fide.Sync.list_url/0`.
config :pairings_engine, :fide, list_url: System.get_env("FIDE_LIST_URL")

# The KBSB data platform's roster API (the Odoo-synced live database), used
# by `PairingsEngine.Kbsb.Api` to refresh the local `kbsb_players` mirror
# without anyone having to upload a file. Both unset is a supported state:
# `Kbsb.Api.configured?/0` is then false and the UI offers only the file
# upload, exactly as before this existed.
#
# `KBSB_API_URL` is the base host with no path, e.g.
# "https://kbsb-api.zerotwo.cloud". `KBSB_API_KEY` is a scoped read key,
# sent as the `x-api-key` header.
config :pairings_engine, :kbsb,
  api_url: System.get_env("KBSB_API_URL"),
  api_key: System.get_env("KBSB_API_KEY")

# Who may put the read-only public tournament pages in an iframe -- a CSP
# `frame-ancestors` source list. Default `*`: those pages are already
# world-readable to anyone holding the slug, hold no session and take no
# input, so a club site embedding one gains nothing it could not already
# fetch. Set to a space-separated origin list to restrict it, or to
# `'none'` to switch embedding off. Everything else in the app stays at
# `'none'` regardless -- see `PairingsEngineWeb.CSP`.
config :pairings_engine,
       :public_frame_ancestors,
       System.get_env("PUBLIC_FRAME_ANCESTORS") || "*"

# The email domain self-serve registration/email-change is blocked on -
# accounts on it must come from 02cloud SSO instead (see
# `PairingsEngine.Accounts.User.blocked_registration_domain/0`). Defaults to
# the one domain that currently has SSO wired up; set
# SSO_BLOCKED_REGISTRATION_DOMAIN if a second federated domain is ever added,
# rather than hardcoding it - this was tech debt (a single hardcoded domain
# module attribute) until this env var existed.
config :pairings_engine, :accounts,
  blocked_registration_domain: System.get_env("SSO_BLOCKED_REGISTRATION_DOMAIN")

# Configure 02cloud SSO (Keycloak, auth.zerotwo.cloud, realm `zerotwo`).
#
# Unlike SMTP above, this is NOT required to boot - SSO is one login option
# among several (magic link, password), not the only account-recovery path -
# so an unconfigured instance (any dev checkout, or a prod deploy that hasn't
# registered a Keycloak client yet) simply serves an inert "SSO isn't
# configured" flash from `KeycloakAuthController.new/2` instead of failing to
# start. See `PairingsEngine.Keycloak.configured?/0`.
keycloak_client_id = System.get_env("KEYCLOAK_CLIENT_ID")
keycloak_client_secret = System.get_env("KEYCLOAK_CLIENT_SECRET")

config :pairings_engine, :keycloak,
  issuer: System.get_env("KEYCLOAK_ISSUER") || "https://auth.zerotwo.cloud/realms/zerotwo",
  client_id: keycloak_client_id,
  client_secret: keycloak_client_secret,
  redirect_uri:
    System.get_env("KEYCLOAK_REDIRECT_URI") ||
      "https://#{System.get_env("PHX_HOST") || "example.com"}/auth/keycloak/callback"

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/pairings_engine start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :pairings_engine, PairingsEngineWeb.Endpoint, server: true
end

config :pairings_engine, PairingsEngineWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# How many reverse proxies sit in front of this app. Rate limiting (the mobile
# enrollment code and the log-in email) keys on the client address, and behind
# a proxy every request otherwise arrives from the proxy's own address - one
# shared bucket for the whole venue. Set this to the number of proxies you
# actually run (usually 1) so the address is read from the right position in
# X-Forwarded-For; leaving it 0 means "no proxy", and the header is ignored
# entirely rather than trusted. See PairingsEngineWeb.ClientIp.
config :pairings_engine,
       :trusted_proxy_hops,
       String.to_integer(System.get_env("TRUSTED_PROXY_HOPS", "0"))

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :pairings_engine, PairingsEngineWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/pairings_engine_web/router\.ex$"E,
        ~r"lib/pairings_engine_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/pairings_engine/pairings_engine.db
      """

  config :pairings_engine, PairingsEngine.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    # See config/test.exs for why: rollback-journal mode lets one reader
    # starve every writer, and the adapter's 2000ms default busy_timeout is
    # too short for a multi-arbiter app with concurrent readers/writers.
    busy_timeout: 15_000,
    journal_mode: :wal

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :pairings_engine, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :pairings_engine, PairingsEngineWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :pairings_engine, PairingsEngineWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :pairings_engine, PairingsEngineWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end

# Shared secret for the deploy script's "about to restart" announcement.
# Unset means the endpoint refuses everything, which is the safe default:
# an unset variable must not silently open a route that can put a banner on
# every user's screen.
config :pairings_engine,
  deploy_notice_token: System.get_env("DEPLOY_NOTICE_TOKEN")
