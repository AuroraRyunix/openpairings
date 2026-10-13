defmodule PairingsEngine.BoardLink.GoneGamesTest do
  @moduledoc """
  A game a board reported goes when its pairing goes
  (`PairingsEngine.BoardLink.prune_games/2`): one test per way a pairing can
  disappear, and one for the way it does not - a swap, which keeps the game.
  """
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.AccountsFixtures
  import PairingsEngine.BoardLinkFixtures

  alias PairingsEngine.{
    Audit,
    BoardLink,
    Handoff,
    Repo,
    Snapshots,
    TeamMatches,
    Tournaments
  }

  alias PairingsEngine.BoardLink.Game
  alias PairingsEngine.Tournaments.{Pairing, Round}

  setup do
    scope = user_scope_fixture()
    fixture = paired_tournament(scope)
    {:ok, link, _secret} = BoardLink.create_link(scope, fixture.tournament)
    fixture |> Map.put(:scope, scope) |> Map.put(:link, link)
  end

  defp report!(link, tournament, board, attrs \\ %{}) do
    {:ok, %{applied: true}} = BoardLink.report(link, tournament, report_for(board, attrs))
    :ok
  end

  defp removals(tournament_id) do
    tournament_id
    |> Audit.list_for_tournament(limit: 100)
    |> Enum.filter(&(&1.action == "boards.games_removed"))
  end

  defp repair!(tournament, players) do
    [a, b, c, d] = players
    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

    for {board, white, black} <- [{1, a, c}, {2, b, d}] do
      pairing =
        Repo.insert!(%Pairing{
          round_id: round.id,
          board: board,
          white_player_id: white.id,
          black_player_id: black.id
        })

      Repo.get!(Pairing, pairing.id)
    end
  end

  test "unpairing a round removes its games, and says how many", %{
    tournament: t,
    link: link,
    boards: [board1, board2],
    players: players
  } do
    report!(link, t, board1)
    report!(link, t, board2, %{"status" => "finished", "result" => "1-0"})
    assert map_size(BoardLink.summaries(t.id)) == 2

    assert :ok = PairingsEngine.Pairing.delete_round(t.id, 1)

    assert BoardLink.summaries(t.id) == %{}
    assert BoardLink.get_game(t.id, board1.game_uid) == nil
    assert [%{details: %{"count" => 2} = details}] = removals(t.id)
    # The count, and nothing of the game.
    refute Map.has_key?(details, "moves")

    # Paired again: other games, with other ids, and nothing left over to
    # show beside them.
    [new1, _new2] = repair!(t, players)
    refute new1.game_uid == board1.game_uid
    assert BoardLink.summaries(t.id) == %{}
    assert BoardLink.get_pairing(t.id, board1.game_uid) == nil
  end

  test "a round with no reported games leaves no line in the trail", %{tournament: t} do
    assert :ok = PairingsEngine.Pairing.delete_round(t.id, 1)
    assert removals(t.id) == []
  end

  test "deleting one board removes that board's game and no other", %{
    tournament: t,
    link: link,
    round: round,
    boards: [board1, board2]
  } do
    report!(link, t, board1)
    report!(link, t, board2)

    # The arbiter empties board 2, then deletes it.
    board2
    |> Ecto.Changeset.change(white_player_id: nil, black_player_id: nil, result: "")
    |> Repo.update!()

    round = Repo.preload(round, :pairings, force: true)
    vacant = Enum.find(round.pairings, &(&1.id == board2.id))
    assert {:ok, _} = Tournaments.delete_pairing(round, vacant)

    assert BoardLink.get_game(t.id, board2.game_uid) == nil
    assert %Game{} = BoardLink.get_game(t.id, board1.game_uid)
    assert [%{details: %{"count" => 1}}] = removals(t.id)
  end

  test "a game whose pairing survives a board swap is kept", %{
    tournament: t,
    link: link,
    boards: [board1, board2]
  } do
    report!(link, t, board1)

    # Board 1 and board 2 change places: the same two games on other seats.
    board1 |> Ecto.Changeset.change(board: 99) |> Repo.update!()
    board2 |> Ecto.Changeset.change(board: 1) |> Repo.update!()
    Repo.get!(Pairing, board1.id) |> Ecto.Changeset.change(board: 2) |> Repo.update!()

    assert BoardLink.prune_games(t.id) == 0
    assert %Game{moves: ["e4", "e5", "Nf3"]} = BoardLink.get_game(t.id, board1.game_uid)
    assert removals(t.id) == []
  end

  describe "restore points" do
    test "going back to before the round was paired removes the round's games", %{
      scope: scope,
      tournament: t,
      link: link,
      boards: [board1 | _],
      players: players
    } do
      assert :ok = PairingsEngine.Pairing.delete_round(t.id, 1)
      {:ok, empty} = Snapshots.capture(Repo.reload!(t), "snapshot.manual", scope)

      [new1 | _] = repair!(t, players)
      report!(link, Repo.reload!(t), new1)
      assert %Game{} = BoardLink.get_game(t.id, new1.game_uid)

      assert {:ok, _} = Snapshots.restore(Repo.reload!(t), empty.id, scope)

      assert BoardLink.get_game(t.id, new1.game_uid) == nil
      assert BoardLink.get_game(t.id, board1.game_uid) == nil
      assert [%{details: %{"count" => 1}, user_id: user_id}] = removals(t.id)
      assert user_id == scope.user.id
    end

    test "a point taken before a re-pairing brings the old pairings back with the games it held",
         %{scope: scope, tournament: t, link: link, boards: [board1 | _], players: players} do
      report!(link, t, board1, %{"seq" => 3, "moves" => ["d4", "d5"]})
      {:ok, before} = Snapshots.capture(Repo.reload!(t), "snapshot.manual", scope)

      # The board plays on, the round is unpaired, and paired again.
      report!(link, t, board1, %{"seq" => 9, "moves" => ["d4", "d5", "c4", "e6"]})
      assert :ok = PairingsEngine.Pairing.delete_round(t.id, 1)
      [new1 | _] = repair!(t, players)
      report!(link, Repo.reload!(t), new1)

      assert {:ok, _} = Snapshots.restore(Repo.reload!(t), before.id, scope)

      # The old game is back as the restore point held it - two moves, not
      # four: the four went when the round was unpaired - and the game of
      # the re-pairing is gone with its pairing.
      assert %Game{moves: ["d4", "d5"], seq: 3} = BoardLink.get_game(t.id, board1.game_uid)
      assert BoardLink.get_game(t.id, new1.game_uid) == nil
      assert BoardLink.get_pairing(t.id, board1.game_uid)

      # The box may send its fuller copy again under the same id, and it is
      # taken: a higher `seq` wins as it always did.
      back = BoardLink.get_pairing(t.id, board1.game_uid)

      assert {:ok, %{applied: true}} =
               BoardLink.report(
                 link,
                 Repo.reload!(t),
                 report_for(back, %{"seq" => 9, "moves" => ["d4", "d5", "c4", "e6"]})
               )
    end

    test "a game that outlived the restore point is not put back to an older copy", %{
      scope: scope,
      tournament: t,
      link: link,
      boards: [board1 | _]
    } do
      report!(link, t, board1, %{"seq" => 1})
      {:ok, point} = Snapshots.capture(Repo.reload!(t), "snapshot.manual", scope)

      report!(link, t, board1, %{
        "seq" => 5,
        "moves" => ["e4", "c5"],
        "status" => "finished",
        "result" => "0-1"
      })

      assert {:ok, _} = Snapshots.restore(Repo.reload!(t), point.id, scope)

      assert %Game{seq: 5, result: "0-1"} = BoardLink.get_game(t.id, board1.game_uid)
      assert removals(t.id) == []
    end
  end

  test "a returning hand-off file without the round takes the round's games with it", %{
    scope: scope,
    tournament: t,
    link: link,
    boards: [board1 | _]
  } do
    report!(link, t, board1)

    wire = fn payload -> payload |> Jason.encode!() |> Jason.decode!() end
    other = user_scope_fixture()

    {:ok, payload} = Handoff.hand_off(Repo.reload!(t), "the other laptop", scope)
    {:ok, copy} = Handoff.receive(wire.(payload), other)

    # On the other machine the round is unpaired before the file comes back.
    assert :ok = PairingsEngine.Pairing.delete_round(copy.id, 1)
    {:ok, back} = Handoff.return(Repo.reload!(copy), other)

    assert {:ok, _unlocked} = Handoff.release(Repo.reload!(t), wire.(back), scope)

    assert BoardLink.get_game(t.id, board1.game_uid) == nil
    assert [%{details: %{"count" => 1}}] = removals(t.id)
  end

  test "a team line-up that drops a board drops that board's game" do
    import PairingsEngine.TeamFixtures

    teams = for i <- 1..4, do: {"T#{i}", Enum.map(1..4, &(2000 - i * 10 - &1))}
    {t, _} = team_round_robin(teams, boards: 4)
    pair_next!(t)
    t = Repo.reload!(t)

    [match | _] =
      t.id |> Tournaments.get_round(1) |> Map.fetch!(:id) |> Tournaments.list_matches()

    boards =
      Repo.all(from p in Pairing, where: p.match_id == ^match.id, order_by: p.board)

    for board <- boards do
      Repo.insert!(%Game{tournament_id: t.id, game_uid: board.game_uid, moves: ["e4"]})
    end

    %{a: a, b: b} = TeamMatches.lineups(t, match)
    {:ok, _} = TeamMatches.set_lineups(t, match, Enum.take(a, 3), Enum.take(b, 3))

    left = Repo.all(from p in Pairing, where: p.match_id == ^match.id, select: p.game_uid)
    held = t.id |> BoardLink.games_by_uid() |> Map.keys()

    assert Enum.sort(held) == Enum.sort(left)

    assert length(left) < length(boards)
    assert [%{details: %{"count" => count}}] = removals(t.id)
    assert count == length(boards) - length(left)
  end
end
