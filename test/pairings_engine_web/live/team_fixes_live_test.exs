defmodule PairingsEngineWeb.TeamFixesLiveTest do
  @moduledoc """
  The team-event fixes of 2026-10-03, through the pages an arbiter uses:
  deleting a team, a round robin that grows a second cycle after its first
  is paired, and a two-team Swiss that cannot go on.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{Publishing, Repo, Tournaments}
  alias PairingsEngine.Pairing, as: Engine

  @moduletag :capture_log

  setup :register_and_log_in_user

  defp numbers(t), do: t.id |> Tournaments.list_teams() |> Enum.map(& &1.pairing_number)

  describe "deleting a team" do
    test "a refused first pairing leaves no numbers behind, so every team can be deleted", %{
      conn: conn,
      scope: scope
    } do
      {t, [a, _b]} = team_swiss([{"A", [2000, 1900]}, {"B", []}], user_id: scope.user.id)

      assert {:error, _} = Engine.pair_next_round(Repo.reload!(t))
      assert numbers(t) == [nil, nil]

      {:ok, c} = Tournaments.create_team(t, %{"name" => "C"})
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/teams")

      for team <- [a, c] do
        assert has_element?(lv, "#delete-team-#{team.id}[data-confirm]")
      end

      lv |> element("#delete-team-#{a.id}") |> render_click()
      refute Repo.get(PairingsEngine.Tournaments.Team, a.id)
    end

    test "a team round robin's refusal gives the numbers back too", %{scope: scope} do
      {t, _} = team_round_robin([{"A", [2000, 1900]}], user_id: scope.user.id)
      assert {:error, _} = Engine.pair_next_round(Repo.reload!(t))
      assert numbers(t) == [nil]
      refute Tournaments.teams_frozen?(t.id)
    end

    test "after round 1 of a team Swiss: a team that played explains itself, one that never played goes",
         %{conn: conn, scope: scope} do
      {t, [a, _b, _c, d]} =
        team_swiss(
          [{"A", [2000, 1900]}, {"B", [1800, 1700]}, {"C", [1750, 1650]}, {"D", []}],
          user_id: scope.user.id
        )

      _ = pair_next!(t)
      # D could field nobody: numbered with the others, but in no match.
      assert Repo.reload!(d).pairing_number
      {:ok, e} = Tournaments.create_team(t, %{"name" => "E"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/teams")

      # Every team is offered the button; only the deletable ones confirm.
      assert has_element?(lv, "#delete-team-#{a.id}")
      refute has_element?(lv, "#delete-team-#{a.id}[data-confirm]")
      assert has_element?(lv, "#delete-team-#{d.id}[data-confirm]")
      assert has_element?(lv, "#delete-team-#{e.id}[data-confirm]")

      lv |> element("#delete-team-#{a.id}") |> render_click()
      assert has_element?(lv, "p[role=alert]")
      assert Repo.get(PairingsEngine.Tournaments.Team, a.id)

      lv |> element("#delete-team-#{d.id}") |> render_click()
      refute Repo.get(PairingsEngine.Tournaments.Team, d.id)

      lv |> element("#delete-team-#{e.id}") |> render_click()
      refute Repo.get(PairingsEngine.Tournaments.Team, e.id)
      refute has_element?(lv, "p[role=alert]")
    end

    test "a team round robin under way refuses, even for a team with no match left", %{
      scope: scope
    } do
      {t, [a, _b, _c]} =
        team_round_robin([{"A", [2000]}, {"B", [1900]}, {"C", [1800]}],
          user_id: scope.user.id,
          boards: 1
        )

      _ = pair_next!(t)
      assert {:error, :team_played} = Tournaments.delete_team(Repo.reload!(a))

      # The round's bye team still sits in the Berger table.
      bye_team =
        t.id
        |> Tournaments.team_byes_by_round()
        |> Map.fetch!(1)

      team = Tournaments.get_team(t.id, bye_team)
      assert {:error, :team_played} = Tournaments.delete_team(team)
    end
  end

  describe "a team round robin's second cycle, decided after round 1" do
    test "Settings - Options extends a two-team match from one round to two", %{
      conn: conn,
      scope: scope
    } do
      {t, _} =
        team_round_robin([{"A", [2000, 1900]}, {"B", [1800, 1700]}],
          user_id: scope.user.id,
          fide_compliance_lost_round: 0
        )

      _ = pair_next!(t)
      enter!(t, 1, "A", "B", ["1-0", "0-1"])
      assert Repo.reload!(t).rounds_count == 1

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/options")

      lv
      |> form("#pairing-settings-form", tournament: %{rr_cycles: "2"})
      |> render_submit()

      t = Repo.reload!(t)
      assert {t.rr_cycles, t.rounds_count} == {2, 2}

      # The Pairings page offers round 2 straight away (with one round there
      # was no round 2 to open), and it is round 1 with the colours reversed.
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings?round=2")
      assert has_element?(lv, "#round-actions #pair-round")
      _ = pair_next!(t)

      {m1, _} = match_between(t, 1, "A", "B")
      {m2, _} = match_between(t, 2, "A", "B")
      assert {m2.team_a_id, m2.team_b_id} == {m1.team_b_id, m1.team_a_id}
    end
  end

  describe "a two-team Swiss" do
    test "round 2 says a Swiss of two teams has one round, and points to the round robin", %{
      conn: conn,
      scope: scope
    } do
      {t, _} =
        team_swiss([{"A", [2000, 1900]}, {"B", [1800, 1700]}], user_id: scope.user.id, rounds: 3)

      _ = pair_next!(t)
      enter!(t, 1, "A", "B", ["1-0", "0-1"])

      assert {:error, {:team_pairing, {:too_few_teams, 2, 1}, 2}} =
               Engine.pair_next_round(Repo.reload!(t))

      text =
        PairingsEngineWeb.SettingsSupport.error_text({:team_pairing, {:too_few_teams, 2, 1}, 2})

      assert text =~ "a Swiss with 2 teams can have at most 1 round,"
      assert text =~ "round robin"

      # Nothing was written: round 2 is still to pair, the teams keep their numbers.
      assert Engine.paired_rounds_count(t.id) == 1
      assert Enum.all?(numbers(t))
      {:ok, _lv, _html} = live(conn, ~p"/t/#{t.id}/pairings?round=2")
    end
  end

  describe "publishing a team event's round" do
    setup do
      Publishing.put_endpoint("https://openresults.example/")
      Publishing.put_token("s3cret")
      me = self()

      Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(me, {:published, Jason.decode!(body)})
        Req.Test.json(conn, %{"ok" => true})
      end)

      :ok
    end

    test "the round's Public control queues a publish at once and sends the round's matches", %{
      conn: conn,
      scope: scope
    } do
      {t, _} =
        team_round_robin(
          [
            {"Antwerp", [2000, 1900]},
            {"Brugge", [1800, 1700]},
            {"Gent", [1700, 1600]},
            {"Hasselt", [1600, 1500]}
          ],
          user_id: scope.user.id
        )

      t = pair_all!(t)

      {:ok, t} =
        t
        |> Ecto.Changeset.change(publish_to_openresults: true, public_slug: "teams-#{t.id}")
        |> Repo.update()

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings?round=1")
      lv |> element("#round-publish-group [phx-value-level='1']") |> render_click()

      # The click only records the intent - nothing has gone over the wire.
      assert Publishing.queued(t.id)
      refute_received {:published, _}

      assert {1, 0} = Publishing.drain()
      assert_received {:published, payload}

      assert [%{"number" => 1, "matches" => matches, "boards" => boards}] = payload["rounds"]
      assert length(matches) == 2
      assert length(boards) == 4

      assert Enum.sort(Enum.map(payload["teams"], & &1["name"])) ==
               ~w(Antwerp Brugge Gent Hasselt)
    end
  end
end
