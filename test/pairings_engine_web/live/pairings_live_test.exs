defmodule PairingsEngineWeb.PairingsLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Audit, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Round, Pairing}

  setup :register_and_log_in_user

  defp fixture(scope) do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Pairings Print Test",
        "type" => "swiss",
        "rounds_count" => "3"
      })

    [a, b] =
      for {name, rating} <- [{"A", 2000}, {"B", 1800}] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name, fide_rating: rating})
      end

    r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})
    r2 = Repo.insert!(%Round{tournament_id: tournament.id, number: 2, status: "finished"})

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: "1-0"
    })

    Repo.insert!(%Pairing{
      round_id: r2.id,
      board: 1,
      white_player_id: b.id,
      black_player_id: a.id,
      result: "1-0"
    })

    tournament
  end

  test "print pairings/standings links open the currently selected round in a new tab", %{
    conn: conn,
    scope: scope
  } do
    tournament = fixture(scope)

    {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    # Two rounds are paired, so the view defaults to the latest one (round 2).
    assert html =~ ~s(href="/t/#{tournament.id}/print/pairings?round=2")
    assert html =~ ~s(href="/t/#{tournament.id}/print/standings?round=2")
    assert html =~ ~s(target="_blank")

    html = lv |> element("button[phx-value-number='1']") |> render_click()

    assert html =~ ~s(href="/t/#{tournament.id}/print/pairings?round=1")
    assert html =~ ~s(href="/t/#{tournament.id}/print/standings?round=1")
  end

  test "no print links are shown for an unpaired round", %{conn: conn, scope: scope} do
    tournament = fixture(scope)

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    html = lv |> element("button[phx-value-number='3']") |> render_click()

    refute html =~ ~s(print/pairings?round=3)
    refute html =~ ~s(print/standings?round=3)
  end

  # Was removed in the July 2026 "pairings declutter" and is back by
  # request: the public standings page had a one-click share link and the
  # public pairings page did not, so the only way to hand someone the
  # pairings URL was through Settings.
  test "shows a public pairings link while public pages are enabled", %{
    conn: conn,
    scope: scope
  } do
    tournament = fixture(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    assert tournament.public_slug
    assert html =~ "Public pairings link"
    assert html =~ ~s(href="/p/#{tournament.public_slug}/pairings")
  end

  test "hides the public pairings link once public pages are turned off", %{
    conn: conn,
    scope: scope
  } do
    tournament = fixture(scope)
    {:ok, tournament} = Tournaments.set_public_pages(tournament, false)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    refute html =~ "Public pairings link"
    refute html =~ ~s(href="/p/#{tournament.public_slug}/pairings")
  end

  test "does not show a separate 'Explain this round' link (relocated to the audit page)", %{
    conn: conn,
    scope: scope
  } do
    tournament = fixture(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    refute html =~ "Explain this round"
  end

  test "print pairings/results buttons stay single, with the extra variants tucked into a hidden right-click menu",
       %{conn: conn, scope: scope} do
    tournament = fixture(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    # Round 2 is selected by default (see the earlier print-links test).
    refute html =~ "Print pairings (with absentees)"
    refute html =~ "Test print (3)"
    refute html =~ "Print result cards (stack-cut order)"

    assert html =~ "Print pairings"
    assert html =~ "Print result cards"
    assert html =~ ~s(href="/t/#{tournament.id}/print/pairings?round=2&amp;absentees=1")
    assert html =~ "With absentees section"
    assert html =~ ~s(href="/t/#{tournament.id}/print/results?round=2&amp;limit=3")
    assert html =~ "Test print (first 3 cards)"
    assert html =~ ~s(href="/t/#{tournament.id}/print/results?round=2&amp;order=stack")
    assert html =~ "Stack-cut order"
  end

  test "shows a PGN export link for the currently selected round", %{conn: conn, scope: scope} do
    tournament = fixture(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    assert html =~ ~s(href="/t/#{tournament.id}/export/pgn?round=2")
    assert html =~ "Export PGN"
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

    # Inserted deliberately out of board order (3, 1, 2) — the round's
    # `pairings` association preloads in whatever order the DB returns
    # them, not board order, so this reproduces the bug: without a sort at
    # render time the table would read "Board 3, Board 1, Board 2".
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

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    # Distinct, unlikely-to-collide-elsewhere names for boards 1/2/3's white
    # players — their positions in the rendered HTML must be ascending.
    positions =
      for name <- ["Boardonealice", "Boardtwocarol", "Boardthreeeve"],
          do: :binary.match(html, name) |> elem(0)

    assert positions == Enum.sort(positions), "expected boards 1, 2, 3 top to bottom"
  end

  test "a fixed-board pairing moves to the bottom and ordinary boards close the gap it leaves", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Fixed Board Reorder Test",
        "type" => "swiss",
        "rounds_count" => "1"
      })

    [wheelchair, wopp, shifted, sopp] =
      for name <- ["Wheelchairwendy", "Wheelchairopp", "Shiftedsam", "Shiftedopp"] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name})
      end

    Repo.update!(Ecto.Changeset.change(wheelchair, fixed_board: 1001))

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

    # Real board 1 is the fixed-table pairing; real board 2 is ordinary —
    # once board 1 becomes the special row at the bottom, board 2 should
    # take over displayed board 1 (the gap-closing case), not stay "2".
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

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    assert html =~ ~s(<td class="num">1001</td>)
    refute html =~ ~s(<td class="num">2</td>)

    # The gap-closed ordinary board (labelled "1" now) must render before
    # the fixed-table one (labelled "1001") — i.e. Shiftedsam's row comes
    # before Wheelchairwendy's.
    shifted_pos = :binary.match(html, "Shiftedsam") |> elem(0)
    wheelchair_pos = :binary.match(html, "Wheelchairwendy") |> elem(0)
    assert shifted_pos < wheelchair_pos

    # The real board numbers in the database are untouched — this is a
    # display-only relabeling.
    pairings = Repo.preload(round, :pairings).pairings
    assert Enum.find(pairings, &(&1.white_player_id == wheelchair.id)).board == 1
    assert Enum.find(pairings, &(&1.white_player_id == shifted.id)).board == 2
  end

  test "two fixed-board players paired against each other with different values show both, slash-joined",
       %{conn: conn, scope: scope} do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Fixed Board Duo Test",
        "type" => "swiss",
        "rounds_count" => "1"
      })

    [alice, bob] =
      for name <- ["Duoalice", "Duobob"] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name})
      end

    Repo.update!(Ecto.Changeset.change(alice, fixed_board: 1002))
    Repo.update!(Ecto.Changeset.change(bob, fixed_board: 1001))

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 1,
      white_player_id: alice.id,
      black_player_id: bob.id,
      result: ""
    })

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    assert html =~ ~s(<td class="num">1001/1002</td>)
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

    # A byes-table row (SWAR-imported or round-specific absentee bye) is
    # NOT a Pairing row and previously never showed up anywhere in the UI —
    # the bug this display fixes.
    Repo.insert_all("byes", [
      %{tournament_id: tournament.id, player_id: absentee.id, round: 1, type: "requested-zero"}
    ])

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    assert html =~ "Absentee"
    assert html =~ "requested zero-point bye"
  end

  test "a fixed-board pairing's own board number is the fixed_board value, not the real one", %{
    conn: conn,
    scope: scope
  } do
    tournament = fixture(scope)
    player_a = Repo.get_by!(Player, tournament_id: tournament.id, name: "A")
    Repo.update!(Ecto.Changeset.change(player_a, fixed_board: 7))

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    assert html =~ ~s(<td class="num">7</td>)
    # Real board 1 stays real board 1 in the database (never touched by
    # this presentation-only relabeling) — only the one paired board in
    # this round's fixture, so there's no ordinary board left to
    # demonstrate the gap-closing here (see PairingDisplayTest for that).
    refute html =~ ~s(<td class="num">1</td>)
  end

  ## ---------- CSV results import ----------

  defp import_fixture(scope) do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Import Test",
        "type" => "swiss",
        "rounds_count" => "2"
      })

    [a, b, c, d] =
      for name <- ["A", "B", "C", "D"] do
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

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 2,
      white_player_id: c.id,
      black_player_id: d.id,
      result: ""
    })

    tournament
  end

  test "the import panel is hidden until the toggle button is clicked", %{
    conn: conn,
    scope: scope
  } do
    tournament = import_fixture(scope)

    {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")
    refute html =~ "results-csv-import-form"

    html = lv |> element("button", "Import results (CSV)") |> render_click()
    assert html =~ "results-csv-import-form"
  end

  test "importing a valid CSV writes results and shows a success flash", %{
    conn: conn,
    scope: scope
  } do
    tournament = import_fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    lv |> element("button", "Import results (CSV)") |> render_click()

    csv =
      file_input(lv, "#results-csv-import-form", :results_csv, [
        %{name: "results.csv", content: "1,1-0\n2,0-1\n", type: "text/csv"}
      ])

    render_upload(csv, "results.csv")
    html = lv |> form("#results-csv-import-form", %{}) |> render_submit()

    assert html =~ "Imported 2 results."

    round = Tournaments.get_round(tournament.id, 1)
    assert Enum.find(round.pairings, &(&1.board == 1)).result == "1-0"
    assert Enum.find(round.pairings, &(&1.board == 2)).result == "0-1"

    # A successful import writes results, which broadcasts on the
    # tournament's PubSub topic — this LiveView is subscribed to its own
    # topic, so drain that message before the test process exits.
    render(lv)
  end

  test "an invalid CSV shows per-line errors and writes nothing (all-or-nothing)", %{
    conn: conn,
    scope: scope
  } do
    tournament = import_fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    lv |> element("button", "Import results (CSV)") |> render_click()

    csv =
      file_input(lv, "#results-csv-import-form", :results_csv, [
        %{name: "results.csv", content: "1,1-0\n99,0-1\n", type: "text/csv"}
      ])

    render_upload(csv, "results.csv")
    html = lv |> form("#results-csv-import-form", %{}) |> render_submit()

    assert html =~ "Nothing was saved"
    assert html =~ "board 99"

    round = Tournaments.get_round(tournament.id, 1)
    assert Enum.find(round.pairings, &(&1.board == 1)).result == ""
  end

  ## ---------- Setup-completion gate ----------

  test "pairing is blocked, with a banner, when the tournament is missing a start date", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "No Start Date", "type" => "swiss"})

    Repo.insert!(%Player{tournament_id: tournament.id, name: "A"})
    Repo.insert!(%Player{tournament_id: tournament.id, name: "B"})

    {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    assert html =~ "Finish the tournament setup"
    assert html =~ ~s(href="/t/#{tournament.id}/settings")

    button = lv |> element("button", "Pair round")
    assert render(button) =~ "disabled"

    html = render_click(lv, "pair", %{})
    assert html =~ "Finish the tournament setup"
    refute Tournaments.get_round(tournament.id, 1)
  end

  test "pairing is allowed once the tournament setup is complete", %{conn: conn, scope: scope} do
    tournament = complete_setup_tournament(scope)

    {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    refute html =~ "Finish the tournament setup"

    button = lv |> element("button", "Pair round")
    refute render(button) =~ "disabled"
  end

  # Only this half of the setup-gate coverage actually runs the pairing, which
  # shells out to javafo.jar — the gate assertions above stay untagged so they
  # keep running where the (gitignored) jar isn't present, e.g. CI.
  @tag :javafo
  test "pairing with a complete setup creates the round", %{conn: conn, scope: scope} do
    tournament = complete_setup_tournament(scope)

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    render_click(lv, "pair", %{})

    # do_pair writes the round/pairings and broadcasts on the tournament's
    # topic, which this `lv` is subscribed to — drain the self-broadcast
    # before teardown (same race as the CSV import test above).
    render(lv)

    assert Tournaments.get_round(tournament.id, 1)
  end

  describe "round-robin pairs its whole schedule in one action" do
    defp round_robin_setup_tournament(scope, attrs \\ %{}) do
      {:ok, tournament} =
        Tournaments.create_tournament(
          scope,
          Map.merge(
            %{
              "name" => "RR Whole Schedule",
              "type" => "roundrobin",
              "pairing_system" => "round_robin",
              "start_date" => "2026-07-15",
              # Deliberately wrong on purpose — round-robin corrects this to
              # the real Berger total, it isn't a free choice the way it is
              # for Swiss. This is the exact "I get too many rounds" case.
              "rounds_count" => "9",
              "round_dates" => List.duplicate("2026-07-15", 9),
              "chief_arbiter" => "Jane Arbiter",
              "federation" => "BEL",
              "rate_of_play" => "90 min + 30 sec/move"
            },
            attrs
          )
        )

      for name <- ["Alice", "Bob", "Carol", "Dave"] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name})
      end

      tournament
    end

    test "the button reads 'Pair the whole tournament' and asks for confirmation", %{
      conn: conn,
      scope: scope
    } do
      tournament = round_robin_setup_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

      assert html =~ "Pair the whole tournament"
      assert html =~ "generates the whole round-robin schedule at once"
      refute html =~ "Pair round 1"
    end

    test "one click generates every round, and corrects a mismatched rounds_count", %{
      conn: conn,
      scope: scope
    } do
      # 4 players, single cycle -> RoundRobin.total_rounds(4, 1) == 3, not
      # the bogus 9 the tournament was created with.
      tournament = round_robin_setup_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

      render_click(lv, "pair", %{})
      render(lv)

      assert Tournaments.get_round(tournament.id, 1)
      assert Tournaments.get_round(tournament.id, 2)
      assert Tournaments.get_round(tournament.id, 3)
      refute Tournaments.get_round(tournament.id, 4)

      assert Repo.reload!(tournament).rounds_count == 3
      assert Tournaments.list_rounds(tournament.id) |> length() == 3
    end

    test "every generated round gets its own audit entry", %{conn: conn, scope: scope} do
      tournament = round_robin_setup_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

      render_click(lv, "pair", %{})
      render(lv)

      entries = Audit.list_for_tournament(tournament.id)
      round_paired_entries = Enum.filter(entries, &(&1.action == "pairing.round_paired"))
      assert length(round_paired_entries) == 3
    end
  end

  defp complete_setup_tournament(scope) do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Complete Setup",
        "type" => "swiss",
        "start_date" => "2026-07-15",
        "rounds_count" => "2",
        "round_dates" => ["2026-07-15", "2026-07-16"],
        "tiebreaks" => ["BH", "SB"],
        "chief_arbiter" => "Jane Arbiter",
        "federation" => "BEL",
        "rate_of_play" => "90 min + 30 sec/move"
      })

    Repo.insert!(%Player{tournament_id: tournament.id, name: "A"})
    Repo.insert!(%Player{tournament_id: tournament.id, name: "B"})

    tournament
  end

  ## ---------- concurrent-arbiter "updated by another arbiter" notice ----------

  test "a broadcast that actually changes the viewed round shows the remote-arbiter notice", %{
    conn: conn,
    scope: scope
  } do
    tournament = fixture(scope)
    {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    # Round 2 is selected by default; nothing shown yet.
    refute html =~ "updated by another arbiter"

    # Simulate another arbiter/tab changing round 2's result directly in the
    # DB (bypassing this LiveView entirely) and broadcasting the change —
    # exactly what `Tournaments.update_pairing_result/2` would do from a
    # different process.
    round2 = Tournaments.get_round(tournament.id, 2) |> Repo.preload(:pairings)
    pairing = hd(round2.pairings)
    Repo.update!(Ecto.Changeset.change(pairing, result: "0-1"))
    Tournaments.broadcast_tournament_change(tournament.id, :results)

    html = render(lv)
    assert html =~ "Round 2 was just updated by another arbiter"
    assert html =~ "Dismiss"
  end

  test "a broadcast echoing this LiveView's own action does not show the notice", %{
    conn: conn,
    scope: scope
  } do
    tournament = import_fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    round = Tournaments.get_round(tournament.id, 1) |> Repo.preload(:pairings)
    pairing = hd(round.pairings)

    # Entering a result ourselves updates the DB, refreshes `@round`
    # synchronously inside the same `handle_event`, and also broadcasts
    # `:results` right back to this same subscribed process — that self-echo
    # must not trigger the "another arbiter" notice.
    html =
      render_click(lv, "result", %{"pairing-id" => to_string(pairing.id), "result" => "1-0"})

    refute html =~ "updated by another arbiter"

    # Drain the self-broadcast before asserting again.
    html = render(lv)
    refute html =~ "updated by another arbiter"
  end

  test "the remote-arbiter notice is dismissible and clears on the next click", %{
    conn: conn,
    scope: scope
  } do
    tournament = fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    round2 = Tournaments.get_round(tournament.id, 2) |> Repo.preload(:pairings)
    pairing = hd(round2.pairings)
    Repo.update!(Ecto.Changeset.change(pairing, result: "0-1"))
    Tournaments.broadcast_tournament_change(tournament.id, :results)

    html = render(lv)
    assert html =~ "updated by another arbiter"

    html = lv |> element("button", "Dismiss") |> render_click()
    refute html =~ "updated by another arbiter"
  end

  test "the remote-arbiter notice also clears on any other click (e.g. switching rounds)", %{
    conn: conn,
    scope: scope
  } do
    tournament = fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    round2 = Tournaments.get_round(tournament.id, 2) |> Repo.preload(:pairings)
    pairing = hd(round2.pairings)
    Repo.update!(Ecto.Changeset.change(pairing, result: "0-1"))
    Tournaments.broadcast_tournament_change(tournament.id, :results)

    html = render(lv)
    assert html =~ "updated by another arbiter"

    html = lv |> element("button[phx-value-number='1']") |> render_click()
    refute html =~ "updated by another arbiter"
  end

  ## ---------- match-format round labels ----------

  test "round-picker labels are plain numbers when no match format is set", %{
    conn: conn,
    scope: scope
  } do
    tournament = fixture(scope)
    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    assert html =~ ~s(phx-value-number="1")
    assert html =~ "Round 2"
    refute html =~ "M1·"
    refute html =~ "Match "
  end

  test "round-picker labels show match/game numbers when rr_match_format is set", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "RR Match Format",
        "type" => "swiss",
        "pairing_system" => "round_robin",
        "rounds_count" => "4",
        "rr_match_format" => "true"
      })

    [a, b] =
      for name <- ["A", "B"] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name})
      end

    r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})
    r2 = Repo.insert!(%Round{tournament_id: tournament.id, number: 2, status: "finished"})

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: "1-0"
    })

    Repo.insert!(%Pairing{
      round_id: r2.id,
      board: 1,
      white_player_id: b.id,
      black_player_id: a.id,
      result: "0-1"
    })

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    assert html =~ "M1·1"
    assert html =~ "M1·2"
    assert html =~ "M2·1"
    assert html =~ "M2·2"
    assert html =~ "Match 1, game 2"
  end

  test "round-picker labels show match/game numbers when swiss_match_format is set", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Swiss Match Format",
        "type" => "swiss",
        "rounds_count" => "4",
        "swiss_match_format" => "true"
      })

    [a, b] =
      for name <- ["A", "B"] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name})
      end

    r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: "1-0"
    })

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    assert html =~ "M1·1"
    assert html =~ "M1·2"
    assert html =~ "M2·1"
    assert html =~ "M2·2"
    assert html =~ "Match 1, game 1"
  end

  describe "a blank result submission never silently overwrites an existing one" do
    test "stages a confirmation instead of clearing the result immediately", %{
      conn: conn,
      scope: scope
    } do
      tournament = fixture(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

      round1 = Tournaments.get_round(tournament.id, 1) |> Repo.preload(:pairings)
      pairing = hd(round1.pairings)
      assert pairing.result == "1-0"

      html = lv |> element("button[phx-value-number='1']") |> render_click()
      refute html =~ "Clear the recorded result"

      html =
        render_change(lv, "result", %{"pairing-id" => to_string(pairing.id), "result" => ""})

      assert html =~ "Clear the recorded result (1-0) for this board?"
      assert html =~ "Yes, clear it"

      # Never written to the DB just from the blank submission arriving.
      assert Repo.get!(Pairing, pairing.id).result == "1-0"

      [log] = Audit.list_for_tournament(tournament.id, action: "pairing.result_clear_attempted")
      assert log.details["pairing_id"] == pairing.id
      assert log.details["from"] == "1-0"
    end

    test "confirming the clear actually clears it, and logs a distinct action", %{
      conn: conn,
      scope: scope
    } do
      tournament = fixture(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

      round1 = Tournaments.get_round(tournament.id, 1) |> Repo.preload(:pairings)
      pairing = hd(round1.pairings)

      lv |> element("button[phx-value-number='1']") |> render_click()
      render_change(lv, "result", %{"pairing-id" => to_string(pairing.id), "result" => ""})

      html = render_click(lv, "confirm_clear_result", %{"pairing-id" => to_string(pairing.id)})

      refute html =~ "Clear the recorded result"
      assert Repo.get!(Pairing, pairing.id).result == ""

      [log] = Audit.list_for_tournament(tournament.id, action: "pairing.result_cleared")
      assert log.details["pairing_id"] == pairing.id
      assert log.details["from"] == "1-0"
    end

    test "cancelling leaves the result untouched", %{conn: conn, scope: scope} do
      tournament = fixture(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

      round1 = Tournaments.get_round(tournament.id, 1) |> Repo.preload(:pairings)
      pairing = hd(round1.pairings)

      lv |> element("button[phx-value-number='1']") |> render_click()
      render_change(lv, "result", %{"pairing-id" => to_string(pairing.id), "result" => ""})

      html = render_click(lv, "cancel_clear_result", %{})

      refute html =~ "Clear the recorded result"
      assert Repo.get!(Pairing, pairing.id).result == "1-0"
    end

    test "a blank submission on a board with no existing result is a harmless no-op, no confirmation needed",
         %{conn: conn, scope: scope} do
      tournament = fixture(scope)

      round1 = Tournaments.get_round(tournament.id, 1) |> Repo.preload(:pairings)
      pairing = hd(round1.pairings)
      Repo.update!(Ecto.Changeset.change(pairing, result: ""))

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

      html =
        render_change(lv, "result", %{"pairing-id" => to_string(pairing.id), "result" => ""})

      refute html =~ "Clear the recorded result"
      assert Repo.get!(Pairing, pairing.id).result == ""

      assert Audit.list_for_tournament(tournament.id, action: "pairing.result_clear_attempted") ==
               []
    end
  end

  describe "hand-editing a round" do
    defp two_board_fixture(scope) do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Swap Test",
          "type" => "swiss",
          "rounds_count" => "3"
        })

      [a, b, c, d, spare] =
        for name <- ~w(A B C D Spare) do
          Repo.insert!(%Player{tournament_id: tournament.id, name: name})
        end

      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

      board1 =
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

      %{tournament: tournament, a: a, b: b, c: c, d: d, spare: spare, board1: board1}
    end

    defp arm_and_pick(lv, first_id, second_id) do
      render_click(lv, "arm_swap", %{"player-id" => to_string(first_id)})
      render_click(lv, "pick_swap_target", %{"player-id" => to_string(second_id)})
    end

    test "right-click opens a menu rather than doing anything", %{conn: conn, scope: scope} do
      %{tournament: t, a: a} = two_board_fixture(scope)

      {:ok, lv, html} = live(conn, ~p"/t/#{t.id}/pairings")
      refute html =~ "ctx-menu"

      html =
        render_click(lv, "open_menu", %{
          "x" => 100,
          "y" => 200,
          "scope" => "seated",
          "player-id" => to_string(a.id)
        })

      assert html =~ "ctx-menu"
      assert html =~ "Swap with"
      assert html =~ "Mark absent for this round"
    end

    test "a second right-click never completes a swap, only the menu plus confirm can",
         %{conn: conn, scope: scope} do
      %{tournament: t, a: a, d: d} = two_board_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      render_click(lv, "arm_swap", %{"player-id" => to_string(a.id)})

      # Right-clicking the second player opens ITS menu; nothing is written.
      html =
        render_click(lv, "open_menu", %{
          "x" => 10,
          "y" => 10,
          "scope" => "seated",
          "player-id" => to_string(d.id)
        })

      assert html =~ "ctx-menu"

      round = Tournaments.get_round(t.id, 1)
      assert Enum.find(round.pairings, &(&1.board == 1)).white_player_id == a.id
    end

    test "arm, pick, confirm swaps the two seats", %{conn: conn, scope: scope} do
      %{tournament: t, a: a, b: b, c: c, d: d} = two_board_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      html = render_click(lv, "arm_swap", %{"player-id" => to_string(a.id)})
      assert html =~ "Swapping"

      html = render_click(lv, "pick_swap_target", %{"player-id" => to_string(d.id)})
      assert html =~ "Swap players"
      assert html =~ "board-diff"

      render_click(lv, "apply_confirm", %{})

      round = Tournaments.get_round(t.id, 1)
      board1 = Enum.find(round.pairings, &(&1.board == 1))
      board2 = Enum.find(round.pairings, &(&1.board == 2))
      assert board1.white_player_id == d.id
      assert board1.black_player_id == b.id
      assert board2.white_player_id == c.id
      assert board2.black_player_id == a.id

      assert [_] = Audit.list_for_tournament(t.id, action: "pairing.players_swapped")
    end

    test "picking a player's own opponent is titled as a colour swap", %{conn: conn, scope: scope} do
      %{tournament: t, a: a, b: b} = two_board_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      html = arm_and_pick(lv, a.id, b.id)

      assert html =~ "Swap colours"
    end

    test "cancelling the confirm writes nothing", %{conn: conn, scope: scope} do
      %{tournament: t, a: a, d: d} = two_board_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      arm_and_pick(lv, a.id, d.id)

      html = render_click(lv, "cancel_confirm", %{})
      refute html =~ "pe-modal-card"

      round = Tournaments.get_round(t.id, 1)
      assert Enum.find(round.pairings, &(&1.board == 1)).white_player_id == a.id
    end

    test "a recorded result on an affected board is flagged as about to clear",
         %{conn: conn, scope: scope} do
      %{tournament: t, a: a, d: d, board1: board1} = two_board_fixture(scope)
      {:ok, _} = Tournaments.update_pairing_result(board1, "1-0")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      html = arm_and_pick(lv, a.id, d.id)

      assert html =~ "will be cleared"
    end

    test "marking a player absent empties their seat and leaves board and opponent alone",
         %{conn: conn, scope: scope} do
      %{tournament: t, a: a, b: b} = two_board_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      html = render_click(lv, "stage_vacate", %{"player-id" => to_string(a.id)})
      assert html =~ "Mark absent"
      assert html =~ "keeps its number"

      html = render_click(lv, "apply_confirm", %{})

      round = Tournaments.get_round(t.id, 1)
      board1 = Enum.find(round.pairings, &(&1.board == 1))
      assert board1.board == 1
      assert board1.white_player_id == nil
      assert board1.black_player_id == b.id

      # The empty seat is visible, and A is now in the not-playing pool.
      assert html =~ "seat-vacant"
      assert html =~ "Not playing round 1"
    end

    test "a pool player can be dropped straight into the only empty seat",
         %{conn: conn, scope: scope} do
      %{tournament: t, a: a, spare: spare} = two_board_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      render_click(lv, "stage_vacate", %{"player-id" => to_string(a.id)})
      render_click(lv, "apply_confirm", %{})

      # One vacancy open, so this stages the fill without asking which seat.
      html = render_click(lv, "offer_seats", %{"player-id" => to_string(spare.id)})
      assert html =~ "Fill the empty seat"

      render_click(lv, "apply_confirm", %{})

      round = Tournaments.get_round(t.id, 1)
      assert Enum.find(round.pairings, &(&1.board == 1)).white_player_id == spare.id
    end

    test "a vacancy can instead be resolved as a bye for the player left behind",
         %{conn: conn, scope: scope} do
      %{tournament: t, a: a, b: b} = two_board_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      render_click(lv, "stage_vacate", %{"player-id" => to_string(a.id)})
      render_click(lv, "apply_confirm", %{})

      round = Tournaments.get_round(t.id, 1)
      vacant = Enum.find(round.pairings, &(&1.board == 1))

      html = render_click(lv, "stage_bye", %{"pairing-id" => to_string(vacant.id)})
      assert html =~ "Award a bye"

      render_click(lv, "apply_confirm", %{})

      round = Tournaments.get_round(t.id, 1)
      board1 = Enum.find(round.pairings, &(&1.board == 1))
      assert board1.white_player_id == b.id
      assert board1.black_player_id == nil
      assert board1.result == "bye"
    end

    test "two pool players can be paired onto a new board with an editable table number",
         %{conn: conn, scope: scope} do
      %{tournament: t, a: a, spare: spare} = two_board_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      # Vacate A so there are two people in the pool (A and Spare).
      render_click(lv, "stage_vacate", %{"player-id" => to_string(a.id)})
      render_click(lv, "apply_confirm", %{})

      html = render_click(lv, "stage_pool_pair", %{"player-id" => to_string(spare.id)})
      assert html =~ "Pairing"

      html = render_click(lv, "stage_pool_pair", %{"player-id" => to_string(a.id)})
      assert html =~ "Pair these two"
      assert html =~ "Table number"

      render_click(lv, "set_confirm_board", %{"board" => "9"})
      render_click(lv, "apply_confirm", %{})

      round = Tournaments.get_round(t.id, 1)
      new_board = Enum.find(round.pairings, &(&1.board == 9))
      assert new_board

      assert Enum.sort([new_board.white_player_id, new_board.black_player_id]) ==
               Enum.sort([spare.id, a.id])
    end

    test "swapping a seated player with someone from the pool substitutes them",
         %{conn: conn, scope: scope} do
      %{tournament: t, a: a, spare: spare} = two_board_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      html = arm_and_pick(lv, a.id, spare.id)
      assert html =~ "Substitute player"

      render_click(lv, "apply_confirm", %{})

      round = Tournaments.get_round(t.id, 1)
      assert Enum.find(round.pairings, &(&1.board == 1)).white_player_id == spare.id

      pool_ids = Tournaments.list_round_pool(t.id, 1) |> Enum.map(& &1.player.id)
      assert a.id in pool_ids
    end

    test "an absentee is listed in the pool and can be swapped onto a board",
         %{conn: conn, scope: scope} do
      %{tournament: t, a: a, spare: spare} = two_board_fixture(scope)
      {:ok, _} = Tournaments.update_player(spare, %{"absent" => "true"})

      {:ok, lv, html} = live(conn, ~p"/t/#{t.id}/pairings")

      # The whole point of the panel: someone who said they could not come
      # has to be visible, because turning up anyway is the commonest
      # reason to reach for a swap at all.
      assert html =~ "Spare"
      assert html =~ "absent (whole event)"

      html = arm_and_pick(lv, a.id, spare.id)
      assert html =~ "Substitute player"
      # Playing one round does not un-withdraw them, and the modal says so.
      assert html =~ "stay marked absent for the whole event"

      render_click(lv, "apply_confirm", %{})

      round = Tournaments.get_round(t.id, 1)
      assert Enum.find(round.pairings, &(&1.board == 1)).white_player_id == spare.id
    end

    test "a forfeited player is not listed in the pool", %{conn: conn, scope: scope} do
      %{tournament: t, spare: spare} = two_board_fixture(scope)
      {:ok, _} = Tournaments.update_player(spare, %{"forfeit" => "true"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings")

      refute html =~ "Spare"
    end
  end
end
