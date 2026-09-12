defmodule PairingsEngine.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  # How many times `run_migrations/0` will throw the current migration
  # connection away and start a fresh one if it never became available
  # (queue_timeout, not a migration error - see the comment on
  # `run_migrations/0`). Not one: a single slow connect on a loaded CI
  # runner is exactly the transient case worth trying again for. Not
  # unbounded: a database that is genuinely unreachable must still say so
  # and stop the boot, per `run_migrations/0`'s own comment on why this is
  # not `PairingsEngine.BusyWrite`'s "no retry loop" case.
  @migration_connection_attempts 3
  @migration_connection_retry_backoff_ms 2_000

  @impl true
  def start(_type, _args) do
    # Migrations run here - before `children` below ever builds a
    # connection pool - not as an entry in that list, where they ran until
    # this comment was written. See `run_migrations/0`'s comment for why
    # moving them out was the fix and not just a rearrangement.
    unless skip_migrations?(), do: run_migrations()

    children = [
      PairingsEngineWeb.Telemetry,
      PairingsEngine.Repo,
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
      # Always supervised, idle on a hosted server - see its own moduledoc
      # for why (same "idle at the entrances" reasoning as
      # `PairingsEngine.Federations.BEL.Sync` just above). It never so much
      # as schedules its first timer unless `PairingsEngine.Authz.local_mode?/0`
      # says this is a desktop install, so a hosted server's copy of this
      # process sits doing nothing for the life of the node.
      PairingsEngine.Updates.Checker,
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

  # Migrations run through a single, throwaway connection - never through
  # `PairingsEngine.Repo`'s own pool - because that pool's very first boot
  # against a brand-new database (every fresh install, every fresh CI
  # runner, every wiped `OPENPAIRINGS_DATA_DIR`) is a race its own
  # connections can lose to each other.
  #
  # SQLite only needs an exclusive lock to CHANGE `journal_mode` to `:wal`,
  # not to confirm it is already there - and on a database file that does
  # not exist yet, EVERY connection that opens it is making that change, not
  # confirming it. `PairingsEngine.Repo`'s pool opens more than one
  # connection at once (`pool_size: 2` in local mode, 5 on a server - see
  # `config/runtime.exs`), and exqlite's `connect/1` sets `:journal_mode`
  # before `:busy_timeout` (`exqlite/lib/exqlite/connection.ex`), so on that
  # first boot every connection but the one that wins the lock hits
  # SQLITE_BUSY with no busy-wait configured yet to ride it out - there is
  # nothing to wait WITH. DBConnection then retries that failed connect on
  # its own backoff (starting at `:backoff_min`, 1 000 ms by default, not
  # ours), while `Ecto.Migrator`'s checkout for "CREATE TABLE
  # schema_migrations" sits in the pool's queue with nothing to check out -
  # and DBConnection's own queue drops it once it has waited long enough:
  # "connection not available and request was dropped from queue after
  # 4000ms", the portable release's intermittent boot failure on the CI
  # macOS x86_64 runner (the slowest in the build matrix, and so the one
  # slow enough to open this window). `pool_size` was already lowered from 5
  # to 2 for local mode for exactly this race (see the comment on
  # `PairingsEngine.Repo`'s config) and it narrowed the window without
  # closing it - two connections can still open the same new file at once.
  #
  # A single connection cannot race itself. `with_repo/3` below starts its
  # own `pool_size: 1` copy of the repo - ours is not running yet, since
  # this runs before `children` in `start/2` - so exactly one connection
  # ever performs the create-the-file-and-switch-to-:wal step, runs every
  # migration, then stops. By the time `PairingsEngine.Repo` starts as an
  # ordinary child right after this returns, the file already exists and is
  # already `:wal`, so every pool connection's own `:journal_mode` pragma is
  # now the cheap confirmation rather than the exclusive-locking change -
  # opening two, or five, of them at once is no longer a race.
  #
  # ## The same message came back anyway (2026-09-12)
  #
  # `pool_size: 1` closes the race ABOVE - two connections fighting over the
  # WAL switch - but it does not make the one remaining connection instant,
  # and it turns out DBConnection was never actually waiting for THAT lock
  # in the run that reopened this: run 34696140761 (commit 81c0925, a
  # docs-only change - the identical code had passed run 34695187793 twenty
  # minutes earlier) died on `Ecto.Migrator.verbose_schema_migration/3` -
  # "create schema migrations table", the very FIRST query this throwaway
  # connection ever runs, before a single migration file has executed. With
  # only one connection ever existing, nothing else could have been holding
  # it; the only thing left that takes a variable amount of time is the
  # connection itself finishing `connect/1` (open the file, switch it to
  # `:wal`, apply `:busy_timeout` and the rest of `config/runtime.exs`'s
  # pragmas) on whatever the slowest machine in the fleet is doing at that
  # moment - and the macOS x86_64 runner, the slowest target in the build
  # matrix, is exactly where both failures happened.
  #
  # DBConnection does not treat "the pool has zero ready connections because
  # the only one is still connecting" as a special case - it queues the
  # checkout like any other, and its CoDel-based congestion control
  # (`:queue_target`/`:queue_interval`, defaults 50ms/2000ms) starts
  # actively dropping queued requests once the queue looks "slow" for about
  # one full interval, which is what "dropped from queue after 4000ms" is:
  # roughly two default `:queue_interval`s, not a hardcoded 4 000. The
  # error's own text names the fix - "4. Allowing requests to wait longer by
  # increasing :queue_target and :queue_interval" - so `PairingsEngine.Repo`
  # now sets both generously (`config/runtime.exs`, `config/dev.exs`),
  # matching the existing `busy_timeout: 15_000` rather than the
  # library defaults that were tuned for a pool serving concurrent web
  # requests, not a solitary boot-time migration with nothing else queued
  # behind it to protect against.
  #
  # That should already close this for good, but the retry below stays as a
  # backstop for however much slower a CI runner can still get: it is NOT
  # the retry loop `PairingsEngine.BusyWrite` argues against, because it is
  # not the same failure shape. `BusyWrite` is about an application write
  # hitting a lock that a DIFFERENT writer already holds - trying again
  # immediately just queues behind the same holder, so waiting longer is the
  # only real fix, which is exactly why that module has no loop. Here the
  # failed attempt holds NOTHING - `with_repo/3`'s `after` clause has
  # already stopped the pool that failed to connect in time - so a retry
  # starts a genuinely fresh connection with a full new budget, not a second
  # queue entry behind the same slow one. A migration that fails for its OWN
  # reason (bad SQL, a bug in a backfill) does not raise
  # `DBConnection.ConnectionError` and is never caught here - it crashes the
  # boot immediately, exactly as before.
  defp run_migrations do
    for repo <- Application.fetch_env!(:pairings_engine, :ecto_repos) do
      run_migrations_for(repo, @migration_connection_attempts)
    end
  end

  defp run_migrations_for(repo, attempts_left) do
    migrate = fn ->
      Ecto.Migrator.with_repo(
        repo,
        # `log: :info` is already the default (see `Ecto.Migration.Runner`),
        # kept explicit so which migration is running - the one thing worth
        # seeing if a long backfill is what makes a future boot slow - does
        # not depend on that default never changing upstream.
        &Ecto.Migrator.run(&1, :up, all: true, log: :info),
        pool_size: 1
      )
    end

    with_migration_retry(migrate, repo, attempts_left)
  end

  # Split out from `run_migrations_for/2` so the retry/give-up decision -
  # retry only a connection-availability failure, and only a bounded number
  # of times, backing off between attempts - can be exercised directly in
  # `PairingsEngine.ApplicationTest` against a stub `migrate` that fails on
  # command, without a real flaky database connection. `@doc false` rather
  # than `defp`: this is still a private implementation detail of
  # `run_migrations/0`, just one the test module next to it needs to reach.
  @doc false
  def with_migration_retry(
        migrate,
        repo,
        attempts_left,
        backoff_ms \\ @migration_connection_retry_backoff_ms
      ) do
    {:ok, _, _} = migrate.()
  rescue
    error in [DBConnection.ConnectionError] ->
      if attempts_left > 1 do
        Logger.warning(
          "[#{inspect(repo)}] migration connection was not available " <>
            "(#{Exception.message(error)}); starting a fresh connection " <>
            "(#{attempts_left - 1} attempt(s) left)."
        )

        Process.sleep(backoff_ms)
        with_migration_retry(migrate, repo, attempts_left - 1, backoff_ms)
      else
        Logger.error(
          "[#{inspect(repo)}] migration connection did not become available " <>
            "after #{@migration_connection_attempts} attempts; giving up."
        )

        reraise error, __STACKTRACE__
      end
  end

  defp release? do
    System.get_env("RELEASE_NAME") != nil or System.get_env("RELEASE_ROOT") != nil
  end
end
