defmodule PairingsEngineWeb.PluginSeamTest do
  @moduledoc """
  The compile-time plugin seam (`PairingsEngine.Plugin`,
  `PairingsEngine.Plugins`): with no plugin there is no trace of one -
  no route, no menu, no feature, no finding, roster board order - and a
  plugin's hooks are called where the seam says, through the test-only
  `PairingsEngine.FakePlugin`.

  The "no plugin" tests hold in both editions: they compare against
  `Plugins.compiled/0`, which is `[]` in every build but the hosted one.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{FakePlugin, Features, Plugins, Repo, TeamMatches, Tournaments}

  @moduletag :capture_log

  setup :register_and_log_in_user

  defp first_match(t, number \\ 1) do
    t.id
    |> Tournaments.get_round(number)
    |> Map.fetch!(:id)
    |> Tournaments.list_matches()
    |> Enum.find(& &1.team_b_id)
  end

  describe "a build without a plugin" do
    test "has no plugin route and no plug-ins page" do
      paths = PairingsEngineWeb.Router |> Phoenix.Router.routes() |> Enum.map(& &1.path)
      plugin_paths = Enum.filter(paths, &(&1 == "/plugins" or String.starts_with?(&1, "/p/")))

      if Enum.empty?(Plugins.compiled()) do
        assert plugin_paths == []
        assert Plugins.routes([]) == []
      else
        assert "/plugins" in plugin_paths
      end
    end

    test "the home screen has no Plug-ins menu", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      assert has_element?(lv, "#topbar-plugins") == not Enum.empty?(Plugins.compiled())
    end

    test "nothing is added to features, line-ups or schedules", %{scope: scope} do
      if Enum.empty?(Plugins.compiled()) do
        refute Plugins.any?()
        assert Plugins.installed() == []
        assert Plugins.features() == []
        assert Plugins.migrations_paths() == []
        refute Enum.any?(Features.keys(), &(&1 == "fake_league"))
      end

      {t, _} =
        team_round_robin([{"A", [2000, 1900]}, {"B", [1800, 1700]}], user_id: scope.user.id)

      pair_next!(t)
      t = Repo.reload!(t)
      match = first_match(t)
      %{a: a, b: b} = TeamMatches.lineups(t, match)

      assert Plugins.check_lineups(t, match, 1, a, b) == nil
      refute Plugins.plugin_board_order?(t)
      assert Plugins.team_schedule(t) == nil
      assert Plugins.tournament_menu_entries(scope, t) == []
    end

    test "the roster's board order is still enforced", %{scope: scope} do
      {t, _} =
        team_round_robin([{"A", [2000, 1900]}, {"B", [1800, 1700]}], user_id: scope.user.id)

      pair_next!(t)
      t = Repo.reload!(t)
      match = first_match(t)
      %{a: [p1, p2], b: b} = TeamMatches.lineups(t, match)

      assert {:error, {:board_order, _, _}} = TeamMatches.set_lineups(t, match, [p2, p1], b)
    end
  end

  describe "with a plugin" do
    setup do
      FakePlugin.register(
        candidates: [
          %{"name" => "Listed One", "national_id" => "9001", "fide_rating" => "1650"},
          %{"name" => "Listed Two", "national_id" => "9002", "fide_rating" => "1600"}
        ]
      )

      :ok
    end

    test "the home screen gets one Plug-ins menu listing it", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, "#topbar-plugins #topbar-plugins-toggle", "Plug-ins")
      assert has_element?(lv, "#plugin-menu-fake[href='/p/fake']", "Fake League")
      assert has_element?(lv, "#plugin-menu-fake", "9.9.9")
      assert has_element?(lv, "#plugin-menu-fake", "only in the test suite")
      assert has_element?(lv, "#plugin-menu-installed[href='/plugins']")
    end

    test "its routes are mounted under /p/<id>, with the plug-ins page" do
      assert [
               {"/plugins", PairingsEngineWeb.PluginsLive, :index},
               {"/p/fake", FakePlugin, :index},
               {"/p/fake/series/:id", FakePlugin, :show}
             ] = Plugins.routes([FakePlugin])
    end

    test "its features join the catalogue under their federation" do
      assert "fake_league" in Features.keys()
      assert Enum.any?(Features.catalogue_for("BEL"), &(&1.key == "fake_league"))
    end

    test "a tournament it owns gets its menu entry", %{conn: conn, scope: scope} do
      {t, _} =
        team_round_robin([{"A", [2000]}, {"B", [1900]}],
          name: "Fake series",
          user_id: scope.user.id
        )

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
      assert has_element?(lv, "#plugin-menu-fake[href='/p/fake/series/#{t.id}']")

      {other, _} = team_round_robin([{"A", [2000]}, {"B", [1900]}], user_id: scope.user.id)
      {:ok, lv, _html} = live(conn, ~p"/t/#{other.id}/players")
      refute has_element?(lv, "#plugin-menu-fake")
    end

    test "its line-up findings show on the match page, saved or not", %{conn: conn, scope: scope} do
      {t, _} =
        team_round_robin([{"A", [2000, 1900]}, {"B", [1800, 1700]}],
          name: "Fake series",
          user_id: scope.user.id
        )

      pair_next!(t)
      match = first_match(Repo.reload!(t))

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings/1/matches/#{match.id}")

      assert has_element?(lv, "#lineup-checks")

      assert has_element?(
               lv,
               "#lineup-finding-0.lineup-finding-violation",
               "Team A seats 2 players."
             )

      assert has_element?(lv, "#lineup-finding-0", "Art. 1.a")
      assert has_element?(lv, "#lineup-finding-0", "Game lost by forfeit")
      assert has_element?(lv, "#lineup-finding-1.lineup-finding-warning", "Looked.")

      # A draft: board 2 emptied on the form, not saved.
      lv
      |> form("#lineup-form")
      |> render_change(%{"lineup" => %{"a" => %{"2" => ""}}})

      assert has_element?(lv, "#lineup-finding-0", "Team A seats 1 players.")
      assert TeamMatches.lineups(Repo.reload!(t), match).a |> Enum.all?()
    end

    test "a match it does not own shows no checks", %{conn: conn, scope: scope} do
      {t, _} =
        team_round_robin([{"A", [2000]}, {"B", [1900]}], user_id: scope.user.id)

      pair_next!(t)
      match = first_match(Repo.reload!(t))

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings/1/matches/#{match.id}")
      refute has_element?(lv, "#lineup-checks")
    end

    test "a plugin that raises does not take the page with it", %{conn: conn, scope: scope} do
      FakePlugin.register(raise: true)

      {t, _} =
        team_round_robin([{"A", [2000]}, {"B", [1900]}],
          name: "Fake series",
          user_id: scope.user.id
        )

      pair_next!(t)
      match = first_match(Repo.reload!(t))

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings/1/matches/#{match.id}")
      refute has_element?(lv, "#lineup-checks")
      refute has_element?(lv, "#plugin-menu-fake")
    end

    test "it can own the board order: a line-up out of roster order is accepted",
         %{scope: scope} do
      {t, _} =
        team_round_robin([{"A", [2000, 1900]}, {"B", [1800, 1700]}],
          name: "Fake series",
          user_id: scope.user.id
        )

      pair_next!(t)
      t = Repo.reload!(t)
      match = first_match(t)
      %{a: [p1, p2], b: b} = TeamMatches.lineups(t, match)

      assert Plugins.plugin_board_order?(t)
      assert {:ok, _} = TeamMatches.set_lineups(t, match, [p2, p1], b)
      assert TeamMatches.lineups(t, Repo.reload!(match)).a == [p2, p1]
    end

    test "its roster candidates are offered on the Teams page and added in order",
         %{conn: conn, scope: scope} do
      {t, [a, _b]} =
        team_round_robin([{"A", [2000]}, {"B", [1900]}],
          name: "Fake series",
          user_id: scope.user.id
        )

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/teams")
      button = "#roster-source-fake-#{a.id} button"
      assert has_element?(lv, button, "Add 2 players from the fake list")

      lv |> element(button) |> render_click()

      names = t.id |> Tournaments.team_roster(a.id) |> Enum.map(& &1.name)
      assert names == ["A 1", "Listed One", "Listed Two"]
      refute has_element?(lv, button)
    end
  end

  describe "a plugin's team schedule" do
    defp three_fake_teams(scope) do
      team_round_robin([{"A", [2000]}, {"B", [1900]}, {"C", [1800]}],
        name: "Fake series",
        user_id: scope.user.id
      )
    end

    test "numbers 1..N on the table N needs is C.05's own table: FIDE mode is kept",
         %{scope: scope} do
      {t, [a, b, c]} = three_fake_teams(scope)
      FakePlugin.register(schedule: %{size: 4, numbers: %{a.id => 1, b.id => 2, c.id => 3}})

      pair_next!(t)
      t = Repo.reload!(t)

      assert t.rounds_count == 3
      assert is_nil(t.fide_compliance_lost_round)
    end

    test "a vacancy in the table is a bye for its opponent, and leaves FIDE mode",
         %{scope: scope} do
      {t, [a, b, c]} = three_fake_teams(scope)
      FakePlugin.register(schedule: %{size: 4, numbers: %{a.id => 1, b.id => 2, c.id => 4}})

      pair_next!(t)
      t = Repo.reload!(t)
      round = Tournaments.get_round(t.id, 1)
      matches = Tournaments.list_matches(round.id)

      # Berger 4, round 1: 1-4 and 2-3. Number 3 is vacant, so B has the bye.
      assert [played] = Enum.filter(matches, & &1.team_b_id)
      assert {played.team_a_id, played.team_b_id} == {a.id, c.id}
      assert [bye] = Enum.reject(matches, & &1.team_b_id)
      assert bye.team_a_id == b.id
      assert t.rounds_count == 3
      assert t.fide_compliance_lost_round == 1
    end

    test "a listed schedule pairs each round as listed, the rest with the bye, and leaves FIDE mode",
         %{scope: scope} do
      {t, [a, b, c]} = three_fake_teams(scope)

      FakePlugin.register(
        schedule: %{
          size: 4,
          numbers: %{a.id => 1, b.id => 2, c.id => 4},
          rounds: [[{4, 1}], [{2, 4}], []]
        }
      )

      pair_next!(t)
      t = Repo.reload!(t)
      assert t.rounds_count == 3
      assert t.fide_compliance_lost_round == 1

      matches = Tournaments.list_matches(Tournaments.get_round(t.id, 1).id)
      assert [played] = Enum.filter(matches, & &1.team_b_id)
      assert {played.team_a_id, played.team_b_id} == {c.id, a.id}
      assert [%{team_a_id: bye}] = Enum.reject(matches, & &1.team_b_id)
      assert bye == b.id

      pair_next!(t)
      pair_next!(Repo.reload!(t))
      round3 = Tournaments.list_matches(Tournaments.get_round(t.id, 3).id)
      assert Enum.all?(round3, &is_nil(&1.team_b_id)) and length(round3) == 3
    end

    test "every team must have a number", %{scope: scope} do
      {t, [a, b, _c]} = three_fake_teams(scope)
      FakePlugin.register(schedule: %{size: 4, numbers: %{a.id => 1, b.id => 2}})

      assert {:error, message} = PairingsEngine.Pairing.pair_next_round(Repo.reload!(t))
      assert message =~ "not every team has one"
    end
  end
end
