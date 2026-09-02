defmodule PairingsEngineWeb.PairingsLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Audit, Publishing, Repo, Tournaments}
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

    # Every production call site freezes display labels immediately after a
    # round's pairings are inserted - do the same here so this fixture
    # matches reality.
    :ok = Tournaments.freeze_round_display_boards!(r1.id)
    :ok = Tournaments.freeze_round_display_boards!(r2.id)

    tournament
  end

  test "board list shows each player's score coming INTO the round, next to their rating", %{
    conn: conn,
    scope: scope
  } do
    tournament = fixture(scope)

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    # Round 1: nobody has played anything yet - both start at 0.
    html = lv |> element("button[phx-value-number='1']") |> render_click()
    assert html =~ "A (2000, 0)"
    assert html =~ "B (1800, 0)"

    # Round 2: A won round 1 (1-0), so A comes in at 1, B at 0 - the score
    # from BEFORE round 2, not round 2's own (already-entered) result.
    html = lv |> element("button[phx-value-number='2']") |> render_click()
    assert html =~ "B (1800, 0)"
    assert html =~ "A (2000, 1)"
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
  test "shows a public link on the results site while the tournament publishes", %{
    conn: conn,
    scope: scope
  } do
    Publishing.put_endpoint("https://results.example.org")
    tournament = fixture(scope)
    {:ok, tournament} = Tournaments.set_publish_to_openresults(tournament, true)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    assert tournament.public_slug
    assert html =~ "Public page"
    assert html =~ "https://results.example.org/t/#{tournament.public_slug}"
    refute html =~ "/p/#{tournament.public_slug}"
  end

  test "hides the public link once publishing is turned off", %{
    conn: conn,
    scope: scope
  } do
    Publishing.put_endpoint("https://results.example.org")
    tournament = fixture(scope)
    {:ok, tournament} = Tournaments.set_publish_to_openresults(tournament, false)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    refute html =~ "Public page"
    refute html =~ "results.example.org"
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

    # Inserted deliberately out of board order (3, 1, 2) - the round's
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
    # players - their positions in the rendered HTML must be ascending.
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

    # Real board 1 is the fixed-table pairing; real board 2 is ordinary -
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

    :ok = Tournaments.freeze_round_display_boards!(round.id)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    assert html =~ ~s(<td class="num">1001</td>)
    refute html =~ ~s(<td class="num">2</td>)

    # The gap-closed ordinary board (labelled "1" now) must render before
    # the fixed-table one (labelled "1001") - i.e. Shiftedsam's row comes
    # before Wheelchairwendy's.
    shifted_pos = :binary.match(html, "Shiftedsam") |> elem(0)
    wheelchair_pos = :binary.match(html, "Wheelchairwendy") |> elem(0)
    assert shifted_pos < wheelchair_pos

    # The real board numbers in the database are untouched - this is a
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

    :ok = Tournaments.freeze_round_display_boards!(round.id)

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
    # NOT a Pairing row and previously never showed up anywhere in the UI -
    # the bug this display fixes.
    Repo.insert_all("byes", [
      %{tournament_id: tournament.id, player_id: absentee.id, round: 1, type: "requested-zero"}
    ])

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    assert html =~ "Absentee"
    assert html =~ "requested zero-point bye"
  end

  test "the pool panel costs one absence query for the page, not one per chip", %{
    conn: conn,
    scope: scope
  } do
    # `bye_points_for_row/2` asked the database for a player's cumulative
    # absence count once per rendered chip. It only READS that count when
    # `abs_nbfois` is set - a SWAR import capping "Pt ABSENT" by occurrence -
    # which is why the N+1 sat here unnoticed. `absent_counts/1` fetches the
    # lot once per refresh and `bye_points_for_row/3` reads the map.
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Absence N+1",
        "type" => "swiss",
        "rounds_count" => "3"
      })

    {:ok, tournament} =
      tournament
      |> Ecto.Changeset.change(abs_value: 0.5, abs_nbfois: 2, abs_jusque: nil)
      |> Repo.update()

    absentees =
      for name <- ["Abs A", "Abs B", "Abs C", "Abs D", "Abs E"] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name})
      end

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})
    :ok = Tournaments.freeze_round_display_boards!(round.id)

    Repo.insert_all(
      "byes",
      for p <- absentees do
        %{tournament_id: tournament.id, player_id: p.id, round: 1, type: "absent"}
      end
    )

    per_row =
      count_matching_queries(~r/count\(.*"byes"|FROM "byes".*count\(/i, fn ->
        {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")
        assert html =~ "Abs A"
        assert html =~ "Abs E"
      end)

    assert per_row == [],
           "the per-row absence COUNT is still being issued: #{inspect(per_row)}"
  end

  # Ecto emits `[:pairings_engine, :repo, :query]` for every query. The
  # LiveView runs in its own process, so this counts across processes and
  # narrows by the query text instead - safe because the suite runs one
  # case at a time (`max_cases: 1` in `test_helper.exs`).
  defp count_matching_queries(pattern, fun) do
    test_pid = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:pairings_engine, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if Regex.match?(pattern, metadata.query), do: send(test_pid, {ref, metadata.query})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    drain(ref, [])
  end

  defp drain(ref, acc) do
    receive do
      {^ref, query} -> drain(ref, [query | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  test "a fixed-board pairing's own board number is the fixed_board value, not the real one", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Pairings Print Test",
        "type" => "swiss",
        "rounds_count" => "1"
      })

    a = Repo.insert!(%Player{tournament_id: tournament.id, name: "A", fixed_board: 7})
    b = Repo.insert!(%Player{tournament_id: tournament.id, name: "B"})

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: ""
    })

    :ok = Tournaments.freeze_round_display_boards!(round.id)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    assert html =~ ~s(<td class="num">7</td>)
    # Real board 1 stays real board 1 in the database (never touched by
    # this presentation-only relabeling) - only the one paired board in
    # this round's fixture, so there's no ordinary board left to
    # demonstrate the gap-closing here (see PairingDisplayTest for that).
    refute html =~ ~s(<td class="num">1</td>)
  end

  test "a fixed_board set AFTER the round is already paired has no effect on that round", %{
    conn: conn,
    scope: scope
  } do
    tournament = fixture(scope)
    player_a = Repo.get_by!(Player, tournament_id: tournament.id, name: "A")

    Repo.update!(Ecto.Changeset.change(player_a, fixed_board: 7))

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    # The round was already paired before fixed_board was set - its board
    # still reads "1" (the frozen label), never "7".
    refute html =~ ~s(<td class="num">7</td>)
    assert html =~ ~s(<td class="num">1</td>)
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
    # tournament's PubSub topic - this LiveView is subscribed to its own
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
  # shells out to javafo.jar - the gate assertions above stay untagged so they
  # keep running where the (gitignored) jar isn't present, e.g. CI.
  @tag :javafo
  test "pairing with a complete setup creates the round", %{conn: conn, scope: scope} do
    tournament = complete_setup_tournament(scope)

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    render_click(lv, "pair", %{})

    # do_pair writes the round/pairings and broadcasts on the tournament's
    # topic, which this `lv` is subscribed to - drain the self-broadcast
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
              # Deliberately wrong on purpose - round-robin corrects this to
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

  ## ---------- concurrent-arbiter live refresh ----------
  #
  # A visible "Round N was just updated by another arbiter" notice used
  # to fire on a remote broadcast - removed by explicit request: however
  # it was positioned, a toast popping up mid-click kept surprising
  # people. The round data itself still refreshes live underneath;
  # that's the part that actually matters, and it keeps working with no
  # popup attached to it.

  test "a broadcast that changes the viewed round refreshes it live, with no popup", %{
    conn: conn,
    scope: scope
  } do
    tournament = fixture(scope)
    {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    refute html =~ "updated by another arbiter"

    # Simulate another arbiter/tab changing round 2's result directly in the
    # DB (bypassing this LiveView entirely) and broadcasting the change -
    # exactly what `Tournaments.update_pairing_result/2` would do from a
    # different process.
    round2 = Tournaments.get_round(tournament.id, 2) |> Repo.preload(:pairings)
    pairing = hd(round2.pairings)
    Repo.update!(Ecto.Changeset.change(pairing, result: "0-1"))
    Tournaments.broadcast_tournament_change(tournament.id, :results)

    html = render(lv)
    refute html =~ "updated by another arbiter"
    # Each board row carries a stable id keyed by pairing - a remote
    # update patches rows in place rather than by position, so a
    # currently-focused result `<select>` elsewhere on the row list can't
    # get swapped out from under whoever's using it.
    assert html =~ ~s(id="pairing-row-#{pairing.id}")
  end

  # Real report: an arbiter changed an already-set result ("0-0FF" ->
  # "0-0") on one tab; a second arbiter who simply had that SAME board's
  # result <select> focused never saw the change, and it stayed stale
  # even after they clicked away - confirmed by hand against a running
  # server. Root cause: once a <select> has been focused, Phoenix
  # LiveView's client won't overwrite its `value`/`selected` state from a
  # server-pushed diff (protecting in-progress typing elsewhere), and
  # that pin doesn't self-clear on blur. Fix: the true result is ALSO
  # mirrored into a plain `data-result` attribute, which patches
  # normally regardless of focus (unprotected, unlike `value`/`selected`)
  # - the `.BlindResultEntry` hook's `updated()` callback then resyncs
  # `value` from it. This test locks down the SERVER half: `data-result`
  # always carries the pairing's real, current result. The CLIENT half
  # (the JS resync itself) was verified by hand in two real browser tabs
  # - not mechanically testable here, since ExUnit never runs the hook's
  # JS or touches a real focused DOM element.
  test "each result select mirrors the pairing's real result into a plain data-result attribute",
       %{conn: conn, scope: scope} do
    tournament = fixture(scope)
    {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    round2 = Tournaments.get_round(tournament.id, 2) |> Repo.preload(:pairings)
    pairing = hd(round2.pairings)

    assert html =~ ~s(data-result="#{pairing.result}")

    # Change it (same as the other arbiter's action) and confirm the
    # mirrored attribute tracks the new value too, not just the initial one.
    Repo.update!(Ecto.Changeset.change(pairing, result: "0-0"))
    Tournaments.broadcast_tournament_change(tournament.id, :results)

    html = render(lv)
    assert html =~ ~s(data-result="0-0")
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

    test "the menu position is parsed as a number, not interpolated raw", %{
      conn: conn,
      scope: scope
    } do
      # `x`/`y` went straight into `style="left: #{x}px; …"` while the ids
      # beside them were parsed. HEEx escapes the attribute, so the worst it
      # allowed was extra `;`-separated CSS declarations on the sender's own
      # socket - but a coordinate is a number and nothing else.
      %{tournament: t, a: a} = two_board_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      html =
        render_click(lv, "open_menu", %{
          "x" => "100px; position: fixed; width: 100vw",
          "y" => "not a number at all",
          "scope" => "seated",
          "player-id" => to_string(a.id)
        })

      assert html =~ "ctx-menu"
      assert html =~ "left: 100px; top: 0px"
      refute html =~ "position: fixed"
      refute html =~ "not a number"
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

    test "a cross-board swap's confirm modal shows W/B letter badges on each changed seat",
         %{conn: conn, scope: scope} do
      %{tournament: t, a: a, d: d} = two_board_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      html = arm_and_pick(lv, a.id, d.id)

      assert html =~ ~s(aria-label="White">W)
      assert html =~ ~s(aria-label="Black">B)
      # No "⇄ Board N" cross-reference chip any more - removed as
      # confusing/unwanted; the journey arrows drawn by .SwapArrows already
      # show which board a moved player came from without it.
      refute html =~ "board-seat-swap-ref"
      refute html =~ "⇄ Board"
    end

    # The journey arrows themselves are drawn client-side by the
    # `.SwapArrows` hook, so what's assertable here is the contract it
    # depends on: the hook mount point, its (LiveView-ignored) draw layer,
    # and - the part that actually broke first - a `board-seat-moving`
    # marker on the BEFORE card, which only exists because that card is
    # passed a `compare`. Without it the hook has no start points and
    # silently draws nothing.
    test "a swap's confirm modal carries the mount point and start markers the arrows hook needs",
         %{conn: conn, scope: scope} do
      %{tournament: t, a: a, d: d} = two_board_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      html = arm_and_pick(lv, a.id, d.id)

      assert html =~ ~s(id="confirm-board-diffs")
      assert html =~ "SwapArrows"
      assert html =~ ~s(id="swap-arrows-layer")

      # One departing seat per board - the two travellers' start points.
      assert html |> String.split("board-seat-moving") |> length() == 3
    end

    defp swap_colors(html),
      do: Regex.scan(~r/--swap-color: (#[0-9a-f]{6})/, html) |> Enum.map(&Enum.at(&1, 1))

    test "a cross-board swap colours all FOUR players shown, not just the two who moved",
         %{conn: conn, scope: scope} do
      # two_board_fixture's A/B/C/D are all distinct - A and D trade
      # boards, B and C stay exactly where they are.
      %{tournament: t, a: a, d: d} = two_board_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      html = arm_and_pick(lv, a.id, d.id)

      colors = swap_colors(html)
      # 4 people, each shown twice (once in their board's "before" card,
      # once in whichever card they're in "after") - 8 colour tags total,
      # only 4 distinct values, and every value paired exactly twice
      # (the same person always gets the same colour on both sides).
      assert length(colors) == 8
      assert colors |> Enum.uniq() |> length() == 4
      assert colors |> Enum.frequencies() |> Map.values() |> Enum.all?(&(&1 == 2))
    end

    test "a same-board colour swap colours both players, distinctly", %{conn: conn, scope: scope} do
      %{tournament: t, a: a, b: b} = two_board_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      html = arm_and_pick(lv, a.id, b.id)

      colors = swap_colors(html)
      assert length(colors) == 4
      assert colors |> Enum.uniq() |> length() == 2
    end

    test "a non-swap confirm (mark absent) assigns no player colours at all",
         %{conn: conn, scope: scope} do
      %{tournament: t, a: a} = two_board_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      html = render_click(lv, "stage_vacate", %{"player-id" => to_string(a.id)})

      assert swap_colors(html) == []
    end

    test "a non-swap confirm still marks a departing seat, but with no counterpart to pair it to",
         %{conn: conn, scope: scope} do
      # Mark-absent empties a seat: the before card marks it moving, but
      # the after card's changed seat is blank, so the hook's name match
      # finds no pair and leaves the plain "→" layout alone. Pins the
      # negative case the arrows must never fire on.
      %{tournament: t, a: a} = two_board_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      html = render_click(lv, "stage_vacate", %{"player-id" => to_string(a.id)})

      assert html =~ "Mark absent"
      assert html =~ "board-seat-moving"
      refute html =~ "board-seat-swap-ref"
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

    # Real report: an arbiter had "pair with another player who isn't
    # playing…" staged behind its confirm dialog when someone ELSE
    # entered a totally unrelated result elsewhere in the round - and got
    # silently bounced out of it, as if they'd hit Escape themselves.
    test "an in-progress pool-pair confirm dialog survives an unrelated remote broadcast",
         %{conn: conn, scope: scope} do
      %{tournament: t, a: a, spare: spare, board1: board1} = two_board_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      render_click(lv, "stage_vacate", %{"player-id" => to_string(a.id)})
      render_click(lv, "apply_confirm", %{})

      render_click(lv, "stage_pool_pair", %{"player-id" => to_string(spare.id)})
      html = render_click(lv, "stage_pool_pair", %{"player-id" => to_string(a.id)})
      assert html =~ "Pair these two"

      # Someone else enters a result on a totally different board, in a
      # totally different process - the exact shape of a real remote
      # broadcast, bypassing this LiveView entirely.
      Repo.update!(Ecto.Changeset.change(board1, result: "1-0"))
      Tournaments.broadcast_tournament_change(t.id, :results)

      html = render(lv)
      assert html =~ "Pair these two"
    end

    test "applying a pool-pair confirm whose board number got taken by someone else in the meantime fails without corrupting data",
         %{conn: conn, scope: scope} do
      %{tournament: t, a: a, spare: spare} = two_board_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      render_click(lv, "stage_vacate", %{"player-id" => to_string(a.id)})
      render_click(lv, "apply_confirm", %{})

      render_click(lv, "stage_pool_pair", %{"player-id" => to_string(spare.id)})
      render_click(lv, "stage_pool_pair", %{"player-id" => to_string(a.id)})
      render_click(lv, "set_confirm_board", %{"board" => "9"})

      # Board 9 gets taken by something else entirely - a different
      # process, in between staging and applying - exactly the race
      # widened by no longer wiping the confirm dialog on every broadcast.
      round = Tournaments.get_round(t.id, 1)

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 9,
        white_player_id: t.id |> Tournaments.list_players() |> hd() |> Map.fetch!(:id),
        black_player_id: nil,
        result: "bye"
      })

      html = render_click(lv, "apply_confirm", %{})
      assert html =~ "Could not apply that change"

      round = Tournaments.get_round(t.id, 1)
      board9_pairings = Enum.filter(round.pairings, &(&1.board == 9))
      # Exactly the one pairing that was already there - no duplicate, and
      # A/Spare were NOT silently paired onto a colliding board.
      assert length(board9_pairings) == 1
    end

    test "swapping a seated player with someone from the pool substitutes them",
         %{conn: conn, scope: scope} do
      %{tournament: t, a: a, spare: spare} = two_board_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      html = arm_and_pick(lv, a.id, spare.id)
      assert html =~ "Substitute player"

      # The redesigned modal shows a second "not playing list" row next to
      # the board row, with the pool player (Spare) on its "before" side
      # and the seated player (A) on its "after" side - the mirror image
      # of the board row's own before/after. That's what lets
      # `.SwapArrows`' name-matching draw a real in/out arrow for each of
      # them, instead of the wrong self-referential arrow this modal used
      # to draw on the untouched seat (see TODO.md's "Substitute player"
      # entry). Both real board row and the new bench row must render, and
      # both names must appear in it.
      assert html =~ "Not playing list"

      # `Spare` now appears TWICE as a `.board-seat-name`: once in the
      # board row's "after" card (unchanged behaviour - they took the
      # seat) and once more in the new bench row's "before" card (they
      # started on the bench). Same for `A`: once in the board row's
      # "before" card (unchanged - they used to sit there), once more in
      # the bench row's "after" card (they end up on the bench). This is
      # exactly the precondition `matchTravellers/1` needs - a name once
      # on the "before" side and once on the "after" side overall - for
      # its two automatic arrows; ExUnit can't run the hook's JS itself,
      # so this asserts the markup shape rather than the drawn arrows.
      assert html |> String.split(~s(title="Spare">Spare</span>)) |> length() == 3
      assert html |> String.split(~s(title="A">A</span>)) |> length() == 3

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

  describe "hiding/deleting a fully-vacated board" do
    # Vacates both seats of board 1 (a, b) so it's fully vacant; board 2
    # (c, d) stays seated and is therefore the round's real last board.
    defp fully_vacated_fixture(scope) do
      %{tournament: t, a: a, b: b, board1: board1} = two_board_fixture(scope)

      round = Tournaments.get_round(t.id, 1)
      {:ok, _} = Tournaments.vacate_seat(round, a.id)
      round = Tournaments.get_round(t.id, 1)
      {:ok, _} = Tournaments.vacate_seat(round, b.id)

      %{tournament: t, a: a, b: b, board1: board1}
    end

    test "hiding removes the board from the main table and lists it under Hidden boards",
         %{conn: conn, scope: scope} do
      %{tournament: t, board1: board1} = fully_vacated_fixture(scope)

      {:ok, lv, html} = live(conn, ~p"/t/#{t.id}/pairings")
      assert html =~ "pairing-row-#{board1.id}"

      html = render_click(lv, "toggle_hidden", %{"pairing-id" => to_string(board1.id)})

      refute html =~ "pairing-row-#{board1.id}"
      assert html =~ "Hidden boards"
      assert html =~ "Board 1"

      round = Tournaments.get_round(t.id, 1)
      assert Enum.find(round.pairings, &(&1.id == board1.id)).hidden
    end

    test "un-hiding brings the board back to the main table", %{conn: conn, scope: scope} do
      %{tournament: t, board1: board1} = fully_vacated_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      render_click(lv, "toggle_hidden", %{"pairing-id" => to_string(board1.id)})

      html = render_click(lv, "toggle_hidden", %{"pairing-id" => to_string(board1.id)})

      assert html =~ "pairing-row-#{board1.id}"
      refute html =~ "Hidden boards"

      round = Tournaments.get_round(t.id, 1)
      refute Enum.find(round.pairings, &(&1.id == board1.id)).hidden
    end

    test "hiding logs an audit entry, and so does un-hiding", %{conn: conn, scope: scope} do
      %{tournament: t, board1: board1} = fully_vacated_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      render_click(lv, "toggle_hidden", %{"pairing-id" => to_string(board1.id)})
      render_click(lv, "toggle_hidden", %{"pairing-id" => to_string(board1.id)})

      actions = t.id |> Audit.list_for_tournament() |> Enum.map(& &1.action)
      assert "pairing.hidden" in actions
      assert "pairing.unhidden" in actions
    end

    test "deleting a non-last board is refused even from a direct event (server-side, not just a hidden button)",
         %{conn: conn, scope: scope} do
      %{tournament: t, board1: board1} = fully_vacated_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      render_click(lv, "stage_delete_pairing", %{"pairing-id" => to_string(board1.id)})
      html = render_click(lv, "apply_confirm", %{})

      assert html =~ "Could not apply that change"
      assert Repo.get(Pairing, board1.id)
    end

    test "deleting the round's actual last board removes it and is reflected in the round",
         %{conn: conn, scope: scope} do
      %{tournament: t, a: a, b: b} = two_board_fixture(scope)

      round = Tournaments.get_round(t.id, 1)
      board2 = Enum.find(round.pairings, &(&1.board == 2))
      {:ok, _} = Tournaments.vacate_seat(round, board2.white_player_id)
      round = Tournaments.get_round(t.id, 1)
      {:ok, _} = Tournaments.vacate_seat(round, board2.black_player_id)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      html = render_click(lv, "stage_delete_pairing", %{"pairing-id" => to_string(board2.id)})
      assert html =~ "Delete this board"

      html = render_click(lv, "apply_confirm", %{})
      refute html =~ "pairing-row-#{board2.id}"

      round = Tournaments.get_round(t.id, 1)
      refute Enum.find(round.pairings, &(&1.id == board2.id))
      assert Enum.map(round.pairings, & &1.board) == [1]

      # Untouched: board 1 (still seated, a vs b) is unaffected.
      assert Enum.find(round.pairings, &(&1.board == 1)).white_player_id == a.id
      assert Enum.find(round.pairings, &(&1.board == 1)).black_player_id == b.id
    end

    test "deleting the last board logs an audit entry", %{conn: conn, scope: scope} do
      %{tournament: t} = two_board_fixture(scope)

      round = Tournaments.get_round(t.id, 1)
      board2 = Enum.find(round.pairings, &(&1.board == 2))
      {:ok, _} = Tournaments.vacate_seat(round, board2.white_player_id)
      round = Tournaments.get_round(t.id, 1)
      {:ok, _} = Tournaments.vacate_seat(round, board2.black_player_id)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      render_click(lv, "stage_delete_pairing", %{"pairing-id" => to_string(board2.id)})
      render_click(lv, "apply_confirm", %{})

      actions = t.id |> Audit.list_for_tournament() |> Enum.map(& &1.action)
      assert "pairing.deleted" in actions
    end
  end

  describe "frozen-round confirmation (editing a round that isn't the latest paired one)" do
    # Same two-board round 1 as `two_board_fixture/1`, plus a paired round
    # 2 - so round 1 is no longer the tournament's latest.
    defp two_rounds_fixture(scope) do
      %{tournament: t} = fixture = two_board_fixture(scope)

      [e, f] =
        for name <- ~w(E F) do
          Repo.insert!(%Player{tournament_id: t.id, name: name})
        end

      round2 = Repo.insert!(%Round{tournament_id: t.id, number: 2, status: "playing"})

      Repo.insert!(%Pairing{
        round_id: round2.id,
        board: 1,
        white_player_id: e.id,
        black_player_id: f.id,
        result: ""
      })

      Map.merge(fixture, %{e: e, f: f})
    end

    test "the LATEST round's own confirm modal is never frozen", %{conn: conn, scope: scope} do
      %{tournament: t, e: e, f: f} = two_rounds_fixture(scope)

      # Default mount lands on the latest paired round (2), where E/F are -
      # a colour swap between them (their only board) needs no round switch.
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      html = arm_and_pick(lv, e.id, f.id)
      assert html =~ "Swap colours"
      refute html =~ "not the current round"
      refute html =~ "disabled"
    end

    test "swapping on a past (non-latest) round shows the frozen warning with a disabled primary button",
         %{conn: conn, scope: scope} do
      %{tournament: t, a: a, d: d} = two_rounds_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      render_click(lv, "select_round", %{"number" => "1"})

      html = arm_and_pick(lv, a.id, d.id)
      assert html =~ "not the current round"
      assert html =~ "round 2"
      assert html =~ "disabled"

      # Refused server-side too, not just a disabled button client-side.
      render_click(lv, "apply_confirm", %{})
      round = Tournaments.get_round(t.id, 1)
      assert Enum.find(round.pairings, &(&1.board == 1)).white_player_id == a.id
    end

    test "ticking the acknowledgement checkbox enables the button and lets the change through",
         %{conn: conn, scope: scope} do
      %{tournament: t, a: a, d: d} = two_rounds_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      render_click(lv, "select_round", %{"number" => "1"})
      arm_and_pick(lv, a.id, d.id)

      render_click(lv, "toggle_frozen_ack", %{})
      render_click(lv, "apply_confirm", %{})

      round = Tournaments.get_round(t.id, 1)
      board1 = Enum.find(round.pairings, &(&1.board == 1))
      assert board1.white_player_id == d.id
    end

    test "marking a player absent on a past round is frozen too, not just swaps",
         %{conn: conn, scope: scope} do
      %{tournament: t, a: a} = two_rounds_fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      render_click(lv, "select_round", %{"number" => "1"})

      html = render_click(lv, "stage_vacate", %{"player-id" => to_string(a.id)})
      assert html =~ "not the current round"
    end
  end

  describe "publish now / unpublish (publish-delay feature)" do
    test "immediate mode shows neither the badge nor any publish buttons", %{
      conn: conn,
      scope: scope
    } do
      # Immediate is no longer the default, so a test about immediate has to
      # ask for it. The default is manual, which shows exactly the publish
      # controls this asserts are absent.
      tournament = fixture(scope)
      {:ok, tournament} = Tournaments.update_tournament(tournament, %{publish_mode: "immediate"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

      # Lowercase "public" only ever comes from the badge text below - the
      # unrelated "Public pairings link" button is capitalized.
      refute html =~ "public"
      refute html =~ "Publish now"
      refute html =~ "Unpublish"
    end

    test "manual mode shows 'not public yet' and a Publish now button for an unpublished round",
         %{conn: conn, scope: scope} do
      tournament = fixture(scope)
      {:ok, _} = Tournaments.update_tournament(tournament, %{"publish_mode" => "manual"})
      Repo.update_all(Round, set: [published_at: nil])

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

      assert html =~ "not public yet"
      assert html =~ "Publish now"
      refute html =~ "Unpublish"
    end

    test "manual mode shows 'public' and an Unpublish button once the round is published", %{
      conn: conn,
      scope: scope
    } do
      tournament = fixture(scope)
      {:ok, _} = Tournaments.update_tournament(tournament, %{"publish_mode" => "manual"})

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      Repo.update_all(Round, set: [published_at: now])

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

      assert html =~ "public"
      refute html =~ "not public yet"
      assert html =~ "Unpublish"
      refute html =~ "Publish now"
    end

    test "clicking Publish now sets published_at and flips the button to Unpublish", %{
      conn: conn,
      scope: scope
    } do
      tournament = fixture(scope)
      {:ok, _} = Tournaments.update_tournament(tournament, %{"publish_mode" => "manual"})
      Repo.update_all(Round, set: [published_at: nil])

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

      html = lv |> element("button", "Publish now") |> render_click()

      assert html =~ "Unpublish"
      refute html =~ "Publish now"

      round = Tournaments.get_round(tournament.id, 2)
      assert round.published_at
    end

    test "clicking Unpublish clears published_at and flips the button back to Publish now", %{
      conn: conn,
      scope: scope
    } do
      tournament = fixture(scope)
      {:ok, _} = Tournaments.update_tournament(tournament, %{"publish_mode" => "manual"})

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      Repo.update_all(Round, set: [published_at: now])

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

      html = lv |> element("button", "Unpublish") |> render_click()

      assert html =~ "Publish now"
      refute html =~ "Unpublish"

      round = Tournaments.get_round(tournament.id, 2)
      refute round.published_at
    end
  end

  describe "snapshots are captured before the irreversible actions" do
    test "unpairing a round snapshots the state it is about to destroy", %{
      conn: conn,
      scope: scope
    } do
      tournament = fixture(scope)
      assert PairingsEngine.Snapshots.count(tournament.id) == 0

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")
      render_click(lv, "unpair", %{})

      assert [snapshot] = PairingsEngine.Snapshots.list(tournament.id)
      assert snapshot.trigger == "pairing.round_deleted"
      assert snapshot.summary =~ "Before unpairing round"
      assert snapshot.user_id == scope.user.id

      # The point of the snapshot: it still holds the round that unpairing
      # just deleted, even though the live tournament no longer does.
      stored = PairingsEngine.Snapshots.get(tournament.id, snapshot.id)
      snapshot_rounds = stored.payload["tournaments"] |> hd() |> Map.get("rounds")

      assert length(snapshot_rounds) == 2
      assert PairingsEngine.Pairing.paired_rounds_count(tournament.id) == 1
    end

    test "a failed action still leaves its snapshot behind, and that's fine", %{
      conn: conn,
      scope: scope
    } do
      tournament = fixture(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

      # Round 1 isn't the latest, so unpairing it is refused...
      render_click(lv, "select_round", %{"number" => "1"})
      render_click(lv, "unpair", %{})

      # ...but the snapshot was taken first, by design: capture must never
      # depend on the action succeeding, or it would be useless exactly when
      # something went wrong.
      assert [snapshot] = PairingsEngine.Snapshots.list(tournament.id)
      assert snapshot.trigger == "pairing.round_deleted"
      assert PairingsEngine.Pairing.paired_rounds_count(tournament.id) == 2
    end
  end
end
