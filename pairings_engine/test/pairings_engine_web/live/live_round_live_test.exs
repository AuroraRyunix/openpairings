defmodule PairingsEngineWeb.LiveRoundLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Tournaments, Pairing}

  setup :register_and_log_in_user

  test "renders a 'no rounds paired yet' placeholder before any round is paired", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => "Live T", "type" => "swiss"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live")

    assert html =~ "Live T"
    assert html =~ "no rounds paired yet"
  end

  test "shows the latest round's pairings and current standings, and updates live when a result is entered elsewhere",
       %{conn: conn, scope: scope} do
    {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => "Live T", "type" => "swiss"})
    {:ok, _white} = Tournaments.create_player(tournament.id, %{"name" => "White Player", "fide_rating" => "2000"})
    {:ok, _black} = Tournaments.create_player(tournament.id, %{"name" => "Black Player", "fide_rating" => "1900"})

    assert {:ok, _round} = Pairing.pair_next_round(tournament)

    {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/live")

    assert html =~ "Round 1"
    assert html =~ "White Player"
    assert html =~ "Black Player"
    assert html =~ "in progress"

    round = Tournaments.get_round(tournament.id, 1)
    pairing = hd(round.pairings)

    # Simulates another browser tab entering the result on the Pairings
    # page — this live view never touches the DB itself, it just reacts to
    # the tournament-topic broadcast.
    assert {:ok, _} = Tournaments.update_pairing_result(pairing, "1-0")

    assert render(lv) =~ "1-0"
  end

  test "redirects to the tournament list if the tournament is deleted while the page is open", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => "Live T", "type" => "swiss"})

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/live")

    assert {:ok, _} = Tournaments.delete_tournament(tournament)

    assert_redirect(lv, ~p"/")
  end
end
