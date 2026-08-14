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
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Live T", "type" => "swiss"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live")

    assert html =~ "Live T"
    assert html =~ "no rounds paired yet"
  end

  test "board list shows each player's score coming INTO the round, next to their rating", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Live Score Test",
        "type" => "swiss",
        "rounds_count" => "2"
      })

    [a, b] =
      for {name, rating} <- [{"A", 2000}, {"B", 1800}] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name, fide_rating: rating})
      end

    round1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})

    Repo.insert!(%Pairing{
      round_id: round1.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: "1-0"
    })

    round2 = Repo.insert!(%Round{tournament_id: tournament.id, number: 2, status: "playing"})

    Repo.insert!(%Pairing{
      round_id: round2.id,
      board: 1,
      white_player_id: b.id,
      black_player_id: a.id,
      result: ""
    })

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live")

    assert html =~ "A (2000, 1)"
    assert html =~ "B (1800, 0)"
  end

  test "a fixed-table board shows the SAME label and position as the authenticated Pairings page",
       %{conn: conn, scope: scope} do
    # Regression: this page used to sort by raw `pairing.board` and never
    # relabeled anything, so a fixed-table pairing showed its real engine
    # board number here while the Pairings page (and print) showed the
    # fixed_board value and moved it to the end.
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Live Fixed Board Test",
        "type" => "swiss",
        "rounds_count" => "1"
      })

    [wheelchair, wopp, shifted, sopp] =
      for name <- ["Wheelchairwendy", "Wheelchairopp", "Shiftedsam", "Shiftedopp"] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name})
      end

    Repo.update!(Ecto.Changeset.change(wheelchair, fixed_board: 1001))

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 1,
      white_player_id: wheelchair.id,
      black_player_id: wopp.id,
      result: ""
    })

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 2,
      white_player_id: shifted.id,
      black_player_id: sopp.id,
      result: ""
    })

    :ok = Tournaments.freeze_round_display_boards!(round.id)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live")

    # Not a bare `refute html =~ ~s(<td class="num">2</td>)` — the
    # standings table further down the same page legitimately has its own
    # "2"s (rank, points, etc.) unrelated to board numbering.
    assert html =~ ~s(<td class="num">1001</td>)

    shifted_pos = :binary.match(html, "Shiftedsam") |> elem(0)
    wheelchair_pos = :binary.match(html, "Wheelchairwendy") |> elem(0)
    assert shifted_pos < wheelchair_pos
  end

  # A default (swiss) tournament — pairs via JaVaFo, unlike the keizer test
  # below which dispatches to PairingsEngine.Keizer instead.
  @tag :javafo
  test "shows the latest round's pairings and current standings, and updates live when a result is entered elsewhere",
       %{conn: conn, scope: scope} do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Live T", "type" => "swiss"})

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
      Tournaments.create_tournament(scope, %{
        "name" => "Board Order Test",
        "type" => "swiss",
        "rounds_count" => "1"
      })

    [a, b, c, d, e, f] =
      for name <- [
            "Boardonealice",
            "Boardonebob",
            "Boardtwocarol",
            "Boardtwodave",
            "Boardthreeeve",
            "Boardthreefred"
          ] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name})
      end

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 3,
      white_player_id: e.id,
      black_player_id: f.id,
      result: ""
    })

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: ""
    })

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 2,
      white_player_id: c.id,
      black_player_id: d.id,
      result: ""
    })

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live")

    positions =
      for name <- ["Boardonealice", "Boardtwocarol", "Boardthreeeve"],
          do: :binary.match(html, name) |> elem(0)

    assert positions == Enum.sort(positions), "expected boards 1, 2, 3 top to bottom"
  end

  test "a hidden (fully-vacated) row never renders, but every other board keeps its label", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Hidden Row Live Test",
        "type" => "swiss",
        "rounds_count" => "1"
      })

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 1,
      white_player_id: nil,
      black_player_id: nil,
      result: "",
      hidden: true
    })

    [c, d] =
      for name <- ["Stillhereclara", "Stillheredan"] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name})
      end

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 2,
      white_player_id: c.id,
      black_player_id: d.id,
      result: ""
    })

    :ok = Tournaments.freeze_round_display_boards!(round.id)

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/live")

    # Scope to the board-list table specifically ("Board" as the text
    # filter) — the standings table right below it shares the same
    # `pe-table` class and legitimately has its own "1"s (rank, etc.)
    # unrelated to board numbering.
    pairings_html = lv |> element("table.pe-table", "Board") |> render()

    assert pairings_html =~ "Stillhereclara"
    # Board 2's label was frozen at pairing time, before board 1 was ever
    # hidden — hiding board 1 later must NOT retroactively renumber board
    # 2 down to "1" (that would be exactly the 0.14.6 bug class). Board 2
    # simply stops having a "1" row above it; its own label is untouched.
    assert pairings_html =~ ~s(<td class="num">2</td>)
    refute pairings_html =~ ~s(<td class="num">1</td>)
  end

  test "shows byes-table rows (SWAR-imported/round-specific absentee byes) alongside the round's pairings",
       %{
         conn: conn,
         scope: scope
       } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Byes Display Test",
        "type" => "swiss",
        "rounds_count" => "1"
      })

    [a, b, absentee] =
      for name <- ["A", "B", "Absentee"] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name})
      end

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: ""
    })

    Repo.insert_all("byes", [
      %{tournament_id: tournament.id, player_id: absentee.id, round: 1, type: "absent"}
    ])

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live")

    assert html =~ "Absentee"
    assert html =~ "absent"
  end

  test "a keizer tournament shows the ladder table (Value/Keizer pts/Score), not the FIDE tiebreak table",
       %{
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

    {:ok, _a} =
      Tournaments.create_player(tournament.id, %{"name" => "Alice", "fide_rating" => "2000"})

    {:ok, _b} =
      Tournaments.create_player(tournament.id, %{"name" => "Bob", "fide_rating" => "1900"})

    assert {:ok, _round} = Engine.pair_next_round(tournament)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live")

    assert html =~ "Alice"
    assert html =~ "Bob"
    assert html =~ ">Value<"
    assert html =~ ">Keizer pts<"
    assert html =~ ">Score<"
    refute html =~ ">Pts<"
  end

  test "shows a public-standings QR when public pages are on, and an enable-them hint when off",
       %{
         conn: conn,
         scope: scope
       } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Public QR Test", "type" => "swiss"})

    {:ok, tournament} = Tournaments.set_public_pages(tournament, true)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live")

    assert html =~ "enroll-qr-inner"
    assert html =~ "/p/#{tournament.public_slug}/standings"

    assert {:ok, tournament} = Tournaments.set_public_pages(tournament, false)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live")

    assert html =~ "Public pages are off for this tournament."
    refute html =~ "enroll-qr-inner"
  end

  test "redirects to the tournament list if the tournament is deleted while the page is open", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Live T", "type" => "swiss"})

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/live")

    assert {:ok, _} = Tournaments.delete_tournament(tournament)

    assert_redirect(lv, ~p"/")
  end
end
