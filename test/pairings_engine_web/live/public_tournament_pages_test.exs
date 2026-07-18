defmodule PairingsEngineWeb.PublicTournamentPagesTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Tournaments, Pairing}
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.AccountsFixtures

  # Public pages must work for a logged-out visitor — deliberately not
  # using `register_and_log_in_user` here, unlike every other LiveView
  # test in this app.
  defp owner_scope do
    user = AccountsFixtures.user_fixture()
    Scope.for_user(user)
  end

  defp fixture do
    scope = owner_scope()

    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Open Public Cup",
        "type" => "swiss",
        "rounds_count" => "3"
      })

    tournament
  end

  test "logged-out visitor can mount the public pairings page and sees a 'not paired yet' placeholder",
       %{conn: conn} do
    tournament = fixture()

    {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings")

    assert html =~ "Open Public Cup"
    assert html =~ "no rounds paired yet"
  end

  test "logged-out visitor can mount the public standings page", %{conn: conn} do
    tournament = fixture()

    {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/standings")

    assert html =~ "Open Public Cup"
    assert html =~ "Standings"
  end

  test "an unknown slug 404s", %{conn: conn} do
    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/p/does-not-exist/pairings")
    end

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/p/does-not-exist/standings")
    end
  end

  # fixture/0 is a default (swiss) tournament — pairs via JaVaFo.
  @tag :javafo
  test "shows the latest round's pairings and updates live when a result is entered elsewhere", %{
    conn: conn
  } do
    tournament = fixture()

    {:ok, white} =
      Tournaments.create_player(tournament.id, %{
        "name" => "White Player",
        "fide_rating" => "2000"
      })

    {:ok, _black} =
      Tournaments.create_player(tournament.id, %{
        "name" => "Black Player",
        "fide_rating" => "1900"
      })

    assert {:ok, _round} = Pairing.pair_next_round(tournament)

    {:ok, lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings")

    assert html =~ "Round 1"
    assert html =~ "White Player"
    assert html =~ "Black Player"
    assert html =~ "in progress"

    round = Tournaments.get_round(tournament.id, 1)
    pairing = hd(round.pairings)

    # Simulates the result being entered elsewhere (e.g. the authenticated
    # Pairings page) — this public view only ever reacts to the broadcast.
    assert {:ok, _} = Tournaments.update_pairing_result(pairing, "1-0")

    assert render(lv) =~ "1-0"
    refute white == nil
  end

  @tag :javafo
  test "public standings page updates live when a result is entered elsewhere", %{conn: conn} do
    tournament = fixture()

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

    assert {:ok, _round} = Pairing.pair_next_round(tournament)

    {:ok, lv, _html} = live(conn, ~p"/p/#{tournament.public_slug}/standings")

    round = Tournaments.get_round(tournament.id, 1)
    pairing = hd(round.pairings)

    assert {:ok, _} = Tournaments.update_pairing_result(pairing, "1-0")

    html = render(lv)
    assert html =~ "after round 1"
    assert html =~ "1.0"
  end

  test "shows 'no longer available' instead of crashing when the tournament is deleted while the page is open",
       %{
         conn: conn
       } do
    tournament = fixture()

    {:ok, lv, _html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings")

    assert {:ok, _} = Tournaments.delete_tournament(tournament)

    assert render(lv) =~ "no longer available"
  end
end
