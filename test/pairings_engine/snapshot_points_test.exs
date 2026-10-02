defmodule PairingsEngine.SnapshotPointsTest do
  @moduledoc """
  `tournament.scoring`, `boards[].points` and `boards[].postponed_as` in the
  OpenResults snapshot contract (OpenResults' docs/snapshot-schema.md,
  "tournament.scoring" and "boards[].points"): the point system and the
  per-game figures, so the results site never reads points off a result token.
  """
  use PairingsEngine.DataCase, async: true

  import PairingsEngine.SnapshotFixtures, only: [swiss_fixture: 0]

  alias PairingsEngine.{Repo, Snapshot}
  alias PairingsEngine.Tournaments.Pairing

  @scoring_keys ~w(bye draw forfeit_loss forfeit_win loss presence win)

  defp round_of(snapshot, number), do: Enum.find(snapshot["rounds"], &(&1["number"] == number))

  defp board_of(snapshot, round, no),
    do: Enum.find(round_of(snapshot, round)["boards"], &(&1["board"] == no))

  defp three_one_nil(tournament) do
    tournament
    |> Ecto.Changeset.change(points_win: 3.0, points_draw: 1.0, points_loss: 0.0, bye_value: 3.0)
    |> Repo.update!()
  end

  # Round 3's board 3 (8 v 5) has no result in the fixture. Postpone it with
  # the outcomes the arbiter froze when they postponed it.
  defp postpone_round3_board3(tournament, white, black) do
    pairing =
      Repo.get_by!(Pairing,
        round_id: Enum.find(Repo.preload(tournament, :rounds).rounds, &(&1.number == 3)).id,
        board: 3
      )

    pairing
    |> Ecto.Changeset.change(result: "*", provisional_white: white, provisional_black: black)
    |> Repo.update!()
  end

  describe "tournament.scoring" do
    test "carries the tournament's own point system, in the documented shape" do
      {tournament, _} = swiss_fixture()
      tournament = three_one_nil(tournament)

      scoring = Snapshot.build(tournament)["tournament"]["scoring"]

      assert scoring |> Map.keys() |> Enum.sort() == @scoring_keys

      assert %{
               "win" => 3.0,
               "draw" => 1.0,
               "loss" => 0.0,
               "bye" => 3.0,
               "forfeit_win" => 3.0,
               "forfeit_loss" => 0.0,
               "presence" => nil
             } == scoring
    end

    test "every value is a number, apart from a presence point that may be null" do
      {tournament, _} = swiss_fixture()

      for presence <- [nil, 1.0] do
        tournament =
          tournament |> Ecto.Changeset.change(presence_value: presence) |> Repo.update!()

        scoring = Snapshot.build(tournament)["tournament"]["scoring"]

        for {key, value} <- Map.delete(scoring, "presence"), do: assert(is_number(value), key)
        assert scoring["presence"] == presence
      end
    end
  end

  describe "boards[].points" do
    test "a played board carries what each seat scored under the default system" do
      {tournament, _} = swiss_fixture()
      snapshot = Snapshot.build(tournament)

      assert board_of(snapshot, 1, 1)["points"] == %{"white" => 1.0, "black" => 0.0}
      assert board_of(snapshot, 1, 3)["points"] == %{"white" => 0.5, "black" => 0.5}
      # A forfeit pays the winner the win value.
      assert board_of(snapshot, 1, 4)["points"] == %{"white" => 1.0, "black" => 0.0}
    end

    test "follows the tournament's point system, not the result token" do
      {tournament, _} = swiss_fixture()
      snapshot = tournament |> three_one_nil() |> Snapshot.build()

      assert board_of(snapshot, 1, 1)["points"] == %{"white" => 3.0, "black" => 0.0}
      assert board_of(snapshot, 1, 3)["points"] == %{"white" => 1.0, "black" => 1.0}
      assert board_of(snapshot, 1, 4)["points"] == %{"white" => 3.0, "black" => 0.0}
    end

    test "a board with no result and no postponement has no points" do
      {tournament, _} = swiss_fixture()
      board = tournament |> Snapshot.build() |> board_of(3, 3)

      assert board["result"] == nil
      refute Map.has_key?(board, "points")
      refute Map.has_key?(board, "postponed_as")
    end

    test "a postponed board carries what it is credited with, and why" do
      {tournament, _} = swiss_fixture()
      postpone_round3_board3(tournament, "win", "loss")

      board = tournament |> three_one_nil() |> Snapshot.build() |> board_of(3, 3)

      assert board["postponed"] == true
      assert board["result"] == nil
      assert board["points"] == %{"white" => 3.0, "black" => 0.0}
      assert board["postponed_as"] == %{"white" => "win", "black" => "loss"}
    end

    test "a postponed board nobody valued counts as a draw" do
      {tournament, _} = swiss_fixture()
      postpone_round3_board3(tournament, nil, nil)

      board = tournament |> Snapshot.build() |> board_of(3, 3)

      assert board["points"] == %{"white" => 0.5, "black" => 0.5}
      assert board["postponed_as"] == %{"white" => "draw", "black" => "draw"}
    end

    test "withheld with the result when the round's results are not public" do
      {tournament, _} = swiss_fixture()
      postpone_round3_board3(tournament, "win", "loss")

      tournament
      |> Repo.preload(:rounds)
      |> Map.fetch!(:rounds)
      |> Enum.find(&(&1.number == 3))
      |> Ecto.Changeset.change(results_public: false)
      |> Repo.update!()

      round = tournament |> Snapshot.build() |> round_of(3)

      assert round["results_public"] == false

      for board <- round["boards"] do
        refute Map.has_key?(board, "points")
        refute Map.has_key?(board, "postponed_as")
      end
    end

    test "every emitted board matches the documented schema" do
      {tournament, _} = swiss_fixture()
      postpone_round3_board3(tournament, "loss", "draw")
      snapshot = tournament |> three_one_nil() |> Snapshot.build()

      for round <- snapshot["rounds"], board <- round["boards"] do
        case Map.fetch(board, "points") do
          {:ok, points} ->
            assert points |> Map.keys() |> Enum.sort() == ["black", "white"]
            assert Enum.all?(Map.values(points), &is_number/1)

          :error ->
            assert is_nil(board["result"]) and not Map.has_key?(board, "postponed")
        end

        case Map.fetch(board, "postponed_as") do
          {:ok, valuation} ->
            assert board["postponed"] == true
            assert valuation |> Map.keys() |> Enum.sort() == ["black", "white"]
            assert Enum.all?(Map.values(valuation), &(&1 in ["win", "draw", "loss"]))

          :error ->
            refute board["postponed"]
        end
      end
    end

    test "the published figures add up to the published standings points" do
      {tournament, _} = swiss_fixture()
      snapshot = tournament |> three_one_nil() |> Snapshot.build()
      after_round = snapshot["standings"]["after_round"]

      for row <- snapshot["standings"]["rows"] do
        from_boards =
          for round <- snapshot["rounds"],
              round["number"] <= after_round,
              board <- round["boards"],
              side <- ["white", "black"],
              board[side] == row["player"],
              do: board["points"][side]

        from_byes =
          for round <- snapshot["rounds"],
              round["number"] <= after_round,
              bye <- round["byes"],
              bye["player"] == row["player"],
              do: bye["points"]

        assert Enum.sum(from_boards ++ from_byes) == row["points"],
               "player #{row["player"]}"
      end
    end
  end
end
