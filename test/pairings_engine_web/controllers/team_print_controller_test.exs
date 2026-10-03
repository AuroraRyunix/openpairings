defmodule PairingsEngineWeb.TeamPrintControllerTest do
  @moduledoc """
  The team print documents: cross table, match result sheets, rosters and
  board prizes, for a team round robin and a team Swiss with matches played.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import PairingsEngine.TeamSheetsFixtures

  alias PairingsEngine.{Repo, Tournaments}

  setup :register_and_log_in_user

  defp page(conn, path) do
    html = conn |> get(path) |> html_response(200)
    {html, LazyHTML.from_document(html)}
  end

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()
  defp text(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text()

  describe "team cross table, round robin" do
    test "is a team x team grid with the scores and the totals", %{conn: conn, scope: scope} do
      {t, m1} = played_round_robin(scope.user.id)
      {_html, doc} = page(conn, ~p"/t/#{t.id}/print/team-crosstable")

      assert count(doc, "table#team-cross-table") == 1
      assert count(doc, "table#team-cross-table tbody tr") == 4
      assert count(doc, "table#team-cross-table td.tc-diag") == 4
      # No., team, one column per team, MP, GP, rank.
      assert count(doc, "table#team-cross-table thead th") == 2 + 4 + 3

      # The 2-0 match: its team_a scored 2 against the other.
      row_a = text(doc, "tbody tr:nth-child(#{team_row(t, m1.team_a_id)})")
      assert row_a =~ "2"
      # Pairings not yet played are dots.
      assert text(doc, "table#team-cross-table") =~ "·"
    end
  end

  describe "team cross table, Swiss" do
    test "has a row per team with opponent, colour, score and running match points",
         %{conn: conn, scope: scope} do
      {t, _m1} = played_swiss(scope.user.id)
      {html, doc} = page(conn, ~p"/t/#{t.id}/print/team-crosstable")

      assert count(doc, "table#team-cross-table tbody tr") == 4
      # Rank, No., team, two round columns, MP, GP.
      assert count(doc, "table#team-cross-table thead th") == 3 + 2 + 2
      assert count(doc, "table#team-cross-table td.tc-round .tc-opp") == 8
      assert html =~ "Team cross table after round 2"
      assert text(doc, "td.tc-round .tc-opp") =~ ~r/\d [wb]/
      assert text(doc, "table#team-cross-table") =~ "2-0"
      assert text(doc, "table#team-cross-table") =~ "MP 2"
    end
  end

  describe "match result sheets" do
    test "one A4 page per match of the round, filled where results are in",
         %{conn: conn, scope: scope} do
      {t, m1} = played_round_robin(scope.user.id)
      {_html, doc} = page(conn, ~p"/t/#{t.id}/print/team-match-sheets?round=1")

      assert count(doc, "section.match-sheet") == 2
      sheet = "section#match-sheet-#{m1.id}"
      assert count(doc, "#{sheet} table.ms-boards tbody tr") == 2
      assert text(doc, "#{sheet} .ms-total .ms-result") =~ "2 - 0"
      assert text(doc, "#{sheet} table.ms-boards .ms-result") =~ "1 - 0"
      # Both captains and the arbiter sign.
      assert count(doc, "#{sheet} .ms-sig") == 3
      assert text(doc, sheet) =~ "White"
      assert text(doc, sheet) =~ "Black"
      assert text(doc, sheet) =~ "1990"
    end

    test "a round with nothing entered has empty result boxes", %{conn: conn, scope: scope} do
      {t, _} = played_round_robin(scope.user.id)
      {_html, doc} = page(conn, ~p"/t/#{t.id}/print/team-match-sheets?round=3")

      assert count(doc, "section.match-sheet") == 2
      assert doc |> LazyHTML.query(".ms-result") |> LazyHTML.text() |> String.trim() == ""
    end

    test "?match prints a single match; unknown round or match is a 404",
         %{conn: conn, scope: scope} do
      {t, m1} = played_swiss(scope.user.id)
      {_html, doc} = page(conn, ~p"/t/#{t.id}/print/team-match-sheets?round=1&match=#{m1.id}")
      assert count(doc, "section.match-sheet") == 1

      conn |> get(~p"/t/#{t.id}/print/team-match-sheets?round=1&match=999999") |> response(404)
      conn |> get(~p"/t/#{t.id}/print/team-match-sheets?round=9") |> response(404)
    end

    test "defaults to the latest paired round", %{conn: conn, scope: scope} do
      {t, _} = played_swiss(scope.user.id)
      {html, _doc} = page(conn, ~p"/t/#{t.id}/print/team-match-sheets")
      assert html =~ "Match result sheets - round 2"
    end
  end

  describe "rosters" do
    test "lists each team in board order with ratings, FIDE ID and federation",
         %{conn: conn, scope: scope} do
      {t, _} = played_swiss(scope.user.id)

      player = t.id |> Tournaments.list_players() |> Enum.find(&(&1.name == "T1 1"))
      Repo.update!(Ecto.Changeset.change(player, fide_id: 1_234_567, federation: "BEL"))

      {_html, doc} = page(conn, ~p"/t/#{t.id}/print/team-rosters")
      assert count(doc, "section.roster") == 4
      assert count(doc, "section.roster tbody tr") == 8

      team = t.id |> Tournaments.list_teams() |> Enum.find(&(&1.name == "T1"))
      roster = "section#roster-#{team.id}"
      assert text(doc, roster) =~ "1234567"
      assert text(doc, roster) =~ "BEL"
      assert text(doc, roster) =~ "1980"

      {_html, one} = page(conn, ~p"/t/#{t.id}/print/team-rosters?team=#{team.id}")
      assert count(one, "section.roster") == 1
      conn |> get(~p"/t/#{t.id}/print/team-rosters?team=999999") |> response(404)
    end

    test "keeps a withdrawn player on the list, marked", %{conn: conn, scope: scope} do
      {t, _} = played_round_robin(scope.user.id)
      player = t.id |> Tournaments.list_players() |> Enum.find(&(&1.name == "T2 2"))
      Repo.update!(Ecto.Changeset.change(player, status: "withdrawn"))

      {_html, doc} = page(conn, ~p"/t/#{t.id}/print/team-rosters")
      assert count(doc, "section.roster tbody tr") == 8
      assert text(doc, "section.roster .out") =~ "withdrawn"
    end
  end

  describe "board prizes" do
    test "ranks the players of each board by percentage", %{conn: conn, scope: scope} do
      {t, m1} = played_round_robin(scope.user.id)
      {_html, doc} = page(conn, ~p"/t/#{t.id}/print/board-prizes")

      assert count(doc, "section.prize-board") == 2
      assert count(doc, "section#prize-board-1 tbody tr") >= 2
      # The 2-0 team's board-1 player scored 100% and is first on board 1.
      first = text(doc, "section#prize-board-1 tbody tr:first-child")
      assert first =~ "100"
      assert first =~ Tournaments.get_team(t.id, m1.team_a_id).name
    end

    test "?min_games leaves out players with fewer games", %{conn: conn, scope: scope} do
      {t, _} = played_round_robin(scope.user.id)
      {_html, all} = page(conn, ~p"/t/#{t.id}/print/board-prizes")
      {_html, few} = page(conn, ~p"/t/#{t.id}/print/board-prizes?min_games=2")

      assert count(all, "section.prize-board tbody tr") >
               count(few, "section.prize-board tbody tr")
    end
  end

  describe "a tournament that is not a team event" do
    test "answers 404 for all four documents", %{conn: conn, scope: scope} do
      {:ok, t} =
        Tournaments.create_tournament(scope, %{
          "name" => "Plain",
          "type" => "swiss",
          "rounds_count" => "3"
        })

      for path <- ~w(team-crosstable team-match-sheets team-rosters board-prizes) do
        conn |> get("/t/#{t.id}/print/#{path}") |> response(404)
      end
    end
  end

  # 1-based position of a team's row in the round-robin grid (team-number order).
  defp team_row(t, team_id) do
    t.id |> Tournaments.list_teams() |> Enum.find_index(&(&1.id == team_id)) |> Kernel.+(1)
  end
end
