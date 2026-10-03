defmodule PairingsEngine.TeamSheetsTest do
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.TeamSheetsFixtures

  alias PairingsEngine.{TeamSheets, TeamStandings}

  test "points_text writes halves the chess way" do
    assert TeamSheets.points_text(nil) == ""
    assert TeamSheets.points_text(0.0) == "0"
    assert TeamSheets.points_text(0.5) == "½"
    assert TeamSheets.points_text(2.5) == "2½"
    assert TeamSheets.points_text(3.0) == "3"
    assert TeamSheets.points_text(3) == "3"
    assert TeamSheets.points_text(0.25) == "0.25"
  end

  describe "cross_table/1" do
    test "round robin: a cell per pair, totals from the team standings" do
      {t, m1} = played_round_robin(nil)
      cross = TeamSheets.cross_table(t)

      assert cross.kind == :round_robin
      assert length(cross.teams) == 4

      winner = Enum.find(cross.teams, &(&1.team.id == m1.team_a_id))
      assert [%{gp: 2.0, opp_gp: opp}] = winner.cells[m1.team_b_id]
      assert opp == 0.0

      standings = Map.new(TeamStandings.standings(t), &{&1.team.id, &1})

      for row <- cross.teams do
        assert row.mp == standings[row.team.id].mp
        assert row.gp == standings[row.team.id].gp
        assert row.rank == standings[row.team.id].rank
      end
    end

    test "Swiss: rows in rank order with a running match-point total" do
      {t, _} = played_swiss(nil)
      cross = TeamSheets.cross_table(t)

      assert cross.kind == :swiss
      assert cross.rounds == 2
      assert Enum.map(cross.rows, & &1.rank) == [1, 2, 3, 4]

      for row <- cross.rows do
        assert length(row.rounds) == 2
        last = List.last(row.rounds)
        assert last.mp_total == row.mp
        assert last.colour in [:white, :black]
      end
    end
  end

  describe "board_prizes/2" do
    test "groups by board and shares a rank between equal scores" do
      {t, _} = played_round_robin(nil)
      boards = TeamSheets.board_prizes(t)

      assert Enum.map(boards, & &1.board) == [1, 2]

      for %{rows: rows} <- boards do
        pcts = Enum.map(rows, & &1.stat.percentage)
        assert pcts == Enum.sort(pcts, :desc)
        assert hd(rows).rank == 1
      end

      assert TeamSheets.board_prizes(t, min_games: 5) == []
    end
  end

  describe "match_sheets/3" do
    test "one sheet per match, byes left out" do
      {t, m1} = played_round_robin(nil)
      assert {:ok, %{round: 1, sheets: sheets}} = TeamSheets.match_sheets(t, 1)
      assert length(sheets) == 2

      assert {:ok, %{sheets: [one]}} = TeamSheets.match_sheets(t, 1, match_id: m1.id)
      assert one.team_a.id == m1.team_a_id
      assert Enum.map(one.rows, & &1.a_colour) == [:white, :black]

      assert TeamSheets.match_sheets(t, 7) == :error
      assert TeamSheets.match_sheets(t, 1, match_id: 0) == :error
    end
  end
end
