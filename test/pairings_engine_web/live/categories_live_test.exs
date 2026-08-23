defmodule PairingsEngineWeb.CategoriesLiveTest do
  # async: false: several tests here do sequential writes against SQLite's
  # single writer and rely on PubSub self-broadcast draining via `render/1`.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Audit, Tournaments}

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

    test "visiting the page while categories are disabled shows the status toggle, not the forms",
         %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"categories_enabled" => false})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/categories")

      assert html =~ "Turn on"
      refute html =~ "add-category-form"
    end
  end

  describe "Categories on/off - instant button, no separate Save step" do
    test "turning it on immediately persists and reveals the category-list card", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"categories_enabled" => false})

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/categories")
      refute html =~ "add-category-form"

      html = lv |> element("button", "Turn on") |> render_click()

      assert html =~ "add-category-form"
      assert Tournaments.get_authorized_tournament!(scope, tournament.id).categories_enabled
    end

    test "turning it off immediately persists and hides the category-list card again", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"categories_enabled" => true})

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/categories")
      assert html =~ "add-category-form"

      html = lv |> element("button", "Turn off") |> render_click()

      refute html =~ "add-category-form"
      refute Tournaments.get_authorized_tournament!(scope, tournament.id).categories_enabled
    end

    test "turning it off also forces pair_by_category off, avoiding the changeset's own conflict",
         %{conn: conn, scope: scope} do
      tournament =
        create_tournament(scope, %{
          "pairing_system" => "swiss",
          "categories_enabled" => true,
          "categories" => ["A", "B"],
          "pair_by_category" => true
        })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/categories")

      lv
      |> element(~s(button[phx-click="toggle_categories_enabled"]), "Turn off")
      |> render_click()

      updated = Tournaments.get_authorized_tournament!(scope, tournament.id)
      refute updated.categories_enabled
      refute updated.pair_by_category
    end
  end

  describe "pair_by_category (beta) - instant button, locked once round 1 has been paired" do
    defp pair_swiss_round_1(tournament) do
      Tournaments.create_player(tournament.id, %{name: "Alice", fide_rating: 2000})
      Tournaments.create_player(tournament.id, %{name: "Bob", fide_rating: 1900})
      Tournaments.create_player(tournament.id, %{name: "Carol", fide_rating: 1800})
      Tournaments.create_player(tournament.id, %{name: "Dave", fide_rating: 1700})

      {:ok, _round} =
        PairingsEngine.Pairing.pair_next_round(Tournaments.get_tournament!(tournament.id))
    end

    test "not offered at all while categories are off", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"categories_enabled" => false})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/categories")

      refute html =~ "Pair each category independently"
    end

    test "turning it on immediately persists", %{conn: conn, scope: scope} do
      tournament =
        create_tournament(scope, %{
          "pairing_system" => "swiss",
          "categories_enabled" => true,
          "categories" => ["A", "B"]
        })

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/categories")
      assert html =~ "Pair each category independently"

      lv
      |> element(~s(button[phx-click="toggle_pair_by_category"]), "Turn on")
      |> render_click()

      assert Tournaments.get_authorized_tournament!(scope, tournament.id).pair_by_category
    end

    @tag :javafo
    test "button is disabled once round 1 has been paired", %{conn: conn, scope: scope} do
      tournament =
        create_tournament(scope, %{
          "pairing_system" => "swiss",
          "categories_enabled" => true,
          "categories" => ["A", "B"],
          "pair_by_category" => true
        })

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/categories")
      refute html =~ ~r/phx-click="toggle_pair_by_category"[^>]*disabled/

      pair_swiss_round_1(tournament)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/categories")
      assert html =~ ~r/phx-click="toggle_pair_by_category"[^>]*disabled/
      assert html =~ "Locked"
    end

    @tag :javafo
    test "a click is a no-op server-side once locked, even with the disabled attribute bypassed",
         %{conn: conn, scope: scope} do
      tournament =
        create_tournament(scope, %{
          "pairing_system" => "swiss",
          "categories_enabled" => true,
          "categories" => ["A", "B"],
          "pair_by_category" => true
        })

      pair_swiss_round_1(tournament)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/categories")
      render_click(lv, "toggle_pair_by_category", %{})

      assert Tournaments.get_authorized_tournament!(scope, tournament.id).pair_by_category
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

    test "Assign categories only appears once a rule exists, previews the diff, and applies on confirm",
         %{
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

      html =
        lv |> element(~s(button[phx-click="assign_categories"])) |> render_click()

      # The dry run only computes a preview - nothing is written yet.
      assert html =~ "Low"
      assert html =~ "-1100"

      # Scoped to the preview, not the whole document. This player is called
      # "High", and a bare `refute html =~ "High"` fails the moment any
      # unrelated chrome contains that substring - which is what happened
      # when a "High Contrast" theme joined the topbar picker. The claim
      # being made is about the preview's contents, so ask the preview.
      refute lv |> element(".pe-modal-body") |> render() =~ "High"
      assert Tournaments.get_player!(tournament.id, low.id).category == ""
      assert Tournaments.get_player!(tournament.id, high.id).category == ""

      html =
        lv |> element(~s(button[phx-click="apply_category_confirm"])) |> render_click()

      # Drain the self-broadcast (bulk_update_players broadcasts :players on
      # the tournament topic this lv subscribes to) before reading the DB.
      render(lv)

      assert html =~ "Assigned 1 of 2 players."
      refute html =~ ~s(phx-click="cancel_category_confirm")

      assert Tournaments.get_player!(tournament.id, low.id).category == "-1100"
      assert Tournaments.get_player!(tournament.id, high.id).category == ""

      [log | _] = Audit.list_for_tournament(tournament.id, action: "category.auto_assigned")
      assert log.details == %{"matched" => 1, "total" => 2}
    end

    test "canceling the preview discards it with zero side effects", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"categories_enabled" => true})

      {:ok, low} =
        Tournaments.create_player(tournament.id, %{"name" => "Low", "fide_rating" => "900"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/categories")

      lv
      |> form("#add-category-form", %{"name" => "-1100", "kind" => "elo_below", "value" => "1100"})
      |> render_submit()

      lv |> element(~s(button[phx-click="assign_categories"])) |> render_click()

      html =
        lv |> element(~s(button[phx-click="cancel_category_confirm"])) |> render_click()

      refute html =~ ~s(phx-click="apply_category_confirm")
      assert Tournaments.get_player!(tournament.id, low.id).category == ""
    end

    test "when the roster already matches the rules, it says so instead of opening a diff", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"categories_enabled" => true})

      {:ok, low} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Low",
          "fide_rating" => "900",
          "category" => "-1100"
        })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/categories")

      lv
      |> form("#add-category-form", %{"name" => "-1100", "kind" => "elo_below", "value" => "1100"})
      |> render_submit()

      html =
        lv |> element(~s(button[phx-click="assign_categories"])) |> render_click()

      assert html =~ "No changes needed"
      refute html =~ ~s(phx-click="apply_category_confirm")
      assert Tournaments.get_player!(tournament.id, low.id).category == "-1100"
    end
  end
end
