defmodule Mix.Tasks.Pairings.SnapshotFixtures do
  @shortdoc "Regenerates the OpenResults contract fixtures"

  @moduledoc """
  Regenerates the JSON fixtures the OpenResults repo tests its snapshot
  contract against (`snapshot_swiss.json`, `snapshot_keizer.json`,
  `snapshot_team_roundrobin.json`), from the same builders
  `PairingsEngine.SnapshotTest`'s "the cross-repo contract fixtures" drift
  check uses.

      MIX_ENV=test mix pairings.snapshot_fixtures
      MIX_ENV=test mix pairings.snapshot_fixtures --out path/to/dir

  Writes into `../openresults/test/fixtures` by default (a sibling checkout
  next to this one), or `--out DIR`, or `OPENRESULTS_FIXTURES` if that env
  var is set and `--out` is not - the same override `SnapshotTest` and this
  task's own default both honour, so a CI job or a differently-laid-out
  checkout can point every one of them somewhere else at once. See
  `PairingsEngine.SnapshotFixtures.fixture_dir/0`.

  Output is deterministic: the same fixed tournament names, players, results
  and slugs on every run, `published_at` and `source.version` pinned rather
  than the real clock and this checkout's dev version, and `Jason.encode!/2`
  with `pretty: true`'s stable key order. Two runs back to back produce
  byte-identical files - print only the ones that actually changed, below.

  ## Why `MIX_ENV=test`

  The fixtures are built by writing real tournaments through `PairingsEngine.
  Repo` and reading them back through `Snapshot.build/1`, using the same
  fixture builders (`PairingsEngine.SnapshotFixtures`, under
  `test/support/fixtures/`) the test suite already relies on for its own
  assertions about the same contract. That module - and this task, next to
  it under `test/support/` - only exist when `test/support` is on the
  compile path, which `mix.exs` does only for `MIX_ENV=test`. Running this
  any other way fails at task lookup with "no such task" rather than doing
  the wrong thing quietly.

  The task then opens one connection to the test database
  (`PairingsEngine.Repo.start_link/1`, tolerating "already started" for a
  shell where the app is already up) and checks it out of the SQL Sandbox by
  hand (`Ecto.Adapters.SQL.Sandbox.checkout/1`) - the same mechanism
  `PairingsEngine.DataCase` uses per test, just called directly instead of
  through `ExUnit`'s `setup`, since this runs as a single one-shot script
  rather than inside a test run. Nothing it writes is meant to survive: the
  checkout process exiting at the end of the task rolls the sandbox
  transaction back automatically, the same way a test's does.
  """

  use Mix.Task

  alias PairingsEngine.{Repo, SnapshotFixtures}

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    unless Mix.env() == :test do
      Mix.raise(
        "mix pairings.snapshot_fixtures must run with MIX_ENV=test " <>
          "(it writes fixture tournaments to the test database's sandbox) - " <>
          "try `MIX_ENV=test mix pairings.snapshot_fixtures`"
      )
    end

    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: [out: :string])

    dir =
      opts[:out] || SnapshotFixtures.fixture_dir() ||
        Mix.raise(
          "no output directory: pass --out DIR, set OPENRESULTS_FIXTURES, or check out " <>
            "../openresults beside this repo"
        )

    start_repo()
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    case SnapshotFixtures.write_all!(dir) do
      [] ->
        Mix.shell().info("#{dir}: every fixture already matched - nothing written.")

      changed ->
        Mix.shell().info(
          "#{dir}: wrote #{Enum.join(changed, ", ")} (#{length(changed)} of " <>
            "#{length(SnapshotFixtures.contract_fixtures())} changed)."
        )
    end
  end

  # `Repo` alone is not enough: the builders go through the ordinary
  # `PairingsEngine.Tournaments` write paths (`create_team/2`,
  # `create_player/2`, ...), and those broadcast on `PairingsEngine.PubSub`
  # after every write. Starting the whole application (`app.start`) would
  # also bring up the web endpoint against the port a running service is
  # already bound to - the same reason `mix pairings.role` and
  # `mix pairings.backup` start only what they need by hand - so this starts
  # just the two things the fixture builders actually touch.
  defp start_repo do
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

    case Supervisor.start_link([{Phoenix.PubSub, name: PairingsEngine.PubSub}],
           strategy: :one_for_one
         ) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> Mix.raise("could not start PairingsEngine.PubSub: #{inspect(reason)}")
    end

    case Repo.start_link(pool_size: 1) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> Mix.raise("could not reach the test database: #{inspect(reason)}")
    end
  end
end
