defmodule PairingsEngine.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PairingsEngineWeb.Telemetry,
      PairingsEngine.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:pairings_engine, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:pairings_engine, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PairingsEngine.PubSub},
      PairingsEngine.Fide.Sync,
      # Always supervised, even on a machine where nobody has the Belgian
      # pack's rating-list sync switched on. Three reasons, in order of
      # weight:
      #
      #   1. The switch is PER USER (`PairingsEngine.Features`) and this list
      #      is machine-wide, decided once at boot. Two arbiters can share an
      #      installation and disagree; a supervision tree cannot follow a
      #      preference that changes while it is running, and restarting the
      #      application to honour a checkbox is not a design.
      #   2. It costs nothing idle. This GenServer is manual-trigger only -
      #      no boot work, no timers, no polling (see its moduledoc). Until
      #      something casts to it, it is one process holding a small struct.
      #   3. `Sync.status/0` is a `GenServer.call` by name, so a conditional
      #      child would turn every read of it into an exit, and every caller
      #      would need a "not running" branch. More code, more ways to be
      #      wrong, to save a few hundred bytes.
      #
      # Idle is therefore achieved at the ENTRANCES rather than here: the
      # Connections page renders the Belgian panel, subscribes to this
      # process's topic and accepts its two events only for an account with
      # `bel_ratings_sync` on (see `PairingsEngineWeb.FideLive`, which also
      # re-checks in each handler body because a `phx-click` payload is
      # attacker-controlled). With every entrance shut, nothing ever casts to
      # this, and it sits at `:idle` for the life of the node.
      PairingsEngine.Federations.BEL.Sync,
      PairingsEngine.Tools.Session,
      PairingsEngine.RateLimit,
      PairingsEngine.Deploy,
      PairingsEngine.Publishing.Drain,
      PairingsEngine.Registrations.Poll,
      PairingsEngine.Backup.Scheduler,
      # For work a LiveView must not do in its own process. The publishing
      # connection check is a network round trip with a fifteen-second timeout,
      # and running it inline would freeze the page - every click, every
      # toggle - for as long as an unreachable results site takes to give up.
      {Task.Supervisor, name: PairingsEngine.TaskSupervisor},
      # AFTER the Task.Supervisor, deliberately: it hands its first
      # connection check off the moment it starts, and a task supervisor that
      # does not exist yet is an exit rather than a retry.
      PairingsEngine.Publishing.Monitor,
      # Start to serve requests, typically the last entry
      PairingsEngineWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PairingsEngine.Supervisor]

    with {:ok, _pid} = ok <- Supervisor.start_link(children, opts) do
      # After, not a child of, the supervisor: by the time `start_link/2`
      # above returns, Endpoint - last in `children` - has already bound its
      # listening socket, so a browser opened now finds a server instead of
      # a connection error. See `PairingsEngine.BrowserLauncher`'s moduledoc
      # for why this single call site can never fail the boot that already
      # succeeded.
      PairingsEngine.BrowserLauncher.maybe_open()
      ok
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PairingsEngineWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Migrations run at boot when this is a release, and not under `mix`, where
  # `mix ecto.migrate` is the workflow and running them from the supervision
  # tree would fight it.
  #
  # "Is this a release" used to be `RELEASE_NAME != nil`, which is what
  # `mix phx.gen.release` writes and is true of a release started through its
  # own `bin/<name>` script. **It is false in a Burrito binary**, which is
  # every standalone executable this project ships: Burrito's launcher execs
  # `erl` directly rather than going through that script, and sets
  # `RELEASE_ROOT` and `RELEASE_SYS_CONFIG` but not `RELEASE_NAME`
  # (`deps/burrito/src/erlang_launcher.zig`).
  #
  # So every binary ever built skipped its migrations, started against an
  # empty database, and returned 500 on the first page - "no such table:
  # users". Nobody noticed because nothing ever ran one: the binaries CI
  # built five executables and tested none of them, and `docs/binaries.md`
  # told you to run a migration step by hand first, through a
  # `PairingsEngine.Release.migrate` that does not exist.
  #
  # `RELEASE_ROOT` is set by both kinds of release, so it is the honest test.
  # `RELEASE_NAME` stays in the check for a plain `mix release` run, where
  # both are set anyway - keeping it costs nothing and means this does not
  # depend on Burrito's launcher continuing to set any particular variable.
  defp skip_migrations? do
    not release?()
  end

  defp release? do
    System.get_env("RELEASE_NAME") != nil or System.get_env("RELEASE_ROOT") != nil
  end
end
