defmodule PairingsEngineWeb.LongEventRefreshLiveTest do
  @moduledoc """
  Refresh ratings on the Players page of a tournament lasting more than 30
  days (later ratings from a round, the starting rating untouched), and the
  "?" explainer on the Settings tick.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Meta, Repo, Tournaments}
  alias PairingsEngine.Fide.FidePlayer
  alias PairingsEngine.Tournaments.Player

  setup :register_and_log_in_user

  defp long_tournament(scope) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Winter league",
        "type" => "swiss",
        "rounds_count" => "6",
        "long_event" => "true"
      })

    t
  end

  test "Refresh adds a later rating from a chosen round and leaves the starting rating", %{
    conn: conn,
    scope: scope
  } do
    Meta.put("fide_list_period", "2026-11")
    t = long_tournament(scope)

    {:ok, p} =
      Tournaments.create_player(t.id, %{
        "name" => "Alice",
        "fide_id" => "1",
        "fide_rating" => "1000"
      })

    Repo.insert!(%FidePlayer{fide_id: 1, name: "Alice", standard_rating: 1100})

    {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/players")
    refute has_element?(lv, "#rating-check-notice")

    lv |> element("button", "Refresh ratings") |> render_click()
    render_async(lv)

    assert has_element?(lv, "#rating-refresh-round-form")
    assert has_element?(lv, "#rating-proposal-row-#{p.id}-period_rating")

    lv |> form("#rating-refresh-round-form", %{"round" => "4"}) |> render_change()
    assert has_element?(lv, "#rating-refresh-round[value='4']")

    lv |> element("#rating-refresh-apply") |> render_click()

    p = Repo.get!(Player, p.id)
    assert p.fide_rating == 1000
    assert p.period_ratings == [%{"from_round" => 4, "fide_rating" => 1100}]
  end

  test "Cancel writes nothing", %{conn: conn, scope: scope} do
    Meta.put("fide_list_period", "2026-11")
    t = long_tournament(scope)

    {:ok, p} =
      Tournaments.create_player(t.id, %{"name" => "A", "fide_id" => "1", "fide_rating" => "1000"})

    Repo.insert!(%FidePlayer{fide_id: 1, name: "A", standard_rating: 1100})

    {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/players")
    lv |> element("button", "Refresh ratings") |> render_click()
    render_async(lv)
    lv |> element("#rating-refresh-dialog button", "Cancel") |> render_click()

    refute has_element?(lv, "#rating-refresh-dialog")
    assert Repo.get!(Player, p.id).period_ratings == []
  end

  test "the Settings tick has its explainer, with the text in the popover", %{
    conn: conn,
    scope: scope
  } do
    t = long_tournament(scope)
    {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/settings")

    assert has_element?(lv, "#long-event-explain")
    assert has_element?(lv, "#long-event-explain-button[aria-expanded='false']")
    assert has_element?(lv, "#long-event-explain-text", "later rating")
  end
end
