defmodule PairingsEngine.SyncYieldsToRoundTest do
  @moduledoc """
  A rating-list sync must not start while a round is being played.

  SQLite takes one write lock for the whole database, and the two sync
  transactions are the only things in the application that hold it for more
  than milliseconds - long enough that an arbiter entering a result waits out
  `busy_timeout` and is refused. A rating list can be refreshed whenever; a
  result cannot wait. So the sync is what yields.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.Repo
  alias PairingsEngine.Tournaments
  alias PairingsEngine.Tournaments.Tournament

  defp tournament(name, status) do
    Repo.insert!(%Tournament{
      name: name,
      type: "swiss",
      rounds_count: 5,
      status: status
    })
  end

  test "no tournaments at all leaves the syncs free to run" do
    assert Tournaments.running_tournament_names() == []
  end

  test "a tournament still in setup does not hold a sync back" do
    tournament("Not started yet", "setup")
    assert Tournaments.running_tournament_names() == []
  end

  test "a finished tournament does not hold a sync back" do
    tournament("Last month", "finished")
    assert Tournaments.running_tournament_names() == []
  end

  test "scoring the last round releases the hold" do
    t = tournament("Bruges Open", "running")
    assert Tournaments.running_tournament_names() == ["Bruges Open"]

    # The guard reads live status rather than a cached flag, so finishing the
    # event is all it takes - nobody has to remember to unblock anything.
    Repo.update!(Ecto.Changeset.change(t, status: "finished"))

    assert Tournaments.running_tournament_names() == []
  end

  test "a running tournament does, and is named so the operator knows which" do
    tournament("Bruges Open", "running")

    assert Tournaments.running_tournament_names() == ["Bruges Open"]
  end

  test "several running tournaments all get named, in a stable order" do
    tournament("Ghent Rapid", "running")
    tournament("Antwerp Classic", "running")
    tournament("Finished one", "finished")

    # Sorted, not insertion-ordered: the operator reads this in a flash
    # message on a box that may host several events at once.
    assert Tournaments.running_tournament_names() == ["Antwerp Classic", "Ghent Rapid"]
  end
end
