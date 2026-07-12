defmodule PairingsEngineWeb.PlayersLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.Tournaments

  setup :register_and_log_in_user

  test "print player list / player cards links open the roster-wide documents in a new tab", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => "Players Print Test", "type" => "swiss"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

    assert html =~ ~s(href="/t/#{tournament.id}/print/players")
    assert html =~ ~s(href="/t/#{tournament.id}/print/cards")
    assert html =~ "Print player list"
    assert html =~ "Print player cards"
    assert html =~ ~s(target="_blank")
  end
end
