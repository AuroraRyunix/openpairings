defmodule PairingsEngineWeb.TeamsLiveTest do
  # Sequential SQLite writes plus self-broadcast/render draining.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{Audit, Repo, Tournaments}
  alias PairingsEngineWeb.A11y

  @moduletag :capture_log

  setup :register_and_log_in_user

  defp team_tournament(scope) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "League",
        "type" => "team-roundrobin",
        "pairing_system" => "round_robin",
        "rounds_count" => "3"
      })

    t
  end

  defp player(t, name, rating) do
    {:ok, p} = Tournaments.create_player(t.id, %{"name" => name, "fide_rating" => "#{rating}"})
    p
  end

  # The same rules the accessibility pass holds every page to, on the
  # connected render (a fragment inside the layout).
  #
  # `extra_skip` is for a page whose EXISTING markup the accessibility pass
  # does not enforce yet (the Pairings board table's header scopes and
  # caption - see `@not_enforced` in AccessibilityTest). The team markup
  # itself is held to every rule.
  defp assert_accessible(html, extra_skip \\ []) do
    violations =
      A11y.audit(
        ~s(<!DOCTYPE html><html lang="en"><head><title>t</title></head><body>#{html}</body></html>),
        skip: [:skip_link, :main, :one_h1, :lang, :title] ++ extra_skip
      )

    assert violations == [], A11y.explain(violations)
  end

  describe "the Teams page" do
    test "is a tab next to Players for a team tournament only", %{conn: conn, scope: scope} do
      t = team_tournament(scope)
      {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/players")
      assert html =~ ~s(href="/t/#{t.id}/teams")

      {:ok, swiss} = Tournaments.create_tournament(scope, %{"name" => "Open", "type" => "swiss"})
      {:ok, _lv, html} = live(conn, ~p"/t/#{swiss.id}/players")
      refute html =~ ~s(href="/t/#{swiss.id}/teams")

      {:ok, _lv, html} = live(conn, ~p"/t/#{swiss.id}/teams")
      assert html =~ "Teams are for team tournaments"
    end

    test "creates, renames and deletes a team, and records each in the audit trail", %{
      conn: conn,
      scope: scope
    } do
      t = team_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/teams")

      html =
        lv
        |> form("#create-team-form",
          team: %{name: "Brugse SK", short_name: "BSK", captain: "Jan"}
        )
        |> render_submit()

      assert html =~ "Team Brugse SK added."
      [team] = Tournaments.list_teams(t.id)

      assert {team.name, team.short_name, team.captain, team.seed} ==
               {"Brugse SK", "BSK", "Jan", 1}

      html =
        lv
        |> form("#edit-team-#{team.id}", team: %{name: "Brugse Schaakkring"})
        |> render_submit()

      assert html =~ "Team Brugse Schaakkring saved."

      html = lv |> element("#team-#{team.id} button", "Delete") |> render_click()
      assert html =~ "Team Brugse Schaakkring deleted."
      assert Tournaments.list_teams(t.id) == []

      actions = t.id |> Audit.list_for_tournament() |> Enum.map(& &1.action)
      assert "team.created" in actions
      assert "team.updated" in actions
      assert "team.deleted" in actions
    end

    test "adds players, sets the board order from the keyboard buttons, and removes a player", %{
      conn: conn,
      scope: scope
    } do
      t = team_tournament(scope)
      {:ok, team} = Tournaments.create_team(t, %{"name" => "Deurne"})
      anna = player(t, "Anna", 2000)
      bram = player(t, "Bram", 1900)

      {:ok, lv, html} = live(conn, ~p"/t/#{t.id}/teams")
      assert html =~ "No players on this team yet."

      for p <- [anna, bram] do
        lv
        |> form("#add-player-#{team.id}", %{player_id: p.id})
        |> render_submit()
      end

      assert Tournaments.team_roster(t.id, team.id) |> Enum.map(& &1.name) == ["Anna", "Bram"]

      html =
        lv
        |> element(~s(button[aria-label="Move Bram to a higher board"]))
        |> render_click()

      assert html =~ "Bram moved to a higher board."
      assert Tournaments.team_roster(t.id, team.id) |> Enum.map(& &1.name) == ["Bram", "Anna"]

      html = lv |> element(~s(button[aria-label="Take Anna off Deurne"])) |> render_click()
      assert html =~ "Anna taken off the team."
      assert Repo.reload!(anna).team_id == nil

      assert_accessible(render(lv))
    end

    test "orders the teams by hand or by rating, and freezes the order once paired", %{
      conn: conn,
      scope: scope
    } do
      {t, [weak, strong]} =
        team_round_robin([{"Weak", [1500, 1500]}, {"Strong", [2200, 2100]}],
          user_id: scope.user.id
        )

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/teams")

      lv |> element("button", "Order by rating") |> render_click()
      assert Tournaments.list_teams(t.id) |> Enum.map(& &1.id) == [strong.id, weak.id]

      lv |> element(~s(button[aria-label="Move Weak up the order"])) |> render_click()
      assert Tournaments.list_teams(t.id) |> Enum.map(& &1.id) == [weak.id, strong.id]

      pair_all!(t)
      html = render(lv)

      assert html =~ "Frozen: the order below became the teams&#39; pairing numbers"
      refute html =~ "Order by rating"
      refute html =~ ~s(aria-label="Move Weak up the order")
      refute html =~ ~s(aria-label="Delete Weak")
    end

    test "boards per match saves before pairing and locks after", %{conn: conn, scope: scope} do
      {t, _} = team_round_robin([{"A", [2000]}, {"B", [1900]}], user_id: scope.user.id)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/teams")

      lv |> form("#team-boards-form", tournament: %{team_boards: "6"}) |> render_submit()
      assert Repo.reload!(t).team_boards == 6

      pair_all!(Repo.reload!(t))
      html = render(lv)
      assert html =~ "Locked: round 1 has been paired."

      render_submit(lv, "save_boards", %{"tournament" => %{"team_boards" => "3"}})
      assert Repo.reload!(t).team_boards == 6
    end

    test "crafted and missing event values are no-ops", %{conn: conn, scope: scope} do
      {t, [team]} = team_round_robin([{"A", [2000]}], user_id: scope.user.id)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/teams")

      for {event, payload} <- [
            {"delete_team", %{"team_id" => "nope"}},
            {"move_team", %{"team_id" => team.id, "direction" => "sideways"}},
            {"move_player", %{"player_id" => "999999", "direction" => "up"}},
            {"add_player", %{"team_id" => team.id, "player_id" => "x"}},
            {"remove_player", %{"player_id" => nil}},
            {"create_team", %{"team" => "not a map"}},
            {"update_team", %{}},
            {"save_boards", %{}}
          ] do
        render_hook(lv, event, payload)
        assert Process.alive?(lv.pid), "#{event} crashed the page"
      end

      assert [%{name: "A"}] = Tournaments.list_teams(t.id)
    end
  end

  describe "the rest of a team round robin" do
    setup %{scope: scope} do
      {t, _} =
        team_round_robin(
          [{"Alpha", [2100, 2000]}, {"Beta", [1900, 1800]}, {"Gamma", [1850, 1750]}],
          user_id: scope.user.id,
          tiebreaks: ~w(MP GP SB),
          round_dates: ["2026-09-01", "2026-09-02", "2026-09-03"]
        )

      t = pair_all!(t)
      # Round 1 of a three-team Berger table: Alpha (number 1) sits out,
      # Beta plays Gamma.
      enter!(t, 1, "Beta", "Gamma", ["1-0", "1/2-1/2"])
      %{tournament: Repo.reload!(t)}
    end

    test "the Pairings page lists the round's matches above the boards", %{
      conn: conn,
      tournament: t
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      html = render_click(lv, "select_round", %{"number" => "1"})
      assert html =~ ~s(id="team-matches")
      assert html =~ "does not play this round"

      match_rows =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#team-matches tbody tr")
        |> Enum.count()

      assert match_rows == 2
      assert html =~ "1.5 - 0.5"

      team_matches =
        html |> LazyHTML.from_fragment() |> LazyHTML.query("#team-matches") |> LazyHTML.to_html()

      assert_accessible(team_matches)
      assert_accessible(render(lv), [:th_scope, :table_name])
    end

    test "the Standings page shows team standings and board statistics instead of the individual table",
         %{conn: conn, tournament: t} do
      {:ok, lv, html} = live(conn, ~p"/t/#{t.id}/standings")

      assert html =~ ~s(id="team-standings")
      assert html =~ ~s(id="board-stats")
      refute html =~ ~s(id="standings-table")
      assert html =~ "Board statistics"

      [first | _] =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#team-standings tbody tr")
        |> Enum.map(&LazyHTML.text/1)

      assert first =~ "Beta"
      assert_accessible(render(lv))
    end

    test "prints the team pairing sheet and team standings", %{conn: conn, tournament: t} do
      html = conn |> get(~p"/t/#{t.id}/print/team-pairings?round=1") |> html_response(200)
      assert html =~ "Team pairings - round 1"
      assert html =~ "Beta - Gamma (1.5 - 0.5)"
      assert html =~ "Alpha"
      assert html =~ "does not play this round"

      html = conn |> get(~p"/t/#{t.id}/print/team-standings") |> html_response(200)
      assert html =~ "Team standings after round 3"
      assert html =~ "<th class=\"num\">SB</th>"
      assert html =~ "Alpha"

      {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/print")
      assert html =~ "Team pairings (latest round)"

      assert conn |> get(~p"/t/#{t.id}/print/team-pairings?round=9") |> response(404)
    end

    test "the OpenResults settings page says team tournaments are not published", %{
      conn: conn,
      tournament: t
    } do
      {:ok, lv, html} = live(conn, ~p"/t/#{t.id}/settings/results")
      assert html =~ "Team tournaments are not published yet"

      html = render_click(lv, "toggle_publish_to_openresults", %{})
      assert html =~ "The results site has no team pages yet"
      refute Repo.reload!(t).publish_to_openresults
    end

    test "the Scoring page sets match points", %{conn: conn, tournament: t} do
      {:ok, lv, html} = live(conn, ~p"/t/#{t.id}/settings/scoring")
      assert html =~ "Match points for a won match"

      lv
      |> form("#scoring-settings-form",
        tournament: %{team_match_points_win: "3", team_match_points_draw: "1"}
      )
      |> render_submit()

      t = Repo.reload!(t)
      assert {t.team_match_points_win, t.team_match_points_draw} == {3.0, 1.0}
    end
  end
end
