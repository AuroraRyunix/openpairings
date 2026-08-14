defmodule PairingsEngineWeb.PublicPairingsLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Round, Pairing}

  # No login — the public page needs no `register_and_log_in_user` setup.

  test "has no app chrome (topbar tabs/accent picker/sign-in), shows tempo when set", %{
    conn: conn
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(%{
        "name" => "Chrome Test",
        "type" => "swiss",
        "rate_of_play" => "15 min + 10 sec/move"
      })

    {:ok, tournament} = Tournaments.set_public_pages(tournament, true)

    {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings")

    refute html =~ "accent-picker"
    refute html =~ "topbar-signin"
    assert html =~ "theme-picker"
    assert html =~ "Tempo: 15 min + 10 sec/move"
  end

  test "board list shows each player's score coming INTO the round, next to their rating", %{
    conn: conn
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(%{
        "name" => "Public Score Test",
        "type" => "swiss",
        "rounds_count" => "2"
      })

    {:ok, tournament} = Tournaments.set_public_pages(tournament, true)

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

    {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings")

    # A won round 1, so entering round 2 A is at 1, B at 0.
    assert html =~ "A (2000, 1)"
    assert html =~ "B (1800, 0)"
  end

  test "renders a round's pairings sorted by board number regardless of insertion order", %{
    conn: conn
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(%{
        "name" => "Board Order Test",
        "type" => "swiss",
        "rounds_count" => "1"
      })

    {:ok, tournament} = Tournaments.set_public_pages(tournament, true)

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

    {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings")

    positions =
      for name <- ["Boardonealice", "Boardtwocarol", "Boardthreeeve"],
          do: :binary.match(html, name) |> elem(0)

    assert positions == Enum.sort(positions), "expected boards 1, 2, 3 top to bottom"
  end

  test "a hidden (fully-vacated) row never renders, and its board number doesn't reappear on another row",
       %{conn: conn} do
    {:ok, tournament} =
      Tournaments.create_tournament(%{
        "name" => "Hidden Row Public Test",
        "type" => "swiss",
        "rounds_count" => "1"
      })

    {:ok, tournament} = Tournaments.set_public_pages(tournament, true)

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

    {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings")

    assert html =~ "Stillhereclara"
    # Board 2's label was frozen before board 1 was ever hidden — hiding it
    # later must not renumber board 2 down to "1".
    assert html =~ ~s(<td class="num">2</td>)
    refute html =~ ~s(<td class="num">1</td>)
  end

  test "a fixed-table board shows the SAME label and position as the authenticated Pairings page",
       %{conn: conn} do
    # Regression: the public page used to sort by raw `pairing.board` and
    # never relabeled anything, so a fixed-table pairing showed its real
    # engine board number here while the authenticated page (and print)
    # showed the fixed_board value and moved it to the end — the same
    # round looked different depending on which page you were on.
    {:ok, tournament} =
      Tournaments.create_tournament(%{
        "name" => "Public Fixed Board Test",
        "type" => "swiss",
        "rounds_count" => "1"
      })

    {:ok, tournament} = Tournaments.set_public_pages(tournament, true)

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

    {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings")

    assert html =~ ~s(<td class="num">1001</td>)
    refute html =~ ~s(<td class="num">2</td>)

    shifted_pos = :binary.match(html, "Shiftedsam") |> elem(0)
    wheelchair_pos = :binary.match(html, "Wheelchairwendy") |> elem(0)
    assert shifted_pos < wheelchair_pos
  end

  test "shows byes-table rows (SWAR-imported/round-specific absentee byes) alongside the round's pairings",
       %{
         conn: conn
       } do
    {:ok, tournament} =
      Tournaments.create_tournament(%{
        "name" => "Byes Display Test",
        "type" => "swiss",
        "rounds_count" => "1"
      })

    {:ok, tournament} = Tournaments.set_public_pages(tournament, true)

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
      %{tournament_id: tournament.id, player_id: absentee.id, round: 1, type: "requested-half"}
    ])

    {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings")

    assert html =~ "Absentee"
    assert html =~ "requested half-point bye"
  end

  describe "round history (?round=N)" do
    setup do
      {:ok, tournament} =
        Tournaments.create_tournament(%{
          "name" => "Round History Test",
          "type" => "swiss",
          "rounds_count" => "3"
        })

      {:ok, tournament} = Tournaments.set_public_pages(tournament, true)

      [a, b] =
        for name <- ["Alice", "Bob"] do
          Repo.insert!(%Player{tournament_id: tournament.id, name: name})
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

      %{tournament: tournament, alice: a, bob: b}
    end

    test "defaults to the latest paired round, not just always round 1", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings")

      assert html =~ "Round 2"
    end

    test "a round-picker links to every round, including unpaired round 3", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, lv, _html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings")

      assert has_element?(lv, ".round-picker a", "3")
    end

    test "clicking round 1 in the picker shows round 1's own pairing, not round 2's", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, lv, _html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings")

      html =
        lv
        |> element(".round-picker a", "1")
        |> render_click()

      assert html =~ "Round 1"
      # Round 1: Alice (white) vs Bob (black), 1-0 — entering it both are at 0.
      assert html =~ "Alice (0)"
      assert html =~ "Bob (0)"
    end

    test "requesting a not-yet-paired round shows a placeholder instead of the latest round", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings?round=3")

      assert html =~ "Round 3"
      assert html =~ "hasn&#39;t been published yet"
    end

    test "an out-of-range round falls back to the latest paired round", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings?round=99")

      assert html =~ "Round 2"
    end

    test "standings page links to the pairings/round-history page", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/standings")

      assert html =~ ~s(href="/p/#{tournament.public_slug}/pairings")
    end

    test "pairings page links to standings", %{conn: conn, tournament: tournament} do
      {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings")

      assert html =~ ~s(href="/p/#{tournament.public_slug}/standings")
    end
  end

  describe "publish gating (manual/timed/scheduled publish_mode)" do
    defp manual_fixture do
      {:ok, tournament} =
        Tournaments.create_tournament(%{
          "name" => "Gating Test",
          "type" => "swiss",
          "rounds_count" => "3",
          "publish_mode" => "manual"
        })

      {:ok, tournament} = Tournaments.set_public_pages(tournament, true)

      [a, b] =
        for name <- ["A", "B"] do
          Repo.insert!(%Player{tournament_id: tournament.id, name: name})
        end

      round1 =
        Repo.insert!(%Round{tournament_id: tournament.id, number: 1, published_at: nil})

      Repo.insert!(%Pairing{
        round_id: round1.id,
        board: 1,
        white_player_id: a.id,
        black_player_id: b.id
      })

      %{tournament: tournament, a: a, b: b}
    end

    test "an unpublished round shows the placeholder, not its pairings", %{conn: conn} do
      %{tournament: tournament} = manual_fixture()

      {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings")

      assert html =~ "no rounds published yet"
      refute html =~ "table-card"
    end

    test "explicitly requesting the unpublished round via ?round=1 still hides it", %{conn: conn} do
      %{tournament: tournament} = manual_fixture()

      {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings?round=1")

      # Nothing at all has been published yet, so this reads the same as
      # the no-`?round=` case above — not "Round 1 hasn't been published
      # yet." (that more specific wording is reserved for when at least
      # one OTHER round is already public; see the out-of-order test below).
      assert html =~ "No round has been published yet"
      refute html =~ "table-card"
    end

    test "publishing the round makes it visible on the public page", %{conn: conn} do
      %{tournament: tournament} = manual_fixture()
      round = Tournaments.get_round(tournament.id, 1)

      {:ok, _round} = Tournaments.publish_round_now(round)

      {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings")

      assert html =~ "Round 1"
      assert html =~ "A"
      assert html =~ "B"
    end

    test "a round published out of order is visible even though a later round isn't", %{
      conn: conn
    } do
      %{tournament: tournament, a: a, b: b} = manual_fixture()

      round2 = Repo.insert!(%Round{tournament_id: tournament.id, number: 2, published_at: nil})

      Repo.insert!(%Pairing{
        round_id: round2.id,
        board: 1,
        white_player_id: b.id,
        black_player_id: a.id
      })

      # Publish round 2 but leave round 1 hidden.
      {:ok, _} = Tournaments.publish_round_now(round2)

      {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings?round=2")
      assert html =~ "Round 2"
      assert html =~ "A"

      {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings?round=1")
      assert html =~ "hasn&#39;t been published yet"
    end

    test "with no ?round= param, defaults to the latest PUBLISHED round, not the latest paired one",
         %{conn: conn} do
      %{tournament: tournament, a: a, b: b} = manual_fixture()
      round1 = Tournaments.get_round(tournament.id, 1)
      {:ok, _} = Tournaments.publish_round_now(round1)

      # Round 2 is paired but not published.
      round2 = Repo.insert!(%Round{tournament_id: tournament.id, number: 2, published_at: nil})

      Repo.insert!(%Pairing{
        round_id: round2.id,
        board: 1,
        white_player_id: b.id,
        black_player_id: a.id
      })

      {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/pairings")

      assert html =~ "Round 1"
      refute html =~ "Round 2"
    end
  end
end
