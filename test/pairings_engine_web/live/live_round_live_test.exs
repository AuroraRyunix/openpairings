defmodule PairingsEngineWeb.LiveRoundLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Mobile, Publishing, Repo, Tournaments}
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.{Player, Round, Pairing}

  setup :register_and_log_in_user

  # This page shows what is PUBLISHED, not what is paired - projecting a round
  # in the hall is publishing it, so the two cannot differ. New tournaments are
  # created "manual" (the schema's default, which quietly overrides the
  # migration's "immediate"), so a test that pairs a round and then expects to
  # see it has to publish it, exactly as an arbiter would.
  # A round inserted straight into the table has no `published_at`, and this
  # page shows only what is published. These tests are about how boards
  # render, so they publish as they insert.
  defp published_now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp publish_paired_rounds(tournament) do
    for n <- 1..PairingsEngine.Pairing.paired_rounds_count(tournament.id)//1 do
      {:ok, _} = Tournaments.publish_round_now(Tournaments.get_round(tournament.id, n))
    end

    tournament
  end

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

    round1 =
      Repo.insert!(%Round{
        tournament_id: tournament.id,
        number: 1,
        status: "finished",
        published_at: published_now()
      })

    Repo.insert!(%Pairing{
      round_id: round1.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: "1-0"
    })

    round2 =
      Repo.insert!(%Round{
        tournament_id: tournament.id,
        number: 2,
        status: "playing",
        published_at: published_now()
      })

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

  # Same White-right/Result-centre/Black-left convention as the arbiter's
  # Pairings page (see `assets/css/app.css`), so the projected sheet reads
  # the same way as the one at the desk.
  test "board table columns carry the White/Result/Black alignment classes on header and cells",
       %{
         conn: conn,
         scope: scope
       } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Live Alignment Test",
        "type" => "swiss",
        "rounds_count" => "1"
      })

    [a, b] =
      for {name, rating} <- [{"A", 2000}, {"B", 1800}] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name, fide_rating: rating})
      end

    round =
      Repo.insert!(%Round{
        tournament_id: tournament.id,
        number: 1,
        status: "playing",
        published_at: published_now()
      })

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: ""
    })

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live")

    assert html =~ ~s(<th class="pairing-white">)
    assert html =~ ~s(<th class="pairing-result">)
    assert html =~ ~s(<th class="pairing-black">)
    assert html =~ ~s(<td class="pairing-white">)
    assert html =~ ~s(<td class="pairing-result">)
    assert html =~ ~s(<td class="pairing-black">)

    refute html =~ ~s(style="text-align: center; width: 160px")
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

    round =
      Repo.insert!(%Round{
        tournament_id: tournament.id,
        number: 1,
        status: "playing",
        published_at: published_now()
      })

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

    # Not a bare `refute html =~ ~s(<td class="num">2</td>)` - the
    # standings table further down the same page legitimately has its own
    # "2"s (rank, points, etc.) unrelated to board numbering.
    assert html =~ ~s(<td class="num">1001</td>)

    shifted_pos = :binary.match(html, "Shiftedsam") |> elem(0)
    wheelchair_pos = :binary.match(html, "Wheelchairwendy") |> elem(0)
    assert shifted_pos < wheelchair_pos
  end

  # A default (swiss) tournament - pairs via JaVaFo, unlike the keizer test
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
    publish_paired_rounds(tournament)

    {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/live")

    assert html =~ "Round 1"
    assert html =~ "White Player"
    assert html =~ "Black Player"
    assert html =~ "in progress"

    round = Tournaments.get_round(tournament.id, 1)
    pairing = hd(round.pairings)

    # Simulates another browser tab entering the result on the Pairings
    # page - this live view never touches the DB itself, it just reacts to
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

    round =
      Repo.insert!(%Round{
        tournament_id: tournament.id,
        number: 1,
        status: "playing",
        published_at: published_now()
      })

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

    round =
      Repo.insert!(%Round{
        tournament_id: tournament.id,
        number: 1,
        status: "playing",
        published_at: published_now()
      })

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
    # filter) - the standings table right below it shares the same
    # `pe-table` class and legitimately has its own "1"s (rank, etc.)
    # unrelated to board numbering.
    pairings_html = lv |> element("table.pe-table", "Board") |> render()

    assert pairings_html =~ "Stillhereclara"
    # Board 2's label was frozen at pairing time, before board 1 was ever
    # hidden - hiding board 1 later must NOT retroactively renumber board
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

    round =
      Repo.insert!(%Round{
        tournament_id: tournament.id,
        number: 1,
        status: "playing",
        published_at: published_now()
      })

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
    publish_paired_rounds(tournament)

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

    Publishing.put_endpoint("https://results.example.org")
    {:ok, tournament} = Tournaments.set_publish_to_openresults(tournament, true)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live")

    assert html =~ "enroll-qr-inner"
    assert html =~ "https://results.example.org/t/#{tournament.public_slug}"

    # The one a hall full of people actually scans. It must never resolve to
    # the machine running the round.
    refute html =~ "/p/#{tournament.public_slug}"

    assert {:ok, tournament} = Tournaments.set_publish_to_openresults(tournament, false)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live")

    assert html =~ "This tournament is not published"
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

  describe "enrolling a phone, and where it cannot work" do
    # The QR encodes this endpoint's host, which local mode sets to
    # "localhost" - a phone scanning that resolves its OWN localhost. And
    # the listener is pinned to 127.0.0.1, so even the laptop's real LAN
    # address would be refused.
    #
    # That pin is what makes a no-login build safe: the mode prints login
    # links to a terminal and auto-signs-in whoever reaches it. Binding
    # wider to make the QR work would hand sign-in-as-the-owner to everyone
    # on the venue wifi. So the page says why rather than offering a control
    # that cannot work.
    defp local_mode(on?) do
      previous = Application.get_env(:pairings_engine, :local_mode)
      Application.put_env(:pairings_engine, :local_mode, on?)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:pairings_engine, :local_mode)
          value -> Application.put_env(:pairings_engine, :local_mode, value)
        end
      end)
    end

    defp paired_tournament(scope) do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Phone",
          "type" => "swiss",
          "rounds_count" => "3"
        })

      for {name, n} <- [{"A", 1}, {"B", 2}] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name, pairing_number: n})
      end

      {:ok, _} = Engine.pair_next_round(tournament)
      publish_paired_rounds(tournament)
      tournament
    end

    test "a hosted run offers the code", %{conn: conn, scope: scope} do
      local_mode(false)
      tournament = paired_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live")

      assert html =~ "Generate a code"
    end

    test "a local run explains instead of offering it", %{conn: conn, scope: scope} do
      local_mode(true)
      tournament = paired_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live")

      # No control that cannot work...
      refute html =~ "Generate a code"
      # ...and a reason, so an arbiter who has heard of the feature is not
      # left hunting for a panel that silently vanished.
      assert html =~ "Not available when OpenPairings runs on your own computer"
    end

    test "the mint form creates an enrolment with the chosen level and board range", %{
      conn: conn,
      scope: scope
    } do
      local_mode(false)
      tournament = paired_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/live")

      html =
        lv
        |> form("form[phx-submit=generate_enrollment]", %{
          "level" => "helper",
          "board_from" => "1",
          "board_to" => "5"
        })
        |> render_submit()

      # The just-minted panel, and the device list below it, both say what
      # the code may do - not just that a code exists.
      assert html =~ "Boards 1-5"
      assert html =~ "Helper"

      assert [enrollment] = Mobile.list_enrollments(tournament.id)
      assert enrollment.level == "helper"
      assert enrollment.board_from == 1
      assert enrollment.board_to == 5
    end

    test "a name typed into the mint form shows on the just-minted panel and the device list", %{
      conn: conn,
      scope: scope
    } do
      local_mode(false)
      tournament = paired_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/live")

      html =
        lv
        |> form("form[phx-submit=generate_enrollment]", %{"label" => "Anke"})
        |> render_submit()

      assert html =~ "Anke"
      assert [enrollment] = Mobile.list_enrollments(tournament.id)
      assert enrollment.label == "Anke"
    end

    test "minting with no name is still allowed, and reads as no name given rather than blank", %{
      conn: conn,
      scope: scope
    } do
      local_mode(false)
      tournament = paired_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/live")

      html =
        lv
        |> form("form[phx-submit=generate_enrollment]", %{})
        |> render_submit()

      assert html =~ "No name given"
      assert [enrollment] = Mobile.list_enrollments(tournament.id)
      assert enrollment.label == ""
    end

    test "the device list says a fresh code has not been used yet, then says when it was claimed",
         %{conn: conn, scope: scope} do
      local_mode(false)
      tournament = paired_tournament(scope)
      {:ok, enrollment} = Mobile.create_enrollment(tournament.id)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live")
      assert html =~ "Not used yet"

      assert {:ok, _claimed} = Mobile.claim(enrollment)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live")
      refute html =~ "Not used yet"
      assert html =~ "Claimed"
    end

    test "an invalid board range is refused with its own message, not the generic retry one", %{
      conn: conn,
      scope: scope
    } do
      local_mode(false)
      tournament = paired_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/live")

      html =
        lv
        |> form("form[phx-submit=generate_enrollment]", %{
          "board_from" => "10",
          "board_to" => "1"
        })
        |> render_submit()

      assert html =~ "Board range is invalid"
      assert Mobile.list_enrollments(tournament.id) == []
    end
  end

  describe "the projector cycle" do
    # A screen in a hall with more boards than fit on it. The point of the
    # cycle is that a player standing in front of it eventually sees their own
    # board, and can tell that it is coming.
    defp big_tournament(scope) do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Hall",
          "type" => "swiss",
          "rounds_count" => "3"
        })

      for n <- 1..12 do
        Repo.insert!(%Player{
          tournament_id: tournament.id,
          name: "Player #{n}",
          pairing_number: n
        })
      end

      {:ok, _} = Engine.pair_next_round(tournament)
      publish_paired_rounds(tournament)
      tournament
    end

    test "the ordinary view shows every board and no cycle furniture", %{
      conn: conn,
      scope: scope
    } do
      tournament = big_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live")

      assert html =~ "Projector view"
      refute html =~ "Page 1 of"
    end

    test "projector view pages the boards once they stop fitting", %{conn: conn, scope: scope} do
      tournament = big_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/live")

      render_click(lv, "toggle_display", %{})
      html = render_click(lv, "rows_fit", %{"rows" => 2})

      # Six boards, two to a page.
      assert html =~ "Page 1 of 3"
    end

    test "a tick moves to the next page and wraps at the end", %{conn: conn, scope: scope} do
      tournament = big_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/live")

      render_click(lv, "toggle_display", %{})
      render_click(lv, "rows_fit", %{"rows" => 2})

      # Driving the timer's own message rather than waiting 12 seconds: the
      # test is about what a tick does, not how long the gap is.
      send(lv.pid, :cycle_page)
      assert render(lv) =~ "Page 2 of 3"

      send(lv.pid, :cycle_page)
      assert render(lv) =~ "Page 3 of 3"

      send(lv.pid, :cycle_page)
      assert render(lv) =~ "Page 1 of 3", "the cycle has to come back round"
    end

    test "pausing holds the page it is on", %{conn: conn, scope: scope} do
      tournament = big_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/live")

      render_click(lv, "toggle_display", %{})
      render_click(lv, "rows_fit", %{"rows" => 2})
      send(lv.pid, :cycle_page)

      html = render_click(lv, "toggle_pause", %{})
      assert html =~ "Paused"

      # Paused means paused: a tick that arrives anyway must not move it, and
      # it must stay where the reader stopped it rather than jumping home.
      send(lv.pid, :cycle_page)
      assert render(lv) =~ "Page 2 of 3"
    end

    test "no page counter when everything fits on one screen", %{conn: conn, scope: scope} do
      tournament = big_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/live")

      render_click(lv, "toggle_display", %{})
      html = render_click(lv, "rows_fit", %{"rows" => 50})

      refute html =~ "Page 1 of"
    end

    test "high contrast is on by default and can be turned off", %{conn: conn, scope: scope} do
      tournament = big_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/live")

      html = render_click(lv, "toggle_display", %{})
      assert html =~ ~s(data-theme="contrast"), "a projector should not inherit a desk theme"

      html = render_click(lv, "toggle_contrast", %{})
      refute html =~ ~s(data-theme="contrast")
    end

    test "?display=1 opens straight into it, for a screen nobody will touch", %{
      conn: conn,
      scope: scope
    } do
      tournament = big_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live?display=1")

      assert html =~ "Leave projector view"
    end

    test "and the cycle is already running, without anybody pressing anything", %{
      conn: conn,
      scope: scope
    } do
      # The whole point of the URL: a machine drives a hall screen and nobody
      # touches it. The timer used to be started only by the button, the pause
      # toggle and its own tick, so this path showed page one for the rest of
      # the tournament.
      tournament = big_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/live?display=1")

      render_click(lv, "rows_fit", %{"rows" => 2})
      assert render(lv) =~ "Page 1 of 3"

      send(lv.pid, :cycle_page)
      assert render(lv) =~ "Page 2 of 3"
    end
  end

  describe "a round is live, or it is not" do
    # Projecting a round in the hall IS publishing it - the people it would be
    # withheld from are the ones standing in front of the screen. So this page
    # tracks the same flag the public site does, rather than the latest paired
    # round.
    defp two_round_tournament(scope, publish_mode) do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Publishing",
          "type" => "swiss",
          "rounds_count" => "3"
        })

      for n <- 1..4 do
        Repo.insert!(%Player{
          tournament_id: tournament.id,
          name: "Player #{n}",
          pairing_number: n
        })
      end

      {:ok, _} = Engine.pair_next_round(tournament)

      tournament = Repo.get!(Tournaments.Tournament, tournament.id)
      {:ok, tournament} = Tournaments.update_tournament(tournament, %{publish_mode: publish_mode})
      tournament
    end

    test "immediate mode shows the paired round, as it always did", %{conn: conn, scope: scope} do
      tournament = two_round_tournament(scope, "immediate")

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live")

      assert html =~ "Round 1"
      refute html =~ "paired but not published"
    end

    test "manual mode holds the round back until it is published", %{conn: conn, scope: scope} do
      tournament = two_round_tournament(scope, "manual")

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live")

      # Not a blank screen and not a silent round-behind: it says why.
      assert html =~ "Round 1 is paired but not published"
      assert html =~ "Go to pairings"
    end

    test "and shows it once it is published", %{conn: conn, scope: scope} do
      tournament = two_round_tournament(scope, "manual")
      round = Tournaments.get_round(tournament.id, 1)
      {:ok, _} = Tournaments.publish_round_now(round)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/live")

      refute html =~ "paired but not published"
      assert html =~ "Round 1"
    end
  end
end
