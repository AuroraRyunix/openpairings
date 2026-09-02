defmodule PairingsEngine.ResultsImportFrozenTest do
  @moduledoc """
  Importing a round's results into a tournament that has gone read-only.

  `apply_import/3` has no gate of its own; it relies on
  `Tournaments.update_pairing_result/2` refusing inside the transaction and
  then words the rollback afterwards. That worked for one reason only,
  because only one reason had a clause: `{:error, :archived}`. A
  `{:error, :handed_off}` fell to the changeset branch, where
  `changeset_error_text/1` calls `changeset.errors` on it - which parses as
  a remote call to `:handed_off.errors/0` and takes the page down instead of
  refusing.

  Same shape as the crash `SettingsSupport.error_text/1` was given an atom
  clause for; the same fix, at the other end of the same write.
  """
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Repo, ResultsImport, Tournaments}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round}

  defp fixture do
    scope = user_scope_fixture()

    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Frozen Import",
        "type" => "swiss",
        "rounds_count" => "3"
      })

    [a, b] =
      for name <- ["A", "B"] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name})
      end

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

    pairing =
      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: a.id,
        black_player_id: b.id,
        result: ""
      })

    {Tournaments.get_tournament!(tournament.id), pairing}
  end

  test "a handed-off tournament refuses in words rather than crashing" do
    {tournament, pairing} = fixture()
    {:ok, handed} = Tournaments.hand_off(tournament, "the club PC")

    assert {:error, [message]} = ResultsImport.apply_import(handed, 1, [{1, "1-0"}])

    assert message =~ "handed off"
    assert message =~ "take it back"
    assert Repo.reload!(pairing).result == ""
  end

  test "an archived tournament still refuses, and still says archived" do
    {tournament, pairing} = fixture()
    {:ok, archived} = Tournaments.archive_tournament(tournament)

    assert {:error, [message]} = ResultsImport.apply_import(archived, 1, [{1, "1-0"}])

    assert message =~ "archived"
    assert message =~ "unarchive"
    assert Repo.reload!(pairing).result == ""
  end

  test "and the import goes through once it is back" do
    {tournament, pairing} = fixture()
    {:ok, handed} = Tournaments.hand_off(tournament, "the club PC")
    {:ok, back} = Tournaments.take_back(handed, handed.handoff_token)

    assert {:ok, 1} = ResultsImport.apply_import(back, 1, [{1, "1-0"}])
    assert Repo.reload!(pairing).result == "1-0"
  end
end
