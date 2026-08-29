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
      PairingsEngine.Kbsb.Sync,
      PairingsEngine.Tools.Session,
      PairingsEngine.RateLimit,
      PairingsEngine.Deploy,
      PairingsEngine.Publishing.Drain,
      PairingsEngine.Registrations.Poll,
      PairingsEngine.Backup.Scheduler,
      # Start to serve requests, typically the last entry
      PairingsEngineWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PairingsEngine.Supervisor]
    Supervisor.start_link(children, opts)
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
