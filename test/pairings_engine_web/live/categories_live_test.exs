defmodule PairingsEngineWeb.CategoriesLiveTest do
  # async: false: several tests here do sequential writes against SQLite's
  # single writer and rely on PubSub self-broadcast draining via `render/1`.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.Tournaments

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(
          %{"name" => "Categories LV Test", "type" => "swiss", "rounds_count" => "5"},
          attrs
        )
      )

    tournament
  end

  describe "Categories tab reachability" do
    test "the Categories link is always present in the top-bar Settings dropdown", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"categories_enabled" => false})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      assert html =~ ~s(href="/t/#{tournament.id}/categories")
    end

    test "visiting the page while categories are disabled shows a graceful hint instead of the forms",
         %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"categories_enabled" => false})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/categories")

      assert html =~ "Categories are turned off"
      refute html =~ "add-category-form"
    end
  end

  describe "Categories management" do
    test "adds a category, rejects a blank or duplicate name, and removes one", %{
      conn: conn,
      scope: scope
    } do
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

      render(lv)

      assert Tournaments.get_authorized_tournament!(scope, tournament.id).categories == []
    end

    test "the extra-points form is no longer on the Categories page", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"categories_enabled" => true})
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/categories")

      refute html =~ "id=\"extra-points-form\""
      refute html =~ "Elo bands (rating:bonus, comma-separated)"
    end
  end

  describe "threshold rules" do
    test "a category with a rule shows it, and one without shows a dash", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"categories_enabled" => true})
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/categories")

      html =
        lv
        |> form("#add-category-form", %{
          "name" => "-1100",
          "kind" => "elo_below",
          "value" => "1100"
        })
        |> render_submit()

      assert html =~ "below 1100 Elo"

      html = lv |> form("#add-category-form", %{"name" => "Open"}) |> render_submit()
      assert html =~ "Open"

      reloaded = Tournaments.get_authorized_tournament!(scope, tournament.id)
      assert reloaded.categories == ["-1100", "Open"]
      assert reloaded.category_rules == %{"-1100" => %{"kind" => "elo_below", "value" => 1100}}
    end

    test "a non-numeric or zero threshold is rejected, and no category is created", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"categories_enabled" => true})
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/categories")

      html =
        lv
        |> form("#add-category-form", %{
          "name" => "-1100",
          "kind" => "elo_below",
          "value" => "abc"
        })
        |> render_submit()

      assert html =~ "positive whole number"

      html =
        lv
        |> form("#add-category-form", %{"name" => "-1100", "kind" => "elo_below", "value" => "0"})
        |> render_submit()

      assert html =~ "positive whole number"
      assert Tournaments.get_authorized_tournament!(scope, tournament.id).categories == []
    end

    test "removing a category also removes its rule", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"categories_enabled" => true})
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/categories")

      lv
      |> form("#add-category-form", %{"name" => "-1100", "kind" => "elo_below", "value" => "1100"})
      |> render_submit()

      lv |> element(~s(button[phx-value-name="-1100"]), "Remove") |> render_click()
      render(lv)

      reloaded = Tournaments.get_authorized_tournament!(scope, tournament.id)
      assert reloaded.categories == []
      assert reloaded.category_rules == %{}
    end

    test "Assign categories only appears once a rule exists, and fills in every player", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"categories_enabled" => true})

      {:ok, low} =
        Tournaments.create_player(tournament.id, %{"name" => "Low", "fide_rating" => "900"})

      {:ok, high} =
        Tournaments.create_player(tournament.id, %{"name" => "High", "fide_rating" => "2200"})

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/categories")
      refute html =~ "Assign categories"

      lv
      |> form("#add-category-form", %{"name" => "-1100", "kind" => "elo_below", "value" => "1100"})
      |> render_submit()

      html = lv |> element("button", "Assign categories") |> render_click()
      assert html =~ "Assigned 1 of 2 players."

      assert Tournaments.get_player!(tournament.id, low.id).category == "-1100"
      assert Tournaments.get_player!(tournament.id, high.id).category == ""
    end
  end
end
