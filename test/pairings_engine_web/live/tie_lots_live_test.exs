defmodule PairingsEngineWeb.TieLotsLiveTest do
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Audit, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round}

  setup :register_and_log_in_user

  # Four players, one round, no tie-breaks: both games are drawn, so all four share a place.
  defp fixture(scope) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Lots page",
        "type" => "swiss",
        "rounds_count" => "1"
      })

    {:ok, t} = Tournaments.update_tournament(t, %{tiebreaks: []})

    [a, b, c, d] =
      for {name, rating} <- [{"A", 2000}, {"B", 1900}, {"C", 1800}, {"D", 1700}],
          do: Repo.insert!(%Player{tournament_id: t.id, name: name, fide_rating: rating})

    r1 = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "finished"})

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: "1/2-1/2"
    })

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 2,
      white_player_id: c.id,
      black_player_id: d.id,
      result: "1/2-1/2"
    })

    :ok = Tournaments.freeze_round_display_boards!(r1.id)
    t
  end

  test "the button draws lots, turns the manual ranking on and is audited", %{
    conn: conn,
    scope: scope
  } do
    t = fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/standings")

    assert has_element?(lv, "#draw-lots")
    lv |> element("#draw-lots") |> render_click()

    saved = Tournaments.get_tournament!(t.id)
    assert saved.manual_ranking
    assert is_integer(saved.lots_seed)
    assert [_] = Audit.list_for_tournament(t.id, action: "standings.lots_drawn")

    order = t.id |> Tournaments.list_players() |> Enum.map(& &1.manual_rank) |> Enum.sort()
    assert order == [1, 2, 3, 4]
  end
end
