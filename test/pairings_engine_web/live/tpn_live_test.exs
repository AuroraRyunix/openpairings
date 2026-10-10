defmodule PairingsEngineWeb.TpnLiveTest do
  # The Players page's "Pairing numbers" dialog for a Swiss tournament: TPN
  # exchange among equal ratings and regeneration, each confirmed
  # (VCL4THP Q147-Q155).
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Pairing, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Round}

  setup :register_and_log_in_user

  setup %{scope: scope} do
    {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Swiss TPN", "type" => "swiss"})

    players =
      for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1900}, {"Dave", 1800}],
          into: %{} do
        {:ok, p} = Tournaments.create_player(t.id, %{name: name, fide_rating: rating})
        {name, p}
      end

    %{t: t, p: players}
  end

  test "exchange is offered only between equal ratings, and it confirms",
       %{conn: conn, t: t, p: p} do
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
    lv |> element("#open-tpn") |> render_click()

    assert has_element?(lv, "#tpn-exchange-#{p["Bob"].id}[data-confirm]")
    refute has_element?(lv, "#tpn-exchange-#{p["Alice"].id}")
    refute has_element?(lv, "#tpn-exchange-#{p["Carol"].id}")

    lv |> element("#tpn-exchange-#{p["Bob"].id}") |> render_click()
    assert Enum.map(~w(Alice Carol Bob Dave), &number(p[&1])) == [1, 2, 3, 4]
  end

  test "a regeneration that moves numbers asks first, listing them",
       %{conn: conn, t: t, p: p} do
    {:ok, _round} = Pairing.pair_next_round(Repo.reload!(t))
    {:ok, _} = Tournaments.update_player(Repo.reload!(p["Dave"]), %{fide_rating: 2100})

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
    lv |> element("#open-tpn") |> render_click()
    assert has_element?(lv, "#tpn-pibe-note")

    lv |> element("#tpn-regenerate") |> render_click()
    assert has_element?(lv, "#tpn-regenerate-confirm")
    assert number(p["Dave"]) == 4

    lv |> element("#tpn-regenerate-go") |> render_click()
    refute has_element?(lv, "#tpn-regenerate-confirm")
    assert number(p["Dave"]) == 1
  end

  test "a regeneration with nothing to move says so and leaves no trace",
       %{conn: conn, t: t, p: p} do
    {:ok, _round} = Pairing.pair_next_round(Repo.reload!(t))
    entries = Repo.aggregate(PairingsEngine.Audit.AuditLog, :count, :id)

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
    lv |> element("#open-tpn") |> render_click()
    lv |> element("#tpn-regenerate") |> render_click()

    refute has_element?(lv, "#tpn-regenerate-confirm")
    assert has_element?(lv, "#flash-info")
    assert Enum.map(~w(Alice Bob Carol Dave), &number(p[&1])) == [1, 2, 3, 4]
    assert Repo.aggregate(PairingsEngine.Audit.AuditLog, :count, :id) == entries
  end

  test "no dialog once round 4 is paired", %{conn: conn, t: t} do
    for n <- 1..4, do: Repo.insert!(%Round{tournament_id: t.id, number: n, status: "done"})
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")

    refute has_element?(lv, "#open-tpn")
  end

  defp number(player), do: Repo.get!(Player, player.id).pairing_number
end
