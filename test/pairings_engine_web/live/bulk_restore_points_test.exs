defmodule PairingsEngineWeb.BulkRestorePointsTest do
  @moduledoc """
  A restore point is taken before every bulk change: one click that rewrites
  many players at once, which the audit trail's per-field diff cannot undo.
  One test per trigger, plus the retention rule that keeps hand-saved points
  out of the pruning.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{Repo, Snapshots, Tournaments}
  alias PairingsEngine.Fide.FidePlayer

  @moduletag :capture_log

  setup :register_and_log_in_user

  defp tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Bulk Test", "type" => "swiss", "rounds_count" => "5"}, attrs)
      )

    t
  end

  defp snapshots(t), do: Snapshots.list(t.id)

  defp one_snapshot!(t, trigger) do
    assert [s] = Enum.filter(snapshots(t), &(&1.trigger == trigger))
    s
  end

  defp players(t, n) do
    for i <- 1..n do
      {:ok, p} =
        Tournaments.create_player(t.id, %{
          "name" => "Player #{i}",
          "fide_rating" => "#{1500 + i}"
        })

      p
    end
  end

  test "giving everyone a category takes a restore point first", %{conn: conn, scope: scope} do
    t = tournament(scope, %{"categories" => ["U18"]})
    players(t, 2)
    {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/players")

    render_click(lv, "set_all_category", %{"name" => "U18", "value" => "true"})

    s = one_snapshot!(t, "player.bulk_category_set")
    assert s.summary == "Before adding category U18 to everyone"

    render_click(lv, "set_all_category", %{"name" => "U18", "value" => "false"})
    assert length(Enum.filter(snapshots(t), &(&1.trigger == "player.bulk_category_set"))) == 2
  end

  test "assigning categories by rule takes one, counting the players it will touch", %{
    conn: conn,
    scope: scope
  } do
    t = tournament(scope, %{"categories_enabled" => true})
    Tournaments.create_player(t.id, %{"name" => "Low", "fide_rating" => "900"})
    {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/categories")

    lv
    |> form("#add-category-form", %{"name" => "-1100", "rating_below" => "1100"})
    |> render_submit()

    lv |> element(~s(button[phx-click="assign_categories"])) |> render_click()
    # Previewing writes nothing, so it must not snapshot either.
    assert snapshots(t) == []

    lv |> element(~s(button[phx-click="apply_category_confirm"])) |> render_click()
    render(lv)

    assert one_snapshot!(t, "category.auto_assigned").summary ==
             "Before assigning categories to 1 player"
  end

  test "re-seeding the pairing numbers takes one", %{conn: conn, scope: scope} do
    t = tournament(scope)
    players(t, 3)
    {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/players")

    render_click(lv, "tpn_regenerate")

    assert one_snapshot!(t, "player.pairing_numbers_changed").summary ==
             "Before re-seeding the pairing numbers"
  end

  test "each way of re-seeding the starting numbers takes one", %{conn: conn, scope: scope} do
    t = tournament(scope, %{"type" => "roundrobin"})
    players(t, 4)
    {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/players")

    render_click(lv, "sn_by_rating")
    render_click(lv, "sn_by_entry")
    render_click(lv, "sn_draw_lots")

    summaries =
      t
      |> snapshots()
      |> Enum.filter(&(&1.trigger == "player.starting_numbers_set"))
      |> Enum.map(& &1.summary)

    assert Enum.sort(summaries) ==
             Enum.sort([
               "Before re-seeding the starting numbers by rating",
               "Before re-seeding the starting numbers by entry order",
               "Before drawing lots for the starting numbers"
             ])
  end

  describe "refreshing ratings" do
    setup %{scope: scope} do
      PairingsEngine.Meta.put("fide_list_period", PairingsEngine.Fide.month_of(Date.utc_today()))
      %{t: tournament(scope)}
    end

    test "applying proposals takes one, naming how many players", %{conn: conn, t: t} do
      {:ok, _} =
        Tournaments.create_player(t.id, %{
          "name" => "Alice",
          "fide_id" => "555555",
          "fide_rating" => "1900"
        })

      Repo.insert!(%FidePlayer{
        fide_id: 555_555,
        name: "Alice",
        federation: "BEL",
        title: "IM",
        standard_rating: 2100
      })

      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/players")
      lv |> element("button", "Refresh ratings") |> render_click()
      render_async(lv)
      lv |> element("#rating-refresh-apply") |> render_click()
      render(lv)

      assert one_snapshot!(t, "player.ratings_refreshed").summary ==
               "Before refreshing the ratings of 1 player"
    end

    test "applying with nothing selected writes nothing and takes none", %{conn: conn, t: t} do
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/players")
      render_click(lv, "apply_rating_refresh")
      assert snapshots(t) == []
    end
  end

  test "re-seeding the manual ranking takes one", %{conn: conn, scope: scope} do
    t = tournament(scope)
    players(t, 2)
    {:ok, t} = Tournaments.enable_manual_ranking(t)
    {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/standings")

    render_click(lv, "reseed_manual_ranking")

    assert one_snapshot!(t, "standings.manual_reseeded").summary ==
             "Before re-seeding the manual ranking"
  end

  test "applying the extra-points bands takes one", %{conn: conn, scope: scope} do
    t = tournament(scope)
    players(t, 2)
    {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/settings/extra-points")

    render_click(lv, "apply_extra_points_bands")

    assert one_snapshot!(t, "standings.extra_points_applied").summary ==
             "Before applying the extra-points bands"
  end

  test "ordering teams by rating takes one", %{conn: conn, scope: scope} do
    {t, _teams} = team_swiss([{"A", [2000, 1900]}, {"B", [1800, 1700]}], user_id: scope.user.id)
    {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/teams")

    render_click(lv, "seed_by_rating")

    assert one_snapshot!(t, "team.seeding_changed").summary ==
             "Before ordering the teams by rating"
  end

  describe "retention" do
    test "automatic points still prune; hand-saved ones are never pruned or counted", %{
      scope: scope
    } do
      t = tournament(scope)
      keep = Snapshots.keep_per_tournament()

      {:ok, manual} = Snapshots.capture(t, "snapshot.manual", scope, summary: "End of day 1")

      for n <- 1..(keep + 3) do
        {:ok, _} = Snapshots.capture(t, "player.bulk_category_set", scope, summary: "auto #{n}")
      end

      automatic = Enum.filter(snapshots(t), &(&1.trigger != "snapshot.manual"))

      assert length(automatic) == keep
      refute "auto 1" in Enum.map(automatic, & &1.summary)
      assert Snapshots.get(t.id, manual.id)
    end
  end
end
