defmodule PairingsEngineWeb.MobileResultsLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Mobile, Tournaments}
  alias PairingsEngine.Pairing, as: Engine

  defp enrolled_conn(conn, tournament) do
    {:ok, enrollment} = Mobile.create_enrollment(tournament.id)
    init_test_session(conn, %{mobile_enrollment_id: enrollment.id})
  end

  defp paired_tournament do
    scope = user_scope_fixture()

    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Mobile T", "type" => "swiss"})

    {:ok, _white} =
      Tournaments.create_player(tournament.id, %{
        "name" => "White Player",
        "fide_rating" => "2000"
      })

    {:ok, _black} =
      Tournaments.create_player(tournament.id, %{
        "name" => "Black Player",
        "fide_rating" => "1900"
      })

    assert {:ok, _round} = Engine.pair_next_round(tournament)
    tournament
  end

  @tag :javafo
  test "shows each player's rating and their score entering the round", %{conn: conn} do
    tournament = paired_tournament()
    conn = enrolled_conn(conn, tournament)

    {:ok, _lv, html} = live(conn, ~p"/m/results")

    assert html =~ "2000"
    assert html =~ "1900"
    assert html =~ "0 pts"
  end

  @tag :javafo
  test "locking blocks result entry until unlocked again", %{conn: conn} do
    tournament = paired_tournament()
    conn = enrolled_conn(conn, tournament)

    {:ok, lv, html} = live(conn, ~p"/m/results")
    refute html =~ "locked - tap the lock to enter results"

    pairing = tournament.id |> Tournaments.get_round(1) |> Map.fetch!(:pairings) |> hd()

    lv |> element("button.mobile-lock-btn") |> render_click()
    assert render(lv) =~ "locked - tap the lock to enter results"

    # The result buttons are also `disabled` while locked (Phoenix.LiveViewTest
    # itself refuses to click a disabled element, mirroring a real browser) -
    # send the event directly to exercise the actual server-side guard.
    render_click(lv, "set_result", %{"id" => to_string(pairing.id), "result" => "1-0"})

    assert Tournaments.get_round(tournament.id, 1).pairings
           |> Enum.find(&(&1.id == pairing.id))
           |> Map.fetch!(:result) == ""

    lv |> element("button.mobile-lock-btn") |> render_click()

    render_click(lv, "set_result", %{"id" => to_string(pairing.id), "result" => "1-0"})

    assert Tournaments.get_round(tournament.id, 1).pairings
           |> Enum.find(&(&1.id == pairing.id))
           |> Map.fetch!(:result) == "1-0"
  end
end
