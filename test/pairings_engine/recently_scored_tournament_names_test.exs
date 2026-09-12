defmodule PairingsEngine.RecentlyScoredTournamentNamesTest do
  @moduledoc """
  `PairingsEngine.Tournaments.recently_scored_tournament_names/1` is what a
  rating-list sync now asks instead of `running_tournament_names/0` (see
  `PairingsEngine.SyncYieldsToRoundTest` for that one) - "was a result just
  entered here", not "does this tournament have any unfinished round". The
  second is true for most of a season on a club installation; the first is
  false almost all the time, which is the whole point.
  """
  use PairingsEngine.DataCase, async: true

  import Ecto.Query

  alias PairingsEngine.Audit
  alias PairingsEngine.Audit.AuditLog
  alias PairingsEngine.Repo
  alias PairingsEngine.Tournaments
  alias PairingsEngine.Tournaments.Tournament

  defp tournament(name) do
    Repo.insert!(%Tournament{name: name, type: "swiss", rounds_count: 5, status: "running"})
  end

  defp log(tournament_id, action, seconds_ago \\ 0) do
    {:ok, entry} = Audit.log(tournament_id, nil, action, %{})

    if seconds_ago > 0 do
      backdated =
        DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.truncate(:second)

      Repo.update_all(from(a in AuditLog, where: a.id == ^entry.id),
        set: [inserted_at: backdated]
      )
    end

    entry
  end

  test "nothing logged means nothing to name" do
    tournament("Bruges Open")
    assert Tournaments.recently_scored_tournament_names() == []
  end

  test "a result entered just now names its tournament" do
    t = tournament("Bruges Open")
    log(t.id, "pairing.result_entered")

    assert Tournaments.recently_scored_tournament_names() == ["Bruges Open"]
  end

  test "a changed result and a cleared result both count, same as an entered one" do
    t1 = tournament("Antwerp Classic")
    t2 = tournament("Ghent Rapid")
    log(t1.id, "pairing.result_changed")
    log(t2.id, "pairing.result_cleared")

    assert Tournaments.recently_scored_tournament_names() == ["Antwerp Classic", "Ghent Rapid"]
  end

  test "an action that is not about a result does not count" do
    t = tournament("Bruges Open")
    log(t.id, "pairing.round_paired")

    assert Tournaments.recently_scored_tournament_names() == []
  end

  test "a result from outside the default two-minute window does not count" do
    t = tournament("Bruges Open")
    log(t.id, "pairing.result_entered", 200)

    assert Tournaments.recently_scored_tournament_names() == []
  end

  test "the window is exactly what the caller passes, not only the default" do
    t = tournament("Bruges Open")
    log(t.id, "pairing.result_entered", 20)

    assert Tournaments.recently_scored_tournament_names(10) == [],
           "20s ago is outside a 10s window"

    assert Tournaments.recently_scored_tournament_names(30) == ["Bruges Open"],
           "20s ago is inside a 30s window"
  end

  test "several results in the same tournament still name it once" do
    t = tournament("Bruges Open")
    log(t.id, "pairing.result_entered")
    log(t.id, "pairing.result_entered")
    log(t.id, "pairing.result_changed")

    assert Tournaments.recently_scored_tournament_names() == ["Bruges Open"]
  end

  test "several tournaments come back sorted by name, not by recency" do
    t1 = tournament("Namur Open")
    t2 = tournament("Antwerp Classic")

    # Namur's result is the more recent of the two, but the list is still
    # alphabetical - a flash message reads better sorted than by recency.
    log(t1.id, "pairing.result_entered")
    log(t2.id, "pairing.result_entered", 60)

    assert Tournaments.recently_scored_tournament_names() == ["Antwerp Classic", "Namur Open"]
  end

  test "a tournament that is not even running can still be named" do
    # The condition is "a result just happened", full stop - not "and the
    # tournament's status still says running". A result entered to correct a
    # tournament in the instant it finishes is exactly the case this must
    # not miss.
    t = tournament("Bruges Open")
    Repo.update!(Ecto.Changeset.change(t, status: "finished"))
    log(t.id, "pairing.result_entered")

    assert Tournaments.recently_scored_tournament_names() == ["Bruges Open"]
  end
end
