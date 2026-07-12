defmodule PairingsEngineWeb.PairingsLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Round, Pairing}

  setup :register_and_log_in_user

  defp fixture(scope) do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Pairings Print Test", "type" => "swiss", "rounds_count" => "3"})

    [a, b] =
      for {name, rating} <- [{"A", 2000}, {"B", 1800}] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name, fide_rating: rating})
      end

    r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})
    r2 = Repo.insert!(%Round{tournament_id: tournament.id, number: 2, status: "finished"})

    Repo.insert!(%Pairing{round_id: r1.id, board: 1, white_player_id: a.id, black_player_id: b.id, result: "1-0"})
    Repo.insert!(%Pairing{round_id: r2.id, board: 1, white_player_id: b.id, black_player_id: a.id, result: "1-0"})

    tournament
  end

  test "print pairings/standings links open the currently selected round in a new tab", %{
    conn: conn,
    scope: scope
  } do
    tournament = fixture(scope)

    {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    # Two rounds are paired, so the view defaults to the latest one (round 2).
    assert html =~ ~s(href="/t/#{tournament.id}/print/pairings?round=2")
    assert html =~ ~s(href="/t/#{tournament.id}/print/standings?round=2")
    assert html =~ ~s(target="_blank")

    html = lv |> element("button[phx-value-number='1']") |> render_click()

    assert html =~ ~s(href="/t/#{tournament.id}/print/pairings?round=1")
    assert html =~ ~s(href="/t/#{tournament.id}/print/standings?round=1")
  end

  test "no print links are shown for an unpaired round", %{conn: conn, scope: scope} do
    tournament = fixture(scope)

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    html = lv |> element("button[phx-value-number='3']") |> render_click()

    refute html =~ ~s(print/pairings?round=3)
    refute html =~ ~s(print/standings?round=3)
  end

  test "shows a public pairings link pointing at the tournament's public slug", %{conn: conn, scope: scope} do
    tournament = fixture(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    assert tournament.public_slug
    assert html =~ ~s(href="/p/#{tournament.public_slug}/pairings")
    assert html =~ "Public pairings link"
  end
end
