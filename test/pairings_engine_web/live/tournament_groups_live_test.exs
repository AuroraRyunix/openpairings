defmodule PairingsEngineWeb.TournamentGroupsLiveTest do
  # async: false: several users and tournaments per test, one SQLite writer -
  # the same reason as the Settings LiveView tests.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Accounts, Repo, TournamentGroups, Tournaments}
  alias PairingsEngine.Accounts.User
  alias PairingsEngineWeb.Components.GroupSwitcher

  setup :register_and_log_in_user

  defp tournament(scope, name, type \\ "swiss") do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => name,
        "type" => type,
        "rounds_count" => "5"
      })

    t
  end

  defp grouped(scope) do
    open = tournament(scope, "Spring Open")
    u20 = tournament(scope, "Spring U20")
    {:ok, group} = TournamentGroups.create_group(scope, open, "Spring Festival")
    {:ok, _} = TournamentGroups.join_group(scope, u20, group.id)
    {:ok, _} = TournamentGroups.set_label(scope, u20, "U20")
    %{open: open, u20: u20, group: group}
  end

  defp other_user_conn do
    user =
      Repo.insert!(%User{
        email: "user#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    {Phoenix.ConnTest.build_conn() |> log_in_user(user), Accounts.Scope.for_user(user)}
  end

  describe "the Group card on Settings" do
    test "creates a group, labels it, and the switcher appears once there is a sibling", %{
      conn: conn,
      scope: scope
    } do
      open = tournament(scope, "Spring Open")
      u20 = tournament(scope, "Spring U20")

      {:ok, lv, _html} = live(conn, ~p"/t/#{open.id}/settings")
      assert has_element?(lv, "#group-create-form")
      refute has_element?(lv, "#group-switcher")

      lv
      |> form("#group-create-form", group: %{name: "Spring Festival"})
      |> render_submit()

      assert has_element?(lv, "#group-rename-form")
      assert has_element?(lv, "#group-member-#{open.id}")
      # One member: nothing to switch to yet.
      refute has_element?(lv, "#group-switcher")

      lv |> form("#group-label-form", member: %{label: "Open"}) |> render_submit()
      assert TournamentGroups.membership(open.id).label == "Open"

      {:ok, lv2, _html} = live(conn, ~p"/t/#{u20.id}/settings")
      assert has_element?(lv2, "#group-join-form")

      group_id = TournamentGroups.membership(open.id).group_id
      lv2 |> form("#group-join-form", join: %{group_id: group_id}) |> render_submit()

      assert has_element?(lv2, "#group-switcher")
      assert has_element?(lv2, "#group-switch-#{open.id}", "Open")
      assert has_element?(lv2, ~s(#group-switch-#{u20.id}[aria-current="page"]))
    end

    test "reorders, renames and leaves", %{conn: conn, scope: scope} do
      %{open: open, u20: u20, group: group} = grouped(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{open.id}/settings")

      lv |> element("#group-up-#{u20.id}") |> render_click()

      assert TournamentGroups.switcher(scope, open).members |> Enum.map(& &1.id) ==
               [u20.id, open.id]

      lv
      |> form("#group-rename-form", group_rename: %{name: "Autumn Festival"})
      |> render_submit()

      assert Repo.get!(TournamentGroups.Group, group.id).name == "Autumn Festival"

      lv |> element("#group-leave") |> render_click()
      assert TournamentGroups.membership(open.id) == nil
      assert has_element?(lv, "#group-create-form")
      refute has_element?(lv, "#group-switcher")
    end

    test "a refused change says why instead of failing silently", %{conn: conn, scope: scope} do
      open = tournament(scope, "Spring Open")
      {:ok, lv, _html} = live(conn, ~p"/t/#{open.id}/settings")

      lv |> form("#group-create-form", group: %{name: " "}) |> render_submit()
      assert has_element?(lv, "#group-error")
      assert TournamentGroups.membership(open.id) == nil
    end
  end

  describe "the switcher" do
    test "shows on every tournament page and links to the same page of the sibling", %{
      conn: conn,
      scope: scope
    } do
      %{open: open, u20: u20} = grouped(scope)

      for page <- ~w(players pairings standings settings/scoring) do
        {:ok, lv, _html} = live(conn, "/t/#{open.id}/#{page}")
        assert has_element?(lv, "#group-switcher")
        assert has_element?(lv, ~s(#group-switch-#{u20.id}[href="/t/#{u20.id}/#{page}"]))
        assert has_element?(lv, ~s(#group-switch-#{open.id}[aria-current="page"]))
        # The phone dropdown carries the same links.
        assert has_element?(lv, ~s(#group-menu-#{u20.id}[href="/t/#{u20.id}/#{page}"]))
      end
    end

    test "a page the sibling does not have leads to its Players page", %{
      conn: conn,
      scope: scope
    } do
      teams = tournament(scope, "Spring Teams", "team-swiss")
      solo = tournament(scope, "Spring Solo")
      {:ok, group} = TournamentGroups.create_group(scope, teams, "Spring Festival")
      {:ok, _} = TournamentGroups.join_group(scope, solo, group.id)

      {:ok, lv, _html} = live(conn, ~p"/t/#{teams.id}/teams")
      assert has_element?(lv, ~s(#group-switch-#{solo.id}[href="/t/#{solo.id}/players"]))
    end

    test "never names a sibling the viewer cannot open", %{scope: scope} do
      %{open: open, u20: u20} = grouped(scope)
      {helper_conn, helper_scope} = other_user_conn()

      {:ok, invite} = Tournaments.add_collaborator(scope, u20, helper_scope.user.email)
      {:ok, _} = Tournaments.accept_invitation(helper_scope, invite.invite_token)

      {:ok, lv, html} = live(helper_conn, ~p"/t/#{u20.id}/players")
      refute has_element?(lv, "#group-switcher")
      refute html =~ "Spring Open"
      refute html =~ "/t/#{open.id}/"
    end

    test "is absent for a tournament in no group", %{conn: conn, scope: scope} do
      t = tournament(scope, "Lonely Open")
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
      refute has_element?(lv, "#group-switcher")
    end

    test "maps sub-pages the way it promises" do
      solo = %{id: 9, type: "swiss"}
      team = %{id: 9, type: "team-swiss"}

      assert GroupSwitcher.sibling_path("/t/1/standings", solo) == "/t/9/standings"
      assert GroupSwitcher.sibling_path("/t/1/settings/fide?x=1", solo) == "/t/9/settings/fide"
      assert GroupSwitcher.sibling_path("/t/1/pairings/3/explain", solo) == "/t/9/pairings"
      assert GroupSwitcher.sibling_path("/t/1/pairings/3/matches/4", solo) == "/t/9/pairings"

      assert GroupSwitcher.sibling_path("/t/1/team-sheets/rosters", team) ==
               "/t/9/team-sheets/rosters"

      assert GroupSwitcher.sibling_path("/t/1/team-sheets/rosters", solo) == "/t/9/players"
      assert GroupSwitcher.sibling_path("/t/1/something-new", solo) == "/t/9/players"
      assert GroupSwitcher.sibling_path(nil, solo) == "/t/9/players"
    end
  end

  describe "the home list" do
    test "gathers a group's tournaments under its name, in the group's order, and folds", %{
      conn: conn,
      scope: scope
    } do
      %{open: open, u20: u20, group: group} = grouped(scope)
      loose = tournament(scope, "Club Evening")

      {:ok, lv, html} = live(conn, ~p"/")

      assert has_element?(lv, "#home-group-#{group.id}", "Spring Festival")
      assert has_element?(lv, "#tournament-row-#{open.id}.home-group-member")
      assert has_element?(lv, "#tournament-row-#{u20.id}.home-group-member")
      assert has_element?(lv, "#tournament-row-#{loose.id}")
      refute has_element?(lv, "#tournament-row-#{loose.id}.home-group-member")

      # Group order (Open first) even though U20 is the newer tournament.
      {open_at, _} = :binary.match(html, "tournament-row-#{open.id}")
      {u20_at, _} = :binary.match(html, "tournament-row-#{u20.id}")
      assert open_at < u20_at

      lv |> element("#home-group-toggle-#{group.id}") |> render_click()
      refute has_element?(lv, "#tournament-row-#{open.id}")
      assert has_element?(lv, ~s(#home-group-toggle-#{group.id}[aria-expanded="false"]))

      lv |> element("#home-group-toggle-#{group.id}") |> render_click()
      assert has_element?(lv, "#tournament-row-#{open.id}")
    end
  end
end
