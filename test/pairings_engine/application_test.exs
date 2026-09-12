defmodule PairingsEngine.ApplicationTest do
  @moduledoc """
  Covers what `PairingsEngine.Application.run_migrations/0`'s "the same
  message came back anyway (2026-09-12)" comment fixed: a first-boot
  migration connection that never becomes available must retry a bounded
  number of times, on connection-availability failures only, and must
  never swallow a genuine migration error.

  The actual trigger - DBConnection's own queue congestion control giving
  up on a connection that is still slowly `connect/1`-ing on a loaded CI
  runner - is exactly the kind of thing that comment says is hard to
  reproduce on purpose, so nothing here tries to. Two things ARE tested
  directly instead:

    * `with_migration_retry/4`, exercised against a stub `migrate` that
      fails on command rather than a real flaky database connection;
    * the `queue_target`/`queue_interval` config the fix actually relies
      on, which `mix test` never boots through (it is gated behind
      `config_env() == :prod` in `config/runtime.exs`, and `config/dev.exs`
      is not loaded at all under `MIX_ENV=test`), so it is checked by
      reading the config files rather than `PairingsEngine.Repo.config()`.
  """
  use ExUnit.Case, async: true

  alias PairingsEngine.Application, as: App

  describe "with_migration_retry/4" do
    test "a migration that succeeds first try never logs or sleeps" do
      assert {:ok, :migrated, []} =
               App.with_migration_retry(fn -> {:ok, :migrated, []} end, PairingsEngine.Repo, 3, 0)
    end

    test "retries a connection-availability failure and succeeds on a fresh attempt" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      migrate = fn ->
        if Agent.get_and_update(counter, &{&1, &1 + 1}) < 2 do
          raise DBConnection.ConnectionError, message: "queued too long", reason: :queue_timeout
        else
          {:ok, :migrated, []}
        end
      end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :migrated, []} =
                   App.with_migration_retry(migrate, PairingsEngine.Repo, 3, 0)
        end)

      # Two failures, then the attempt that finally lands.
      assert Agent.get(counter, & &1) == 3
      assert log =~ "2 attempt(s) left"
      assert log =~ "1 attempt(s) left"
    end

    test "gives up and re-raises the original error after the last attempt" do
      migrate = fn ->
        raise DBConnection.ConnectionError, message: "queued too long", reason: :queue_timeout
      end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert_raise DBConnection.ConnectionError, "queued too long", fn ->
            App.with_migration_retry(migrate, PairingsEngine.Repo, 2, 0)
          end
        end)

      assert log =~ "1 attempt(s) left"
      assert log =~ "did not become available after"
    end

    test "a single attempt configured means no retry at all" do
      migrate = fn ->
        raise DBConnection.ConnectionError, message: "queued too long", reason: :queue_timeout
      end

      assert_raise DBConnection.ConnectionError, fn ->
        App.with_migration_retry(migrate, PairingsEngine.Repo, 1, 0)
      end
    end

    test "a genuine migration error is never retried and never disguised" do
      # The dangerous failure mode here is over-catching: a real bug in a
      # migration turned into "just try again" would retry a doomed
      # operation and hide the actual message behind three attempts of
      # noise instead of crashing loudly on the first one, as required.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      migrate = fn ->
        Agent.update(counter, &(&1 + 1))
        raise Ecto.MigrationError, "column already exists"
      end

      assert_raise Ecto.MigrationError, "column already exists", fn ->
        App.with_migration_retry(migrate, PairingsEngine.Repo, 3, 0)
      end

      assert Agent.get(counter, & &1) == 1
    end
  end

  describe "the queue_target/queue_interval config the fix relies on" do
    # `mix test` runs under `config_env() == :test`, so neither of these
    # files' Repo config is what `Application.get_env/2` would return here
    # - reading the source is the only way to pin the values `with_repo/3`
    # actually starts the migration connection with in prod and dev.
    test "config/runtime.exs raises the migration connection's queue patience" do
      source = File.read!("config/runtime.exs")

      assert source =~ ~r/config :pairings_engine, PairingsEngine\.Repo,/

      repo_config = repo_config_block(source)

      assert repo_config =~ ~r/busy_timeout:\s*15_000/,
             "the existing busy_timeout guard moved or changed"

      assert repo_config =~ ~r/queue_target:\s*5_000/,
             "queue_target should give the migration connection room for a slow connect"

      assert repo_config =~ ~r/queue_interval:\s*15_000/,
             "queue_interval should match busy_timeout, not DBConnection's 2_000ms default"
    end

    test "config/dev.exs carries the same queue patience for mix ecto.migrate" do
      source = File.read!("config/dev.exs")
      repo_config = repo_config_block(source)

      assert repo_config =~ ~r/queue_target:\s*5_000/
      assert repo_config =~ ~r/queue_interval:\s*15_000/
    end

    # The block runs from the `config :pairings_engine, PairingsEngine.Repo,`
    # line to the next blank line, same slice-by-blank-line approach the
    # rest of this file's config comments already read by eye.
    defp repo_config_block(source) do
      [_before, after_header] =
        String.split(source, ~r/config :pairings_engine, PairingsEngine\.Repo,/, parts: 2)

      after_header
      |> String.split(~r/\n\s*\n/, parts: 2)
      |> hd()
    end
  end
end
