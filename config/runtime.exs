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

# ---------------------------------------------------------------------------
# Local mode: the standalone binary, run on somebody's own machine.
#
# A release normally refuses to start without SMTP credentials, a
# DATABASE_PATH and a SECRET_KEY_BASE, all of which are right for a server
# and all of which are nonsense for a person who downloaded one file and
# double-clicked it. `OPENPAIRINGS_LOCAL=1` says "this is that": pick
# sensible paths, generate the secret once and keep it, and print the
# login link to the terminal instead of mailing it.
#
# ON BY DEFAULT IN A STANDALONE BINARY, and off everywhere else.
#
# It was opt-in at first, which was wrong in the way that only shows up when
# somebody actually uses the thing: you download one file, run it, and get
# "environment variable DATABASE_PATH is missing" followed by a 2.8 MB
# erl_crash_dump. That is a server's error message, and the person reading
# it is not running a server. Nobody deploys a self-extracting executable to
# production - a server gets a real release and a systemd unit - so a
# Burrito binary IS the local case, and asking it to be told so was asking
# the user to know something the program already knew.
#
# `__BURRITO=1` is set by Burrito's own launcher on both of its start paths
# (`deps/burrito/src/erlang_launcher.zig`), which makes it the marker rather
# than a guess about install paths - those are overridable.
#
# `OPENPAIRINGS_LOCAL` still wins in BOTH directions: `=1` turns it on for a
# plain `mix release` or a dev run, `=0` turns it off inside a binary for
# anyone who really does want to point one at a server config.
#
# The safety property is unchanged and is what makes the default safe to
# flip: local mode PINS THE LISTENER TO LOOPBACK further down, and the
# auto-sign-in additionally re-checks per request that the connection came
# from this machine. A binary run somewhere unexpected serves nobody rather
# than serving a no-login build to the network.
local_mode? =
  case System.get_env("OPENPAIRINGS_LOCAL") do
    value when value in ["1", "true", "yes"] -> true
    value when value in ["0", "false", "no"] -> false
    _ -> System.get_env("__BURRITO") == "1"
  end

# Where a local run keeps its database and its generated secret. OTP's own
# per-OS answer: AppData\Local on Windows, Library/Application Support on
# macOS, ~/.local/share on Linux.
# `OPENPAIRINGS_DATA_DIR` overrides it - for a run off a USB stick, a
# machine where the profile is not writable, and for the test that asserts
# what this file does without writing into the developer's real profile.
local_dir =
  if local_mode? do
    dir =
      System.get_env("OPENPAIRINGS_DATA_DIR") ||
        :filename.basedir(:user_data, ~c"OpenPairings") |> to_string()

    File.mkdir_p!(dir)
    dir
  end

# Generated once and kept. Regenerating it every boot would silently
# invalidate every session and every unexpired login link on restart.
local_secret = fn ->
  path = Path.join(local_dir, "secret_key_base")

  case File.read(path) do
    {:ok, existing} when byte_size(existing) >= 64 ->
      String.trim(existing)

    _ ->
      secret = 48 |> :crypto.strong_rand_bytes() |> Base.encode64()
      File.write!(path, secret)
      # Best-effort; File.chmod is a no-op that returns :ok on Windows.
      _ = File.chmod(path, 0o600)
      secret
  end
end

# Read back by `PairingsEngineWeb.UserAuth.local_owner_session/2`. Set from
# here and nowhere else, so "is this a local run" has exactly one answer and
# it is decided at boot rather than per request.
config :pairings_engine, :local_mode, local_mode?

# Accounts that administer this installation by declaration, on top of any
# holding the `admin` role in the database.
#
# This exists to close a bootstrap gap and nothing more. A freshly migrated
# hosted installation has no administrators at all, by design - so without
# this, the first thing after every deploy is a mix task run by hand at
# exactly the moment nobody wants an extra step, and the Connections page
# refuses everything until somebody remembers.
#
# It grants no authority that was not already there: this file is read from
# the systemd unit, which is written `chmod 600` and editable only by root,
# and root can run `mix pairings.role` anyway. What it does buy is that the
# operator is named in the deployment's own configuration rather than in a
# row somebody has to remember to create.
#
# Declared rather than promoted, deliberately: nothing is written to the
# database, so this cannot silently re-promote an account somebody
# deliberately demoted on the next restart. Removing an address here is how
# you revoke it.
config :pairings_engine,
       :admin_emails,
       (System.get_env("ADMIN_EMAILS") || "")
       |> String.split(",")
       |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
       |> Enum.reject(&(&1 == ""))

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

  local_mode? ->
    # Not Swoosh's Local adapter (an in-memory mailbox with a web UI you
    # would have to find) and not its Logger one (the whole struct, at
    # whatever log level): the point is that the link lands in the terminal
    # already in front of the person.
    config :pairings_engine, PairingsEngine.Mailer, adapter: PairingsEngine.ConsoleMailer
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
# by `PairingsEngine.Federations.BEL.Api` to refresh the local `kbsb_players` mirror
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
if System.get_env("PHX_SERVER") || local_mode? do
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
      (local_mode? && Path.join(local_dir, "openpairings.db")) ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/pairings_engine/pairings_engine.db
      """

  # Backups - see `PairingsEngine.Backup`.
  #
  # The database is 219 MB and 207 MB of that is downloaded rating lists, which
  # a sync rebuilds; a backup carries only what cannot be rebuilt, so these files
  # are small and it is worth keeping a month of them.
  #
  # BACKUP_DIR defaults to a `backups/` directory beside the database. Put it on
  # a different disk if there is one: a backup on the same disk survives a bad
  # migration and an accidental delete, which is most of what goes wrong, but not
  # the disk itself.
  #
  # PAIRINGS_BACKUP_PASSPHRASE encrypts them. Worth setting: an unencrypted
  # backup carries the email addresses people gave the entry form. Without it the
  # files are plain, and whoever holds them holds those addresses.
  if backup_dir = System.get_env("BACKUP_DIR") do
    config :pairings_engine, :backup_dir, backup_dir
  end

  if passphrase = System.get_env("PAIRINGS_BACKUP_PASSPHRASE") do
    config :pairings_engine, :backup_passphrase, passphrase
  end

  if keep = System.get_env("BACKUP_RETENTION") do
    config :pairings_engine, :backup_retention, String.to_integer(keep)
  end

  config :pairings_engine, PairingsEngine.Repo,
    database: database_path,
    # Two locally rather than five. One person cannot use five connections,
    # and on a FIRST run they all race to create the same new file and set
    # `journal_mode = wal` on it, which produced an intermittent
    # "database is locked" at boot on the CI smoke run. Fewer connections,
    # smaller race. (It recovers either way - Ecto retries - but a fresh
    # install should not have to.)
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || (local_mode? && "2") || "5"),
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
      (local_mode? && local_secret.()) ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || (local_mode? && "localhost") || "example.com"

  config :pairings_engine, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  port = String.to_integer(System.get_env("PORT", "4000"))

  # The loopback pin. This is what makes local mode safe to have at all: the
  # mode prints login links to a terminal, so it must not be reachable from
  # another machine, and that is enforced here rather than left to whoever
  # sets the variable. A server that switches it on by mistake stops
  # answering the internet - loud, and the safe direction to fail in.
  # And the same pin for a server, which is a smaller claim than it sounds.
  # The only client this app has in production is a cloudflared process on
  # the same host, dialling it over loopback; binding every interface as well
  # put the whole application on the box's public addresses, with the host
  # firewall as the single control between it and the internet.
  #
  # OPENPAIRINGS_LISTEN_IP is the way out for a deployment that really does
  # need to be reached directly - "0.0.0.0" for every IPv4 address, "::" for
  # every address of either family, or one specific address. Anything
  # unparseable is refused rather than guessed at: a typo that silently fell
  # back to a wide bind would be the failure this exists to prevent.
  #
  # Local mode ignores it. That pin is a safety property of the mode itself
  # (see above), not a default to be overridden.
  parse_listen_ip = fn value ->
    case value |> String.trim() |> String.to_charlist() |> :inet.parse_address() do
      {:ok, address} ->
        address

      {:error, _} ->
        raise """
        OPENPAIRINGS_LISTEN_IP is not an IP address: #{inspect(value)}

        Use "127.0.0.1" (the default), "0.0.0.0" for every IPv4 address,
        "::" for every address, or a specific address to bind.
        """
    end
  end

  {listen_ip, url_config} =
    if local_mode? do
      {{127, 0, 0, 1}, [host: host, port: port, scheme: "http"]}
    else
      listen_ip =
        case System.get_env("OPENPAIRINGS_LISTEN_IP") do
          nil -> {127, 0, 0, 1}
          "" -> {127, 0, 0, 1}
          value -> parse_listen_ip.(value)
        end

      {listen_ip, [host: host, port: 443, scheme: "https"]}
    end

  config :pairings_engine, PairingsEngineWeb.Endpoint,
    url: url_config,
    http: [
      # Loopback unless OPENPAIRINGS_LISTEN_IP says otherwise - see above.
      # https://bandit.hexdocs.pm/Bandit.html#t:options/0 covers IPv6 vs IPv4
      # and loopback vs public addresses.
      ip: listen_ip
    ],
    secret_key_base: secret_key_base

  if local_mode? do
    IO.puts("""

    OpenPairings - local mode
      database  #{database_path}
      address   http://#{host}:#{port}

    There is no login - this is your machine, so you are already signed in.
    Reachable from this computer only.
    """)

    # Deliberately does NOT print the owner's address by calling
    # `PairingsEngine.Accounts.local_owner_email/0`. runtime.exs is evaluated
    # before the application starts, so reaching into app modules from here
    # turns a cosmetic line into a way for boot to fail. The address is on
    # screen in the top bar a second later anyway.
  end

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
