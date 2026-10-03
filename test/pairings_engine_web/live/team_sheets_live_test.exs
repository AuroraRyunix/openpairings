defmodule PairingsEngineWeb.TeamSheetsLiveTest do
  @moduledoc """
  The team tables beside Standings - cross table, match sheets, rosters, board
  prizes - for a team round robin and a team Swiss with matches played, and
  the links to them from Standings and the Print page.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PairingsEngine.TeamSheetsFixtures

  alias PairingsEngine.Tournaments

  setup :register_and_log_in_user

  describe "cross table, round robin" do
    test "shows the grid with diagonal, scores and totals", %{conn: conn, scope: scope} do
      {t, m1} = played_round_robin(scope.user.id)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/team-sheets")

      assert has_element?(lv, "#team-cross-table")
      assert has_element?(lv, "#team-cross-table tbody tr", "T1")
      [a, b] = [m1.team_a_id, m1.team_b_id]
      assert has_element?(lv, "#team-cross-cell-#{a}-#{a}.team-cross-diag")
      # The 2-0: the winner's cell against the loser reads 2, the loser's 0.
      assert lv |> element("#team-cross-cell-#{a}-#{b}") |> render() =~ "2"
      assert lv |> element("#team-cross-cell-#{b}-#{a}") |> render() =~ "0"
      assert has_element?(lv, "#team-sheets-print[href='/t/#{t.id}/print/team-crosstable']")
    end
  end

  describe "cross table, Swiss" do
    test "has a cell per team and round", %{conn: conn, scope: scope} do
      {t, m1} = played_swiss(scope.user.id)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/team-sheets")

      assert has_element?(lv, "#team-cross-table")
      assert has_element?(lv, "#team-cross-row-#{m1.team_a_id}")
      assert has_element?(lv, "#team-cross-cell-#{m1.team_a_id}-r1", "2-0")
      assert has_element?(lv, "#team-cross-cell-#{m1.team_a_id}-r2")
      refute has_element?(lv, "#team-cross-cell-#{m1.team_a_id}-r3")
      # The opponent's number and board-1 colour: the winner had White.
      assert lv |> element("#team-cross-cell-#{m1.team_a_id}-r1") |> render() =~ "w"
    end
  end

  describe "match sheets" do
    test "lists the round's matches with a print link each", %{conn: conn, scope: scope} do
      {t, m1} = played_round_robin(scope.user.id)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/team-sheets/match-sheets")

      # Latest paired round by default; the picker offers every paired round.
      assert has_element?(lv, "#match-sheets-round-3")
      assert has_element?(lv, "#match-sheets tbody tr", "T")

      lv |> element("#match-sheets-round-1") |> render_click()
      assert has_element?(lv, "#match-sheet-row-#{m1.id}", "2 - 0")

      assert has_element?(
               lv,
               "#match-sheet-print-#{m1.id}[href='/t/#{t.id}/print/team-match-sheets?round=1&match=#{m1.id}']"
             )

      assert has_element?(
               lv,
               "#team-sheets-print[href='/t/#{t.id}/print/team-match-sheets?round=1']"
             )
    end
  end

  describe "rosters" do
    test "lists every team's board order", %{conn: conn, scope: scope} do
      {t, _} = played_swiss(scope.user.id)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/team-sheets/rosters")

      for team <- Tournaments.list_teams(t.id) do
        assert has_element?(lv, "#roster-#{team.id}", team.name)
        assert has_element?(lv, "#roster-#{team.id} tbody tr", "#{team.name} 1")
      end
    end
  end

  describe "board prizes" do
    test "ranks each board and filters by games", %{conn: conn, scope: scope} do
      {t, _} = played_round_robin(scope.user.id)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/team-sheets/board-prizes")

      assert has_element?(lv, "#board-prize-1")
      assert has_element?(lv, "#board-prize-2")
      assert has_element?(lv, "#board-prizes-min-games")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/team-sheets/board-prizes?min_games=99")
      assert has_element?(lv, "#board-prizes-empty")
      refute has_element?(lv, "#board-prize-1")
    end
  end

  describe "navigation" do
    test "Standings links to the four tabs for a team event", %{conn: conn, scope: scope} do
      {t, _} = played_swiss(scope.user.id)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/standings")

      assert has_element?(lv, "#team-sheets-link-cross-table")
      assert has_element?(lv, "#team-sheets-link-match-sheets")
      assert has_element?(lv, "#team-sheets-link-rosters")
      assert has_element?(lv, "#team-sheets-link-board-prizes")

      lv |> element("#team-sheets-link-rosters") |> render_click()
      assert_redirect(lv, ~p"/t/#{t.id}/team-sheets/rosters")
    end

    test "the Print page lists the four team documents", %{conn: conn, scope: scope} do
      {t, _} = played_swiss(scope.user.id)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/print")

      assert has_element?(lv, "#print-team-crosstable a[href='/t/#{t.id}/print/team-crosstable']")

      assert has_element?(
               lv,
               "#print-team-match-sheets a[href*='print/team-match-sheets?round=2']"
             )

      assert has_element?(lv, "#print-team-rosters a[href='/t/#{t.id}/print/team-rosters']")
      assert has_element?(lv, "#print-board-prizes a[href='/t/#{t.id}/print/board-prizes']")
    end

    test "an individual tournament is sent back to Standings", %{conn: conn, scope: scope} do
      {:ok, t} =
        Tournaments.create_tournament(scope, %{
          "name" => "Plain",
          "type" => "swiss",
          "rounds_count" => "3"
        })

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/t/#{t.id}/team-sheets")
      assert to == "/t/#{t.id}/standings"
    end
  end
end
