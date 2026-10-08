defmodule PairingsEngineWeb.TpnOutOfOrderLiveTest do
  # The Pairings page's warning about pairing numbers out of rating order,
  # and its way to the Players page's regeneration.
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias PairingsEngine.{Pairing, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  setup :register_and_log_in_user

  setup %{scope: scope} do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Order",
        "type" => "swiss",
        "rounds_count" => 5
      })

    Repo.update_all(from(x in Tournament, where: x.id == ^t.id),
      set: [late_entry_numbering: "end"]
    )

    players =
      for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1800}, {"Dave", 1700}] do
        {:ok, p} = Tournaments.create_player(t.id, %{name: name, fide_rating: rating})
        p
      end

    {:ok, _round} = Pairing.pair_next_round(Repo.reload!(t))
    %{t: Repo.reload!(t), players: players}
  end

  test "numbers in rating order: no warning", %{conn: conn, t: t} do
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    refute has_element?(lv, "#tpn-out-of-order")
  end

  test "a player numbered below their rating is named, and the page links to the regeneration",
       %{conn: conn, t: t, players: [_alice, bob, _carol, dave]} do
    # Bob (1900) holding 4, Dave (1700) holding 2: an older version's leftovers.
    Repo.update_all(from(p in Player, where: p.id == ^bob.id), set: [pairing_number: 4])
    Repo.update_all(from(p in Player, where: p.id == ^dave.id), set: [pairing_number: 2])

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    assert has_element?(lv, "#tpn-out-of-order-#{bob.id}")
    assert has_element?(lv, "#tpn-out-of-order-#{dave.id}")
    assert has_element?(lv, ~s|#tpn-out-of-order-regenerate[href="/t/#{t.id}/players?tpn=1"]|)

    {:ok, players_lv, _html} = live(conn, ~p"/t/#{t.id}/players?tpn=1")
    assert has_element?(players_lv, "#tpn-regenerate")
  end
end
