defmodule PairingsEngine.Fide.FtsTriggerRecoveryTest do
  @moduledoc """
  A sync killed mid-import must not cost the search index permanently.

  `do_import_list/4` drops the `fide_players_fts` triggers before its bulk
  load and recreates them after, and since the import stopped riding one
  transaction there is nothing to roll that back. `cancel_import/0` uses
  `Process.exit(pid, :kill)`, which no `after` block survives, so the triggers
  really can be left absent.

  The danger is not that one run fails. It is that recreation used to depend
  on having captured the triggers from `sqlite_master` at the start of the
  same run: the NEXT run would capture an empty list, drop nothing and
  recreate nothing, cementing the loss instead of repairing it. From then on
  every single-row write to `fide_players` would leave the index stale, with
  nothing anywhere to say so.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.Repo
  alias PairingsEngine.Fide.FidePlayer

  defp trigger_names do
    %{rows: rows} =
      Repo.query!("""
      SELECT name FROM sqlite_master
      WHERE type = 'trigger' AND tbl_name = 'fide_players'
      ORDER BY name
      """)

    List.flatten(rows)
  end

  defp indexed_ids do
    %{rows: rows} = Repo.query!("SELECT fide_id FROM fide_players_fts ORDER BY fide_id")
    List.flatten(rows)
  end

  test "the migration's three triggers are what we expect to find" do
    assert trigger_names() == [
             "fide_players_fts_ad",
             "fide_players_fts_ai",
             "fide_players_fts_au"
           ]
  end

  test "an interrupted import leaves the triggers gone - the state to recover from" do
    Enum.each(trigger_names(), &Repo.query!("DROP TRIGGER #{&1}"))
    assert trigger_names() == []

    # And with them gone the index silently stops tracking the table, which
    # is the damage that must not be allowed to become permanent.
    Repo.insert_all(FidePlayer, [%{fide_id: 1, name: "Ghost, Player", federation: "BEL"}])
    assert indexed_ids() == []
  end

  test "the next sync restores them from the built-in definitions" do
    Enum.each(trigger_names(), &Repo.query!("DROP TRIGGER #{&1}"))
    assert trigger_names() == []

    # What the sync does at the top of its import.
    triggers = apply(PairingsEngine.Fide.Sync, :fts_triggers_for_test, [])
    Enum.each(triggers, fn %{sql: sql} -> Repo.query!(sql) end)

    assert trigger_names() == [
             "fide_players_fts_ad",
             "fide_players_fts_ai",
             "fide_players_fts_au"
           ]

    # Restored in working order, not merely present.
    Repo.insert_all(FidePlayer, [%{fide_id: 2, name: "Back, Intrack", federation: "BEL"}])
    assert indexed_ids() == [2]

    Repo.delete_all(FidePlayer)
    assert indexed_ids() == []
  end
end
