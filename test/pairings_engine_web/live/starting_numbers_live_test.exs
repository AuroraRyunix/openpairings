defmodule PairingsEngineWeb.StartingNumbersLiveTest do
  # The Players page's "Starting numbers" dialog for a round robin (C.05 6.2,
  # VCL4THP Q95).
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Pairing, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  setup :register_and_log_in_user

  setup %{scope: scope} do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{"name" => "RR draw", "type" => "swiss"})

    t =
      t
      |> Ecto.Changeset.change(pairing_system: "round_robin", rr_cycles: 1, rounds_count: 3)
      |> Repo.update!()

    players =
      for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1800}, {"Dave", 1700}],
          into: %{} do
        {:ok, p} = Tournaments.create_player(t.id, %{name: name, fide_rating: rating})
        {name, p}
      end

    %{t: t, p: players}
  end

  test "the dialog moves players and types numbers, and round 1 pairs by them",
       %{conn: conn, t: t, p: p} do
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")

    lv |> element("#open-starting-numbers") |> render_click()
    assert has_element?(lv, "#starting-numbers-dialog")

    lv |> element("#sn-down-#{p["Alice"].id}") |> render_click()
    assert number(p["Bob"]) == 1
    assert number(p["Alice"]) == 2

    lv
    |> form("#sn-number-#{p["Dave"].id}", %{"number" => "1"})
    |> render_submit()

    assert Enum.map(~w(Dave Bob Alice Carol), &number(p[&1])) == [1, 2, 3, 4]

    {:ok, round} = Pairing.pair_next_round(Repo.reload!(t))
    pairs = round |> Repo.preload(:pairings) |> Map.fetch!(:pairings)

    assert Enum.any?(
             pairs,
             &(&1.white_player_id == p["Dave"].id and &1.black_player_id == p["Carol"].id)
           )
  end

  test "drawing lots numbers every player", %{conn: conn, t: t, p: p} do
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")

    lv |> element("#open-starting-numbers") |> render_click()
    lv |> element("#sn-draw-lots") |> render_click()

    assert p |> Map.values() |> Enum.map(&number/1) |> Enum.sort() == [1, 2, 3, 4]
  end

  test "no dialog once round 1 is paired", %{conn: conn, t: t} do
    {:ok, _round} = Pairing.pair_next_round(t)
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")

    refute has_element?(lv, "#open-starting-numbers")
  end

  test "no dialog for a Swiss tournament", %{conn: conn, scope: scope} do
    {:ok, swiss} = Tournaments.create_tournament(scope, %{"name" => "Swiss", "type" => "swiss"})
    {:ok, lv, _html} = live(conn, ~p"/t/#{swiss.id}/players")

    refute has_element?(lv, "#open-starting-numbers")
    assert %Tournament{} = swiss
  end

  defp number(player), do: Repo.get!(Player, player.id).pairing_number
end
