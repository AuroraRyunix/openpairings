defmodule PairingsEngineWeb.TeamLineupsLiveTest do
  @moduledoc """
  The pages around team events without players and the team rating: the
  Settings card, the Teams page's rating and team absence, the match page's
  match score, and the pages and prints a team event with empty boards
  renders.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{Audit, Repo, TeamMatches, Tournaments}
  alias PairingsEngine.Tournaments.Pairing

  @moduletag :capture_log

  setup :register_and_log_in_user

  @dates ~w(2026-10-01 2026-10-02 2026-10-03)

  defp no_players(n), do: for(i <- 1..n, do: {"T#{i}", []})

  defp optional_swiss(scope, n \\ 4) do
    {t, teams} =
      team_swiss(no_players(n),
        boards: 4,
        rounds: 3,
        team_lineups: "optional",
        round_dates: @dates,
        user_id: scope.user.id
      )

    {t, teams}
  end

  defp first_match(t) do
    round = Tournaments.get_round(t.id, 1)
    round.id |> Tournaments.list_matches() |> Enum.find(& &1.team_b_id)
  end

  describe "Settings - Options - Teams" do
    test "saves the line-ups and the rating method", %{conn: conn, scope: scope} do
      {t, _} = team_swiss([{"A", [2000]}, {"B", [1900]}], user_id: scope.user.id)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/options")

      assert has_element?(lv, "#team-settings-form #team-lineups")
      assert has_element?(lv, "#team-settings-form #team-rating-method")

      lv
      |> form("#team-settings-form", %{
        "tournament" => %{"team_lineups" => "optional", "team_rating_method" => "roster"}
      })
      |> render_submit()

      t = Repo.reload!(t)
      assert {t.team_lineups, t.team_rating_method} == {"optional", "roster"}
    end

    test "is not shown for an individual tournament", %{conn: conn, scope: scope} do
      {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Open", "type" => "swiss"})
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/options")
      refute has_element?(lv, "#team-settings-form")
    end

    test "the line-ups lock once round 1 is paired", %{conn: conn, scope: scope} do
      {t, _} = optional_swiss(scope)
      pair_next!(t)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/options")
      assert has_element?(lv, "#team-lineups[disabled]")
    end
  end

  describe "the Teams page" do
    test "shows each team's rating and takes one typed in", %{conn: conn, scope: scope} do
      {t, [a, b]} =
        team_swiss([{"A", [2400, 2200]}, {"B", []}], boards: 2, user_id: scope.user.id)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/teams")
      assert has_element?(lv, "#team-rating-#{a.id}", "Team rating: 2300")
      assert has_element?(lv, "#team-rating-#{b.id}", "Team rating: none")
      assert has_element?(lv, "#team-rating-method")

      lv
      |> form("#edit-team-#{b.id}", %{"team" => %{"name" => "B", "rating_override" => "2050"}})
      |> render_submit()

      assert Repo.reload!(b).rating_override == 2050
      assert has_element?(lv, "#team-rating-#{b.id}", "Team rating: 2050")
    end

    test "marks a team absent for a round not yet paired, and back", %{conn: conn, scope: scope} do
      {t, [a | _]} = optional_swiss(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/teams")

      lv |> element("#team-absent-#{a.id}-2") |> render_click()
      assert Repo.reload!(a).absent_rounds == [2]
      assert has_element?(lv, "#team-absent-#{a.id}-2[aria-pressed='true']")
      # The coloured button says it; the text line is only for paired rounds.
      refute has_element?(lv, "#team-absent-rounds-#{a.id}")
      assert Enum.any?(Audit.list_for_tournament(t.id), &(&1.action == "team.absence_changed"))

      lv |> element("#team-absent-#{a.id}-2") |> render_click()
      assert Repo.reload!(a).absent_rounds == []
    end
  end

  describe "the match page" do
    test "a match nobody sits at takes a match score, and gives it back", %{
      conn: conn,
      scope: scope
    } do
      {t, _} = optional_swiss(scope)
      pair_next!(t)
      match = first_match(t)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings/1/matches/#{match.id}")
      assert has_element?(lv, "#lineups-optional-hint")

      lv
      |> form("#match-score-form", %{"score" => %{"a" => "2½", "b" => "1,5"}})
      |> render_submit()

      match = Repo.reload!(match)
      assert {match.match_score_a, match.match_score_b} == {2.5, 1.5}
      assert has_element?(lv, "#match-score-set")
      assert Enum.any?(Audit.list_for_tournament(t.id), &(&1.action == "pairing.match_score_set"))

      lv |> element("#clear-match-score") |> render_click()
      refute TeamMatches.match_score?(Repo.reload!(match))

      assert Repo.all(from p in Pairing, where: p.match_id == ^match.id, select: p.result)
             |> Enum.all?(&(&1 == ""))
    end

    test "a score that does not add up is refused with the reason", %{conn: conn, scope: scope} do
      {t, _} = optional_swiss(scope)
      pair_next!(t)
      match = first_match(t)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings/1/matches/#{match.id}")

      html =
        lv
        |> form("#match-score-form", %{"score" => %{"a" => "3", "b" => "3"}})
        |> render_submit()

      assert html =~ "add up to the number of boards"
      refute TeamMatches.match_score?(Repo.reload!(match))
    end

    test "is not offered with required line-ups", %{conn: conn, scope: scope} do
      {t, _} =
        team_swiss([{"A", [2000]}, {"B", [1900]}], boards: 1, rounds: 1, user_id: scope.user.id)

      pair_next!(t)
      match = first_match(t)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings/1/matches/#{match.id}")
      refute has_element?(lv, "#match-score")
    end
  end

  describe "a team event with empty boards renders" do
    test "the Pairings, Standings and team pages, and the team prints", %{
      conn: conn,
      scope: scope
    } do
      {t, _} = optional_swiss(scope)
      pair_next!(t)
      match = first_match(t)
      {:ok, _} = TeamMatches.set_match_score(t, match, 3, 1)

      {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings")
      assert html =~ "T1"
      {:ok, _lv, _html} = live(conn, ~p"/t/#{t.id}/standings")
      {:ok, _lv, _html} = live(conn, ~p"/t/#{t.id}/team-sheets")

      for path <- [
            ~p"/t/#{t.id}/print/team-pairings?round=1",
            ~p"/t/#{t.id}/print/team-match-sheets?round=1",
            ~p"/t/#{t.id}/print/team-standings",
            ~p"/t/#{t.id}/print/team-crosstable"
          ] do
        assert conn |> get(path) |> html_response(200)
      end
    end

    test "the Export page warns in FIDE mode about boards without two players", %{
      conn: conn,
      scope: scope
    } do
      {t, _} = optional_swiss(scope)
      pair_next!(t)
      t = Repo.reload!(t)

      assert PairingsEngine.Compliance.fide_mode?(t)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/export")
      assert has_element?(lv, "#trf-empty-boards-warning", "round 1: 8 boards")

      # Outside FIDE mode nothing is reported to FIDE from it: no warning.
      {:ok, _} = Tournaments.leave_fide_mode(t)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/export")
      refute has_element?(lv, "#trf-empty-boards-warning")
    end
  end
end
