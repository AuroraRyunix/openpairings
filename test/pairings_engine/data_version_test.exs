defmodule PairingsEngine.DataVersionTest do
  @moduledoc """
  What moves `tournaments.data_version` and what does not, beyond the write
  paths `standings_cache_test.exs` already covers: a round's engine account
  (`rounds.explanation`) is commentary, written after the round by a
  background job, and on its own leaves the version where it was
  (migration `DataVersionIgnoresRoundAccounts`); and the standings cache
  keys by a tournament's settings, not by its bookkeeping.
  """
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.NextRoundPreviewFixture

  alias PairingsEngine.{Repo, Standings, StandingsCache}
  alias PairingsEngine.Tournaments.{Round, Tournament}

  setup do
    t =
      Repo.insert!(%Tournament{
        name: "Versioned",
        type: "swiss",
        rounds_count: 5,
        tiebreaks: ~w(BH),
        round_dates: List.duplicate("2026-09-01", 5)
      })

    for i <- 1..8, do: insert_player(t, i)
    round = pair!(t)
    %{t: reload(t), round: round}
  end

  defp version(t), do: StandingsCache.version(t.id)

  defp set_round(round, fields),
    do: Repo.update_all(from(r in Round, where: r.id == ^round.id), set: fields)

  test "writing only a round's account leaves the version", %{t: t, round: round} do
    before = version(t)
    set_round(round, explanation: %{"status" => "failed"})
    assert version(t) == before

    set_round(round, explanation: nil)
    assert version(t) == before
  end

  test "any other column of the round moves it, with or without the account", %{
    t: t,
    round: round
  } do
    before = version(t)
    set_round(round, status: "finished")
    after_status = version(t)
    assert after_status != before

    set_round(round, status: "playing", explanation: %{"status" => "pending"})
    assert version(t) != after_status
  end

  test "the trigger names every column of the round but its account" do
    columns =
      Repo.query!("PRAGMA table_info(rounds)").rows
      |> Enum.map(&Enum.at(&1, 1))

    [[sql]] =
      Repo.query!(
        "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = 'rounds_data_version_update'"
      ).rows

    for column <- columns -- ["explanation"] do
      assert sql =~ ~s|OLD."#{column}" IS NOT NEW."#{column}"|,
             "rounds.#{column} is not in rounds_data_version_update - recreate the trigger " <>
               "(see migration DataVersionIgnoresRoundAccounts) in the migration that added it"
    end
  end

  test "the standings cache keys by settings, not by bookkeeping", %{t: t} do
    StandingsCache.clear()
    Standings.points_by_player(t, through_round: 1)
    assert length(StandingsCache.entries(t.id)) == 1

    # What every "Pair round" click changes about the tournament row, and
    # what a page reloading the row after the click then hands in.
    moved = %{
      t
      | head_snapshot_id: (t.head_snapshot_id || 0) + 1,
        status: "in_progress",
        updated_at: DateTime.add(t.updated_at, 60)
    }

    Standings.points_by_player(moved, through_round: 1)
    assert length(StandingsCache.entries(t.id)) == 1

    # A setting is still a different tournament.
    Standings.points_by_player(%{t | bye_value: 0.5}, through_round: 1)
    assert length(StandingsCache.entries(t.id)) == 2
  end
end
