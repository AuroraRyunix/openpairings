defmodule PairingsEngineWeb.TeamWorkflowLiveTest do
  @moduledoc """
  The team workflow's pages: the match page's line-ups and home and away,
  the Pairings page's double forfeit, the Teams page's board colours, roster
  locks and withdrawal, the Scoring page's bye value and withdrawal rule,
  the Standings page's annulled team, and the Keizer refusal on New
  tournament. See docs/team-tournaments.md.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{Audit, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Match, Player}

  @moduletag :capture_log

  setup :register_and_log_in_user

  defp player(t, name),
    do: Repo.one!(from p in Player, where: p.tournament_id == ^t.id and p.name == ^name)

  defp team(t, name), do: t.id |> Tournaments.list_teams() |> Enum.find(&(&1.name == name))

  defp audited?(t, action), do: Enum.any?(Audit.list_for_tournament(t.id), &(&1.action == action))

  defp two_team_match(scope, opts \\ []) do
    {t, _} =
      team_round_robin(
        [{"A", [2100, 2000, 1900, 1800]}, {"B", [2050, 1950, 1850, 1750]}],
        [boards: 3, rounds_count: 1, user_id: scope.user.id] ++ opts
      )

    t = pair_all!(t)
    {match, _} = match_between(t, 1, "A", "B")
    {t, match}
  end

  describe "the match page (A1, B3)" do
    test "the Pairings page links to it, and a line-up is saved", %{conn: conn, scope: scope} do
      {t, match} = two_team_match(scope)

      {:ok, pairings, _} = live(conn, ~p"/t/#{t.id}/pairings")
      assert has_element?(pairings, "#match-lineups-#{match.id}")

      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/pairings/1/matches/#{match.id}")
      assert has_element?(lv, "#lineup-form")
      assert has_element?(lv, "#lineup-a-3")

      lv
      |> form("#lineup-form", %{
        "lineup" => %{
          "a" => %{
            "1" => "#{player(t, "A 1").id}",
            "2" => "#{player(t, "A 3").id}",
            "3" => "#{player(t, "A 4").id}"
          },
          "b" => %{
            "1" => "#{player(t, "B 1").id}",
            "2" => "#{player(t, "B 2").id}",
            "3" => "#{player(t, "B 3").id}"
          }
        }
      })
      |> render_submit()

      refute has_element?(lv, "#match-error")

      seated =
        Repo.all(from p in PairingsEngine.Tournaments.Pairing, where: p.match_id == ^match.id)

      ids = Enum.flat_map(seated, &[&1.white_player_id, &1.black_player_id])
      assert player(t, "A 4").id in ids
      refute player(t, "A 2").id in ids
      assert audited?(t, "pairing.lineup_changed")
    end

    test "a line-up out of board order is refused with the reason", %{conn: conn, scope: scope} do
      {t, match} = two_team_match(scope)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/pairings/1/matches/#{match.id}")

      lv
      |> form("#lineup-form", %{
        "lineup" => %{
          "a" => %{
            "1" => "#{player(t, "A 2").id}",
            "2" => "#{player(t, "A 1").id}",
            "3" => "#{player(t, "A 3").id}"
          },
          "b" => %{
            "1" => "#{player(t, "B 1").id}",
            "2" => "#{player(t, "B 2").id}",
            "3" => "#{player(t, "B 3").id}"
          }
        }
      })
      |> render_submit()

      assert has_element?(lv, "#match-error", "board order")
    end

    test "after a result the line-ups are closed", %{conn: conn, scope: scope} do
      {t, match} = two_team_match(scope)
      {_m, [first | _]} = match_between(t, 1, "A", "B")
      {:ok, _} = Tournaments.update_pairing_result(first, "1-0")

      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/pairings/1/matches/#{match.id}")
      assert has_element?(lv, "#lineups-closed")
      refute has_element?(lv, "#save-lineups")
    end

    test "league colours offer the home and away swap", %{conn: conn, scope: scope} do
      {t, match} = two_team_match(scope, team_board_colours: "home")
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/pairings/1/matches/#{match.id}")

      lv |> element("#swap-home") |> render_click()
      assert Repo.reload!(match).team_a_id == team(t, "B").id
      assert audited?(t, "pairing.match_home_swapped")
    end

    test "FIDE colours have no home and away", %{conn: conn, scope: scope} do
      {t, match} = two_team_match(scope)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/pairings/1/matches/#{match.id}")
      refute has_element?(lv, "#home-and-away")
    end
  end

  describe "the double forfeit on the Pairings page (A5)" do
    test "recorded and withdrawn", %{conn: conn, scope: scope} do
      {t, match} = two_team_match(scope)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/pairings")

      lv |> element("#double-forfeit-#{match.id}") |> render_click()
      assert Repo.reload!(match).double_forfeit
      assert has_element?(lv, "#match-decision-#{match.id}", "Double forfeit")
      assert audited?(t, "pairing.match_double_forfeited")

      lv
      |> element("#team-match-#{match.id} button[phx-click='withdraw_match_forfeit']")
      |> render_click()

      refute Repo.reload!(match).double_forfeit
    end
  end

  describe "the Teams page (B2, B3, A4)" do
    test "board colours are a setting, locked once round 1 is paired", %{conn: conn, scope: scope} do
      {t, _} =
        team_round_robin([{"A", [2100, 2000]}, {"B", [2050, 1950]}],
          boards: 2,
          rounds_count: 1,
          user_id: scope.user.id
        )

      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/teams")

      lv
      |> form("#team-boards-form", %{"tournament" => %{"team_board_colours" => "home"}})
      |> render_submit()

      assert Repo.reload!(t).team_board_colours == "home"

      pair_all!(t)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/teams")
      assert has_element?(lv, "#team-board-colours[disabled]")
    end

    test "FIDE mode fixes the rosters after round 1", %{conn: conn, scope: scope} do
      {t, _} = two_team_match(scope)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/teams")

      assert has_element?(lv, "#roster-locked-note")
      refute has_element?(lv, "button[phx-click='move_player']")
    end

    test "outside FIDE mode a change is allowed with a warning", %{conn: conn, scope: scope} do
      {t, _} = two_team_match(scope)
      {:ok, _} = Tournaments.leave_fide_mode(t)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/teams")

      assert has_element?(lv, "#roster-change-warning")
      assert has_element?(lv, "button[phx-click='move_player'][data-confirm]")
    end

    test "a team withdraws in one action and comes back", %{conn: conn, scope: scope} do
      {t, _} =
        team_round_robin(for(i <- 1..4, do: {"T#{i}", [2000 - i, 1900 - i]}),
          boards: 2,
          rounds_count: 3,
          user_id: scope.user.id
        )

      t = pair_all!(t)
      t4 = team(t, "T4")
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/teams")

      lv
      |> form("#withdraw-team-#{t4.id}", %{"from_round" => "2"})
      |> render_submit()

      assert Repo.reload!(t4).withdrawn_from_round == 2
      assert has_element?(lv, "#team-withdrawn-#{t4.id}")
      assert audited?(t, "team.withdrawn")

      assert Repo.aggregate(
               from(m in Match,
                 where: m.forfeited_to_team_id != ^t4.id and not is_nil(m.forfeited_to_team_id)
               ),
               :count
             ) == 2

      lv |> element("#reinstate-team-#{t4.id}") |> render_click()
      assert Repo.reload!(t4).withdrawn_from_round == nil
      assert audited?(t, "team.reinstated")
    end
  end

  describe "the Scoring page (A7, A4)" do
    test "a team Swiss sets its bye's value", %{conn: conn, scope: scope} do
      {t, _} =
        team_swiss(for(i <- 1..3, do: {"T#{i}", [2000 - i, 1900 - i]}), user_id: scope.user.id)

      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/settings/scoring")
      assert has_element?(lv, "#team-pab-match-points")
      refute has_element?(lv, "#team-withdrawal-annul")

      render_submit(lv, "save", %{
        "tournament" => %{"team_pab_match_points" => "2", "team_pab_game_points" => ""}
      })

      t = Repo.reload!(t)
      assert {t.team_pab_match_points, t.team_pab_game_points} == {2.0, nil}
    end

    test "a team round robin sets the withdrawal rule", %{conn: conn, scope: scope} do
      {t, _} = two_team_match(scope)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/settings/scoring")
      refute has_element?(lv, "#team-pab-match-points")

      render_submit(lv, "save", %{"tournament" => %{"team_withdrawal_annul" => "true"}})
      assert Repo.reload!(t).team_withdrawal_annul
    end
  end

  describe "the Standings page (A4)" do
    test "an annulled team is marked", %{conn: conn, scope: scope} do
      {t, _} =
        team_round_robin(for(i <- 1..4, do: {"T#{i}", [2000 - i, 1900 - i]}),
          boards: 2,
          rounds_count: 3,
          user_id: scope.user.id,
          team_withdrawal_annul: true
        )

      t = pair_all!(t)
      t4 = team(t, "T4")
      {:ok, _} = Tournaments.withdraw_team(t, t4, 1)

      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/standings")
      assert has_element?(lv, "#team-annulled-#{t4.id}")
    end
  end

  describe "New tournament (B4)" do
    test "Keizer with Team is refused, with the way out", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      lv |> element("button", "New tournament") |> render_click()

      lv
      |> element("form[phx-change='pairing_system_picked']")
      |> render_change(%{"tournament" => %{"pairing_system" => "keizer", "team" => "true"}})

      assert has_element?(lv, "#new-team-keizer-hint", "Choose Swiss")
    end
  end
end
