defmodule PairingsEngine.Test.LeftoverRows do
  @moduledoc """
  Empties the test database of rows that were COMMITTED to it, before a single
  test runs. `test/test_helper.exs` calls `clear!/0` just before it hands the
  database to the SQL Sandbox.

  Every test writes inside the Sandbox's transaction and has it rolled back, so
  the suite never leaves anything behind, and it quietly assumes it starts from
  empty tables. Nothing enforced that. `pairings_engine_test.db` is a plain file
  that outlives the run, and anything that reaches it without the Sandbox
  commits for good - a `MIX_ENV=test mix run probe.exs` calling a fixture, most
  obviously.

  That is the flaky test nobody could name (docs/test-quality-2026-09-13.md).
  On 2026-09-04 five such probes each committed a user from
  `AccountsFixtures.user_scope_fixture/0` to the main checkout's test database,
  and the rows stayed. `unique_user_email/0` builds its address from
  `System.unique_integer/0`, which is unique within ONE VM and starts again from
  the same base every boot, so a later run could hand a test the very address a
  probe had used. Which test drew it depended on the test order and on which
  scheduler ran the fixture, so a different test failed each time, on
  `{:error, email: "has already been taken"}`, and no re-run reproduced it:
  `MobileEnrollControllerTest` on 2026-09-10, one test during the Ainalrami
  v0.26.1 pin on 2026-09-11, `MobileTest` when it was hunted down.

  Clearing the tables removes the class, not only the e-mail case: every fixture
  that takes a unique column from `System.unique_integer/0` (public slugs,
  Keycloak subjects, installation keys) had the same exposure.

  Left alone: `schema_migrations`, so `ecto.migrate` stays a no-op; SQLite's own
  `sqlite_*` tables; and FTS5 virtual tables with their shadow tables, which the
  triggers on their content tables keep in step with the deletes.
  """

  alias PairingsEngine.Repo

  @kept ["schema_migrations"]

  @doc """
  Deletes every row of every ordinary table that has any, and returns what it
  found as `[{table, row_count}]` - `[]` on a clean database, which is every run
  but the first one after something committed.
  """
  def clear! do
    refuse_unless_test_database!()

    case Enum.flat_map(data_tables(), &rows_in/1) do
      [] ->
        []

      found ->
        {:ok, _} =
          Repo.transaction(fn ->
            # Checked at COMMIT instead of per statement, so the tables can be
            # emptied in any order; by then nothing is left to dangle. Unlike
            # `PRAGMA foreign_keys`, this one works inside a transaction, and
            # SQLite resets it when the transaction ends.
            Repo.query!("PRAGMA defer_foreign_keys = ON")
            Enum.each(found, fn {table, _count} -> Repo.query!(~s|DELETE FROM "#{table}"|) end)
          end)

        found
    end
  end

  # This deletes every row of every table it can see, so it checks what it can
  # see first. `config/test.exs` pins the Repo to `pairings_engine_test*.db`
  # today and nothing in the test environment reads DATABASE_PATH - but a
  # function this destructive should not rest on a config file staying as it
  # is. Anything else, and the suite stops before a single row is touched.
  defp refuse_unless_test_database! do
    database = Repo.config() |> Keyword.get(:database) |> to_string() |> Path.basename()

    unless String.starts_with?(database, "pairings_engine_test") do
      raise "LeftoverRows only ever empties the test database, and the Repo points at " <>
              inspect(database) <> ". Nothing was deleted."
    end
  end

  @doc "The ordinary tables of the main schema: the ones tests write to."
  def data_tables do
    %{rows: rows} = Repo.query!("PRAGMA main.table_list")

    for [_schema, name, "table" | _] <- rows,
        name not in @kept,
        not String.starts_with?(name, "sqlite_"),
        do: name
  end

  defp rows_in(table) do
    case Repo.query!(~s|SELECT count(*) FROM "#{table}"|) do
      %{rows: [[0]]} -> []
      %{rows: [[count]]} -> [{table, count}]
    end
  end
end
