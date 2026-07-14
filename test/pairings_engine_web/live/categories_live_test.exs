defmodule PairingsEngineWeb.CategoriesLiveTest do
  # async: false: several tests here do sequential writes against SQLite's
  # single writer and rely on PubSub self-broadcast draining via `render/1`
  # after the final write in a test — see SettingsLiveTest for the same
  # pattern this file mirrors.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.Tournaments

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Categories LV Test", "type" => "swiss", "rounds_count" => "5"}, attrs)
      )

    tournament
  end

  describe "Categories tab visibility" do
    test "the top-bar tab is hidden when categories are disabled", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"categories_enabled" => false})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      refute html =~ ~s(href="/t/#{tournament.id}/categories")
    end

    test "the top-bar tab is shown when categories are enabled", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"categories_enabled" => true})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      assert html =~ ~s(href="/t/#{tournament.id}/categories")
    end

    test "visiting the page while categories are disabled shows a graceful hint instead of the forms", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"categories_enabled" => false})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/categories")

      assert html =~ "Categories are turned off"
      refute html =~ "add-category-form"
    end
  end

  describe "Categories management" do
    test "adds a category, rejects a blank or duplicate name, and removes one", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"categories_enabled" => true})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/categories")

      html = lv |> form("#add-category-form", %{"name" => "U18"}) |> render_submit()
      assert html =~ "U18"
      assert Tournaments.get_authorized_tournament!(scope, tournament.id).categories == ["U18"]

      html = lv |> form("#add-category-form", %{"name" => "  "}) |> render_submit()
      assert html =~ "Enter a category name"

      html = lv |> form("#add-category-form", %{"name" => "U18"}) |> render_submit()
      assert html =~ "already exists"
      assert Tournaments.get_authorized_tournament!(scope, tournament.id).categories == ["U18"]

      lv |> element(~s(button[phx-value-name="U18"]), "Remove") |> render_click()

      # remove_category saves through Tournaments.update_tournament/2, which
      # broadcasts :settings — drain the self-broadcast before `lv`'s
      # teardown, same as SettingsLiveTest.
      render(lv)

      assert Tournaments.get_authorized_tournament!(scope, tournament.id).categories == []
    end
  end

  describe "Extra points (SWAR parity #12 XtPts)" do
    test "toggling \"count extra points\" and saving the bands persists both", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"categories_enabled" => true})
      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/categories")

      refute html =~ "Set extra points for"
      refute Tournaments.get_authorized_tournament!(scope, tournament.id).count_extra_points

      html =
        lv
        |> form("#extra-points-form", %{
          "tournament" => %{"count_extra_points" => "true", "extra_points_bands" => " 1600:0.5 , 1400:1 "}
        })
        |> render_submit()

      assert html =~ "1400:1"

      saved = Tournaments.get_authorized_tournament!(scope, tournament.id)
      assert saved.count_extra_points == true
      assert saved.extra_points_bands == "1400:1, 1600:0.5"

      # Saves through Tournaments.update_tournament/2, which broadcasts
      # :settings on the tournament topic — drain the self-broadcast.
      render(lv)
    end

    test "\"Apply bands to players\" sets extra_points from the saved bands and shows a summary", %{
      conn: conn,
      scope: scope
    } do
      tournament =
        create_tournament(scope, %{"categories_enabled" => true, "extra_points_bands" => "1400:1"})

      {:ok, low} = Tournaments.create_player(tournament.id, %{"name" => "Low", "fide_rating" => "1200"})
      {:ok, high} = Tournaments.create_player(tournament.id, %{"name" => "High", "fide_rating" => "2000"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/categories")

      html =
        lv
        |> element("button", "Apply bands to players")
        |> render_click()

      assert html =~ "Set extra points for 1 of 2 players."
      assert Tournaments.get_player!(low.id).extra_points == 1.0
      assert Tournaments.get_player!(high.id).extra_points == 0.0

      # apply_extra_points_bands/1 writes players and broadcasts :players —
      # drain it so `lv`'s teardown doesn't race a pending self-broadcast.
      render(lv)
    end
  end
end
