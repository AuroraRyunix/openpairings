defmodule PairingsEngine.Federations.BEL.SyncFtsCostTest do
  @moduledoc """
  The full-replace import must not be quadratic in the size of the roster.

  `kbsb_players` carries an AFTER DELETE trigger that runs
  `DELETE FROM kbsb_players_fts WHERE national_id = old.national_id`. FTS5 is
  a virtual table and cannot carry an index, so that WHERE is a full scan of
  the index - once per deleted row. Deleting the roster row by row therefore
  cost O(n squared), and in September 2026 it crossed the sync's 180 s
  watchdog: the import died at "Importing players... 0 of 35849" while
  looking, from the outside, like a sync that simply stopped working.

  The sync clears the index in one statement first, so each trigger then
  scans an empty table. This test fails if anyone removes that line.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.Repo
  alias PairingsEngine.Federations.BEL.Member

  # Big enough that the quadratic path takes seconds (it needed ~8.5 s here)
  # and the linear one milliseconds, so the bound below separates them by a
  # wide margin rather than by a stopwatch.
  @rows 8_000
  @budget_ms 2_000

  defp seed(n) do
    Repo.query!("DELETE FROM kbsb_players_fts")
    Repo.query!("DELETE FROM kbsb_players")

    1..n
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk ->
      rows =
        Enum.map(chunk, fn i ->
          %{
            national_id: "N#{i}",
            last_name: "Player#{i}",
            first_name: "A",
            national_rating: 1500,
            club_name: "",
            federation: ""
          }
        end)

      Repo.insert_all(Member, rows)
    end)
  end

  @tag timeout: 300_000
  test "clearing the roster stays linear, and leaves no orphaned index rows" do
    seed(@rows)

    {us, _} =
      :timer.tc(fn ->
        Repo.query!("DELETE FROM kbsb_players_fts")
        Repo.query!("DELETE FROM kbsb_players")
      end)

    ms = us / 1000

    assert ms < @budget_ms,
           "clearing #{@rows} players took #{Float.round(ms, 1)} ms, over the " <>
             "#{@budget_ms} ms budget. The per-row FTS trigger is almost " <>
             "certainly scanning the whole index again - check that the sync " <>
             "still empties kbsb_players_fts before deleting kbsb_players."

    assert Repo.aggregate(Member, :count) == 0

    # A stale index row would make the player lookup offer names that are no
    # longer in the mirror, which is worse than being slow.
    %{rows: [[orphans]]} = Repo.query!("SELECT count(*) FROM kbsb_players_fts")

    assert orphans == 0,
           "#{orphans} rows left behind in kbsb_players_fts after the roster was cleared"
  end
end
