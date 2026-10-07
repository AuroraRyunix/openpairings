defmodule PairingsEngineWeb.Chess960LiveTest do
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round}

  setup :register_and_log_in_user

  defp fixture(scope, chess960) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Chess960 page",
        "type" => "swiss",
        "rounds_count" => "3"
      })

    {:ok, t} = Tournaments.update_tournament(t, %{chess960: chess960})

    [a, b] =
      for {name, rating} <- [{"A", 2000}, {"B", 1800}],
          do: Repo.insert!(%Player{tournament_id: t.id, name: name, fide_rating: rating})

    r1 = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "pairing"})

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: ""
    })

    :ok = Tournaments.freeze_round_display_boards!(r1.id)
    t
  end

  test "the setting is saved from the settings page", %{conn: conn, scope: scope} do
    t = fixture(scope, false)
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings")

    lv
    |> form("#tournament-settings-form", %{"tournament" => %{"chess960" => "true"}})
    |> render_submit()

    assert Tournaments.get_tournament!(t.id).chess960
  end

  test "without the setting there is no draw button", %{conn: conn, scope: scope} do
    t = fixture(scope, false)
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    refute has_element?(lv, "#draw-chess960")
  end

  test "the arbiter draws once; the position shows on the page and the print", %{
    conn: conn,
    scope: scope
  } do
    t = fixture(scope, true)
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

    assert has_element?(lv, "#draw-chess960")
    refute has_element?(lv, "#chess960-position")

    lv |> element("#draw-chess960") |> render_click()

    assert has_element?(lv, "#chess960-position")
    refute has_element?(lv, "#draw-chess960")

    round = Repo.get_by!(Round, tournament_id: t.id, number: 1)
    assert round.chess960_position in 0..959
    label = PairingsEngine.Chess960.label(round)
    assert render(lv) =~ label

    assert [%{action: "pairing.chess960_drawn"} | _] =
             PairingsEngine.Audit.list_for_tournament(t.id, action: "pairing.chess960_drawn")

    html = conn |> get(~p"/t/#{t.id}/print/pairings?round=1") |> html_response(200)
    assert html =~ label
    # The starting position is drawn as a board beside it on the print...
    assert html =~ ~s(class="c960-board")

    # ...and on the page, behind the badge.
    assert has_element?(lv, "#chess960-diagram svg.c960-board")
  end

  test "the diagram puts the drawn order on ranks 1 and 8 and pawns on 2 and 7" do
    order = PairingsEngine.Chess960.position(117)
    svg = PairingsEngineWeb.Chess960Diagram.svg(117)

    assert order == "NQBBRNKR"
    assert svg =~ "Chess960 117 NQBBRNKR"
    # 8 white pieces, 8 white pawns, 8 black pawns, 8 black pieces.
    assert length(Regex.scan(~r/<text x="\d+" y="\d+" fill=/, svg)) == 32
    # 64 squares.
    assert length(Regex.scan(~r/<rect /, svg)) == 64
  end
end
