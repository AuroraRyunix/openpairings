defmodule PairingsEngine.SyncYieldsToRoundTest do
  @moduledoc """
  `PairingsEngine.Tournaments.running_tournament_names/0` names the
  tournaments that are paired but not yet fully scored.

  Once also read by `PairingsEngineWeb.FideLive` before a rating-list sync -
  that use was removed in favour of a narrower "was a result entered in the
  last couple of minutes" check (a former `recently_scored_tournament_names/1`
  on `PairingsEngine.Tournaments`), because "paired, not yet fully scored" is
  true for most of a season on a club installation, which made that
  confirmation fire on nearly every press. That narrower check was in turn
  removed entirely once the FIDE sync's own write lock dropped to sub-second
  (see `PairingsEngine.Fide.Sync.do_import_list/4` and
  `PairingsEngineWeb.FideLive.start_fide_sync/1`) - there is no sync
  confirmation left for either function to feed.

  Its one remaining caller is `PairingsEngine.Updates.notice_for_render/0`:
  installing an update restarts the whole app, which is disruptive to a
  tournament in progress no matter how long ago its last result was entered,
  so the broad question is the right one there.
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

  test "no tournaments at all means nothing to warn an update about" do
    assert Tournaments.running_tournament_names() == []
  end

  test "a tournament still in setup is not named" do
    tournament("Not started yet", "setup")
    assert Tournaments.running_tournament_names() == []
  end

  test "a finished tournament is not named" do
    tournament("Last month", "finished")
    assert Tournaments.running_tournament_names() == []
  end

  test "scoring the last round drops it from the list" do
    t = tournament("Bruges Open", "running")
    assert Tournaments.running_tournament_names() == ["Bruges Open"]

    # The guard reads live status rather than a cached flag, so finishing the
    # event is all it takes - nobody has to remember to unblock anything.
    Repo.update!(Ecto.Changeset.change(t, status: "finished"))

    assert Tournaments.running_tournament_names() == []
  end

  test "a running tournament is named so the operator knows which" do
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
