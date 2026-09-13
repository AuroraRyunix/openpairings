defmodule PairingsEngine.Test.LeftoverRowsTest do
  @moduledoc """
  The clean-up `test/test_helper.exs` runs before the suite. See
  `PairingsEngine.Test.LeftoverRows`.

  Run inside the Sandbox like any other test, so the rows below stand in for
  committed leftovers and every DELETE the clean-up issues is rolled back with
  the rest of the test.
  """
  use PairingsEngine.DataCase, async: true

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.Accounts.User
  alias PairingsEngine.Test.LeftoverRows
  alias PairingsEngine.Tournaments
  alias PairingsEngine.Tournaments.Tournament

  test "a probe's user and tournament are found, counted and removed" do
    scope = user_scope_fixture()
    {:ok, _} = Tournaments.create_tournament(scope, %{"name" => "Probe", "type" => "swiss"})

    found = Map.new(LeftoverRows.clear!())

    assert found["users"] == 1
    assert found["tournaments"] == 1
    assert Repo.aggregate(User, :count) == 0
    assert Repo.aggregate(Tournament, :count) == 0
    assert LeftoverRows.clear!() == []
  end

  test "the address a leftover user held can be registered again afterwards" do
    email = unique_user_email()
    _leftover = user_fixture(%{email: email})

    LeftoverRows.clear!()

    assert %User{email: ^email} = user_fixture(%{email: email})
  end

  test "migrations' bookkeeping, SQLite's own tables and full-text indexes are left alone" do
    tables = LeftoverRows.data_tables()
    migrations_before = Repo.query!("SELECT count(*) FROM schema_migrations").rows

    LeftoverRows.clear!()

    assert "users" in tables
    assert "tournaments" in tables
    refute "schema_migrations" in tables
    refute Enum.any?(tables, &String.starts_with?(&1, "sqlite_"))
    refute Enum.any?(tables, &String.contains?(&1, "_fts"))
    assert Repo.query!("SELECT count(*) FROM schema_migrations").rows == migrations_before
    assert [[migrations]] = migrations_before
    assert migrations > 0
  end
end
