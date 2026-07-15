defmodule PairingsEngineWeb.LiveRoundLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.{Player, Round, Pairing}

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

  # A default (swiss) tournament — pairs via JaVaFo, unlike the keizer test
  # below which dispatches to PairingsEngine.Keizer instead.
  @tag :javafo
  test "shows the latest round's pairings and current standings, and updates live when a result is entered elsewhere",
       %{conn: conn, scope: scope} do
    {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => "Live T", "type" => "swiss"})
    {:ok, _white} = Tournaments.create_player(tournament.id, %{"name" => "White Player", "fide_rating" => "2000"})
    {:ok, _black} = Tournaments.create_player(tournament.id, %{"name" => "Black Player", "fide_rating" => "1900"})

    assert {:ok, _round} = Engine.pair_next_round(tournament)

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

  test "renders a round's pairings sorted by board number regardless of insertion order", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Board Order Test", "type" => "swiss", "rounds_count" => "1"})

    [a, b, c, d, e, f] =
      for name <- ["Boardonealice", "Boardonebob", "Boardtwocarol", "Boardtwodave", "Boardthreeeve", "Boardthreefred"] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name})
      end

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

    Repo.insert!(%Pairing{round_id: round.id, board: 3, white_player_id: e.id, black_player_id: f.id, result: ""})
    Repo.insert!(%Pairing{round_id: round.id, board: 1, white_player_id: a.id, black_player_id: b.id, result: ""})
    Repo.insert!(%Pairing{round_id: round.id, board: 2, white_player_id: c.id, black_player_id: d.id, result: ""})

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live")

    positions =
      for name <- ["Boardonealice", "Boardtwocarol", "Boardthreeeve"],
        do: :binary.match(html, name) |> elem(0)

    assert positions == Enum.sort(positions), "expected boards 1, 2, 3 top to bottom"
  end

  test "shows byes-table rows (SWAR-imported/round-specific absentee byes) alongside the round's pairings", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Byes Display Test", "type" => "swiss", "rounds_count" => "1"})

    [a, b, absentee] =
      for name <- ["A", "B", "Absentee"] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name})
      end

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})
    Repo.insert!(%Pairing{round_id: round.id, board: 1, white_player_id: a.id, black_player_id: b.id, result: ""})

    Repo.insert_all("byes", [
      %{tournament_id: tournament.id, player_id: absentee.id, round: 1, type: "absent"}
    ])

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live")

    assert html =~ "Absentee"
    assert html =~ "absent"
  end

  test "a keizer tournament shows the ladder table (Value/Keizer pts/Score), not the FIDE tiebreak table", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Keizer Live T",
        "type" => "swiss",
        "pairing_system" => "keizer",
        "rounds_count" => "3"
      })

    {:ok, _a} = Tournaments.create_player(tournament.id, %{"name" => "Alice", "fide_rating" => "2000"})
    {:ok, _b} = Tournaments.create_player(tournament.id, %{"name" => "Bob", "fide_rating" => "1900"})

    assert {:ok, _round} = Engine.pair_next_round(tournament)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live")

    assert html =~ "Alice"
    assert html =~ "Bob"
    assert html =~ ">Value<"
    assert html =~ ">Keizer pts<"
    assert html =~ ">Score<"
    refute html =~ ">Pts<"
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
