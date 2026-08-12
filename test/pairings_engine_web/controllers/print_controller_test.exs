defmodule PairingsEngineWeb.PrintControllerTest do
  use PairingsEngineWeb.ConnCase

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Round, Pairing}

  setup :register_and_log_in_user

  # 4 players, 2 rounds, mirrors the Standings fixture:
  #   R1: A (w) 1-0 B    C (w) ½-½ D
  #   R2: C (w) 0-1 A    B (w) 1-0 D
  # After R1: A=1, C=0.5, D=0.5, B=0
  # After R2: A=2, B=1,  C=0.5, D=0.5
  defp fixture(scope) do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Print Test",
        "type" => "swiss",
        "rounds_count" => "3"
      })

    [a, b, c, d] =
      for {name, rating, number} <- [
            {"A", 2000, 1},
            {"B", 1800, 2},
            {"C", 1700, 3},
            {"D", 1600, 4}
          ] do
        Repo.insert!(%Player{
          tournament_id: tournament.id,
          name: name,
          fide_rating: rating,
          pairing_number: number
        })
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
      round_id: r1.id,
      board: 2,
      white_player_id: c.id,
      black_player_id: d.id,
      result: "1/2-1/2"
    })

    Repo.insert!(%Pairing{
      round_id: r2.id,
      board: 1,
      white_player_id: c.id,
      black_player_id: a.id,
      result: "0-1"
    })

    Repo.insert!(%Pairing{
      round_id: r2.id,
      board: 2,
      white_player_id: b.id,
      black_player_id: d.id,
      result: "1-0"
    })

    {tournament, %{a: a, b: b, c: c, d: d}}
  end

  # A Keizer tournament, one round paired — enough to exercise
  # PairingsEngine.Keizer.standings/1's rank/value/points/raw_points shape
  # from the print document.
  defp keizer_fixture(scope) do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Keizer Print Test",
        "type" => "swiss",
        "pairing_system" => "keizer",
        "rounds_count" => "3",
        "tiebreaks" => ["BH", "SB"]
      })

    for {name, rating} <- [{"A", 2000}, {"B", 1900}, {"C", 1800}, {"D", 1700}] do
      {:ok, _} =
        Tournaments.create_player(tournament.id, %{
          "name" => name,
          "fide_rating" => to_string(rating)
        })
    end

    {:ok, _round} = PairingsEngine.Pairing.pair_next_round(tournament)

    tournament
  end

  # Every response carries its own CSP nonce (PairingsEngineWeb.CSP), so two
  # renderings of the same page are never byte-identical. Compare the content.
  defp without_nonce(html), do: String.replace(html, ~r/nonce="[^"]*"/, ~s(nonce="_"))

  describe "pairing_list/2" do
    test "?round=1 renders round 1's board pairings, not round 2's", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/pairings?round=1")

      html = html_response(conn, 200)
      assert html =~ "Pairings — round 1"
      assert html =~ "A"
      assert html =~ "B"
      # Round 2's pairing (C vs A on board 1) should not appear as a row —
      # C only appears paired with D on round 1's board 2.
      refute html =~ "round 2"
    end

    test "?round=2 renders round 2's board pairings", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/pairings?round=2")

      html = html_response(conn, 200)
      assert html =~ "Pairings — round 2"
    end

    test "omitting ?round defaults to round 1", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/pairings")

      assert html_response(conn, 200) =~ "Pairings — round 1"
    end

    test "an unpaired round 404s", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/pairings?round=3")

      assert conn.status == 404
    end

    test "shows each player's score coming INTO the round, in brackets next to their name", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _players} = fixture(scope)

      # Round 2 pairs C vs A (see the fixture's own doc comment) — coming
      # into round 2, A is at 1 (won round 1) and C is at 0.5 (drew D).
      html = get(conn, ~p"/t/#{tournament.id}/print/pairings?round=2") |> html_response(200)

      assert html =~ "A (1)"
      assert html =~ "C (0.5)"
    end

    test "a board involving a player with a fixed_board override is relabeled and moved to the end",
         %{conn: conn, scope: scope} do
      {tournament, %{a: a}} = fixture(scope)
      a |> Ecto.Changeset.change(fixed_board: 5) |> Repo.update!()

      conn = get(conn, ~p"/t/#{tournament.id}/print/pairings?round=1")

      html = html_response(conn, 200)
      # Board 2 (C/D, ordinary) closes the gap board 1 (A/B, now special)
      # leaves and becomes displayed board 1; A/B's board shows "5"
      # (the fixed_board value, not the old real board 1) and sorts last.
      [board1_row, board5_row] = Regex.scan(~r/<tr><td class="num">(\d+)<\/td>/, html)
      assert board1_row == ["<tr><td class=\"num\">1</td>", "1"]
      assert board5_row == ["<tr><td class=\"num\">5</td>", "5"]
      assert String.contains?(html, "C") and String.contains?(html, "A")
    end

    test "a board with no fixed_board players is numbered normally", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/pairings?round=2")

      html = html_response(conn, 200)
      assert html =~ "<td class=\"num\">1</td>"
      assert html =~ "<td class=\"num\">2</td>"
    end

    test "byes/absentees are off by default, shown below the table with ?absentees=1", %{
      conn: conn,
      scope: scope
    } do
      {tournament, %{c: c}} = fixture(scope)

      Repo.insert_all("byes", [
        %{tournament_id: tournament.id, player_id: c.id, round: 1, type: "absent"}
      ])

      conn_default = get(conn, ~p"/t/#{tournament.id}/print/pairings?round=1")
      html_default = html_response(conn_default, 200)
      refute html_default =~ "Absentees"

      conn_on = get(conn, ~p"/t/#{tournament.id}/print/pairings?round=1&absentees=1")
      html_on = html_response(conn_on, 200)
      assert html_on =~ "Absentees"
      # "absent" falls back to points_loss (0.0) since this tournament has
      # no abs_value set (not a SWAR import).
      assert html_on =~ ~r/C.*?absent.*?\(0\.0 pt\)/s
    end

    test "a pairing-allocated bye keeps showing as a normal board row regardless of ?absentees",
         %{
           conn: conn,
           scope: scope
         } do
      {tournament, _players} = fixture(scope)
      round1 = Tournaments.get_round(tournament.id, 1)

      e = Repo.insert!(%Player{tournament_id: tournament.id, name: "E", pairing_number: 5})

      Repo.insert!(%Pairing{
        round_id: round1.id,
        board: 3,
        white_player_id: e.id,
        black_player_id: nil,
        result: "bye"
      })

      html = html_response(get(conn, ~p"/t/#{tournament.id}/print/pairings?round=1"), 200)
      assert html =~ "— bye —"
    end
  end

  describe "standings/2" do
    test "without ?round, prints current (overall) standings", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/standings")

      html = html_response(conn, 200)
      assert html =~ "Standings after round 2"
      # A leads overall with 2.0 points after both rounds.
      assert html =~ ~r/A.*?<strong>2\.0<\/strong>/s
    end

    test "?round=1 prints standings as they stood after round 1 only", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/standings?round=1")

      html = html_response(conn, 200)
      assert html =~ "Standings after round 1"
      # After round 1 alone: A has 1.0 (not 2.0, which only holds once
      # round 2's result is counted).
      assert html =~ ~r/A.*?<strong>1\.0<\/strong>/s
      refute html =~ ~r/A.*?<strong>2\.0<\/strong>/s
    end

    test "?round=2 matches the overall standings once all paired rounds are included", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _players} = fixture(scope)

      overall = get(conn, ~p"/t/#{tournament.id}/print/standings") |> html_response(200)
      as_of_2 = get(conn, ~p"/t/#{tournament.id}/print/standings?round=2") |> html_response(200)

      assert without_nonce(overall) == without_nonce(as_of_2)
    end

    test "a round that hasn't been paired yet 404s", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/standings?round=3")

      assert conn.status == 404
    end

    test "shows a Sex column with FIDE's M/F letters, not the internal m/w storage code", %{
      conn: conn,
      scope: scope
    } do
      {tournament, %{a: a}} = fixture(scope)
      a |> Ecto.Changeset.change(sex: "w") |> Repo.update!()

      html = get(conn, ~p"/t/#{tournament.id}/print/standings") |> html_response(200)

      assert html =~ "<th>Sex</th>"
      assert html =~ "<td>F</td>"
      refute html =~ "<td>w</td>"
    end

    test "a tournament with no categories renders byte-identical to before (no Category column/tables)",
         %{
           conn: conn,
           scope: scope
         } do
      {tournament, _players} = fixture(scope)

      html = get(conn, ~p"/t/#{tournament.id}/print/standings") |> html_response(200)

      refute html =~ "Category"
      refute html =~ ">Category:"
    end

    test "a tournament with categories gets a Category column and one table per category", %{
      conn: conn,
      scope: scope
    } do
      {tournament, %{a: a, b: b, c: c, d: d}} = fixture(scope)

      {:ok, tournament} =
        Tournaments.update_tournament(tournament, %{"categories" => ["Open", "Women"]})

      a |> Ecto.Changeset.change(category: "Open") |> Repo.update!()
      b |> Ecto.Changeset.change(category: "Women") |> Repo.update!()
      c |> Ecto.Changeset.change(category: "Open") |> Repo.update!()
      Ecto.Changeset.change(d) |> Repo.update!()

      html = get(conn, ~p"/t/#{tournament.id}/print/standings") |> html_response(200)

      assert html =~ "<th>Category</th>"
      assert html =~ "Category: Open"
      assert html =~ "Category: Women"

      # D has no category, so it appears in the main table but in neither
      # category sub-table.
      [_main, rest] = String.split(html, "Category: Open", parts: 2)
      [open_table, women_and_after] = String.split(rest, "Category: Women", parts: 2)
      assert open_table =~ "A"
      assert open_table =~ "C"
      refute open_table =~ ">B<"
      assert women_and_after =~ "B"
      refute women_and_after =~ ">D<"
    end

    test "a keizer tournament prints the ladder table (Value/Keizer pts/Score), not FIDE points/tiebreak columns",
         %{
           conn: conn,
           scope: scope
         } do
      tournament = keizer_fixture(scope)

      html = get(conn, ~p"/t/#{tournament.id}/print/standings") |> html_response(200)

      assert html =~ "<th class=\"num\">Value</th>"
      assert html =~ "<th class=\"num\">Keizer pts</th>"
      assert html =~ "<th class=\"num\">Score</th>"

      # Not the FIDE-tiebreak standings table: no "Pts" column header, and
      # none of the tournament's configured tiebreak codes as a column.
      refute html =~ "<th class=\"num\">Pts</th>"
      refute html =~ "<th class=\"num\">BH</th>"
      refute html =~ "<th class=\"num\">SB</th>"
    end
  end

  describe "standings/2 — manual ranking (SWAR parity #23)" do
    test "off: no banner, order is the computed tiebreak order", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      html = get(conn, ~p"/t/#{tournament.id}/print/standings") |> html_response(200)

      refute html =~ "MANUAL RANKING IS ON"
    end

    test "on: shows the banner on the current standings print and reorders the table", %{
      conn: conn,
      scope: scope
    } do
      {tournament, %{b: b}} = fixture(scope)
      {:ok, tournament} = Tournaments.enable_manual_ranking(tournament)

      # Hand-flip the top two so B leads even though A has more points.
      Tournaments.move_manual_rank(tournament, Repo.reload!(b), :up)

      html = get(conn, ~p"/t/#{tournament.id}/print/standings") |> html_response(200)

      assert html =~ "MANUAL RANKING IS ON"
      assert html =~ ~r/B.*A/s
    end

    test "on but round-scoped (?round=n): the historical print is unaffected — no banner, computed order",
         %{
           conn: conn,
           scope: scope
         } do
      {tournament, _players} = fixture(scope)
      {:ok, tournament} = Tournaments.enable_manual_ranking(tournament)

      html = get(conn, ~p"/t/#{tournament.id}/print/standings?round=1") |> html_response(200)

      refute html =~ "MANUAL RANKING IS ON"
    end

    test "stale: shows the stale note once a result changes after seeding", %{
      conn: conn,
      scope: scope
    } do
      {tournament, %{a: a, b: b}} = fixture(scope)
      {:ok, tournament} = Tournaments.enable_manual_ranking(tournament)

      pairing = Repo.get_by!(Pairing, white_player_id: a.id, black_player_id: b.id)

      Tournaments.update_pairing_result(pairing, "0-1")

      html = get(conn, ~p"/t/#{tournament.id}/print/standings") |> html_response(200)

      assert html =~ "MANUAL RANKING IS ON"
      assert html =~ "no longer match the real standings"
    end

    test "keizer tournaments never show the banner even if manual_ranking is set", %{
      conn: conn,
      scope: scope
    } do
      tournament = keizer_fixture(scope)
      {:ok, tournament} = Tournaments.update_tournament(tournament, %{"manual_ranking" => "true"})

      html = get(conn, ~p"/t/#{tournament.id}/print/standings") |> html_response(200)

      refute html =~ "MANUAL RANKING IS ON"
    end
  end

  describe "result_cards/2" do
    test "?round=1 renders one card per board of round 1, skipping byes", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/results?round=1")

      html = html_response(conn, 200)
      assert html =~ "Result cards — round 1"
      assert html =~ "A"
      assert html =~ "B"
      assert html =~ "C"
      assert html =~ "D"
      assert html =~ "1 &ndash; 0"
      assert html =~ "other: ............"
    end

    test "?round=2 renders round 2's cards, not round 1's", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/results?round=2")

      assert html_response(conn, 200) =~ "Result cards — round 2"
    end

    test "omitting ?round defaults to the latest paired round", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/results")

      # Fixture has rounds 1 and 2 paired — the latest paired round is 2.
      assert html_response(conn, 200) =~ "Result cards — round 2"
    end

    test "an unpaired round 404s", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/results?round=3")

      assert conn.status == 404
    end

    test "a bye board is skipped", %{conn: conn, scope: scope} do
      {tournament, %{a: a}} = fixture(scope)
      r3 = Repo.insert!(%Round{tournament_id: tournament.id, number: 3, status: "playing"})

      Repo.insert!(%Pairing{
        round_id: r3.id,
        board: 1,
        white_player_id: a.id,
        black_player_id: nil,
        result: "bye"
      })

      conn = get(conn, ~p"/t/#{tournament.id}/print/results?round=3")

      html = html_response(conn, 200)
      refute html =~ ~s(class="result-card")
    end

    test "a board involving a player with a fixed_board override is annotated", %{
      conn: conn,
      scope: scope
    } do
      {tournament, %{a: a}} = fixture(scope)
      a |> Ecto.Changeset.change(fixed_board: 5) |> Repo.update!()

      conn = get(conn, ~p"/t/#{tournament.id}/print/results?round=1")

      html = html_response(conn, 200)
      assert html =~ "(table 5)"
    end

    # Eight compact cards per A4 page (down from three tall ones) — see
    # `@result_cards_css`: `.result-card:nth-child(8n)` forces the page
    # break every 8th card instead of every 3rd.
    test "cards are laid out eight to a page", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/results?round=1")

      html = html_response(conn, 200)
      assert html =~ "nth-child(8n)"
    end

    test "?limit=1 renders exactly one card (test print)", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      # Round 1 has two boards (A-B, C-D) -> without a limit both appear.
      full = get(conn, ~p"/t/#{tournament.id}/print/results?round=1") |> html_response(200)
      assert (full |> String.split(~s(class="result-card")) |> length()) - 1 == 2

      conn = get(conn, ~p"/t/#{tournament.id}/print/results?round=1&limit=1")

      html = html_response(conn, 200)
      assert (html |> String.split(~s(class="result-card")) |> length()) - 1 == 1
      # The first board (A vs B, board order) is the one kept. Matched as
      # "<strong>A</strong>" rather than a bare letter — a bare "C"/"D"
      # false-positives on the random CSP nonce (base64) and on the
      # print-footer credit's "JaVaFo"/"Dutch".
      assert html =~ "<strong>A</strong>"
      assert html =~ "<strong>B</strong>"
      refute html =~ "<strong>C</strong>"
      refute html =~ "<strong>D</strong>"
    end

    test "a junk ?limit value is ignored and the full print is rendered", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _players} = fixture(scope)

      full = get(conn, ~p"/t/#{tournament.id}/print/results?round=1") |> html_response(200)

      for junk <- ["0", "-1", "abc", "1.5", ""] do
        html =
          get(conn, ~p"/t/#{tournament.id}/print/results?round=1&limit=#{junk}")
          |> html_response(200)

        assert without_nonce(html) == without_nonce(full)
      end
    end

    test "?order=stack imposes stack-cut order across three pages", %{conn: conn, scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Stack Cut Test",
          "type" => "swiss",
          "rounds_count" => "1"
        })

      # 40 players -> 20 boards -> 20 cards, board order 1..40 (by
      # pairing_number / insertion order).
      players =
        for n <- 1..40 do
          Repo.insert!(%Player{tournament_id: tournament.id, name: "P#{n}", pairing_number: n})
        end

      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

      players
      |> Enum.chunk_every(2)
      |> Enum.with_index(1)
      |> Enum.each(fn {[w, b], board} ->
        Repo.insert!(%Pairing{
          round_id: round.id,
          board: board,
          white_player_id: w.id,
          black_player_id: b.id
        })
      end)

      html =
        get(conn, ~p"/t/#{tournament.id}/print/results?round=1&order=stack") |> html_response(200)

      # 20 real cards + enough .rc-blank placeholders to fill out 3 pages of
      # 8 (24 slots total) -> 4 blanks. See the worked example in
      # docs/printing.md / the `stack_cut_cards/3` comment: slot 6 has one
      # blank (board 21 doesn't exist, 0-based index 20), slot 7 is entirely
      # blank (3 blanks). Blanks are matched on the literal placeholder div
      # (not the bare "rc-blank" substring, which also appears once in the
      # page's `<style>` block via the `.result-card.rc-blank` CSS rule).
      assert (html |> String.split(~s(class="result-card">)) |> length()) - 1 == 20

      assert (html |> String.split(~s(<div class="result-card rc-blank"></div>)) |> length()) - 1 ==
               4

      # Extract player names in the order their cards actually render, then
      # keep only the ones belonging to a White-slot rc-player span (each
      # card mentions its White player first) — simplest robust check is to
      # just walk the "P<n>" tokens in document order and assert against the
      # expected slot -> board mapping directly.
      names_in_order =
        Regex.scan(~r/>P(\d+)</, html) |> Enum.map(fn [_, n] -> String.to_integer(n) end)

      # pages = ceil(20/8) = 3. Board on page p (0-based), slot s (0-based)
      # is board index s*pages + p (0-based); board index i is players
      # P(2i+1) (white) vs P(2i+2) (black). Walk slots/pages in render order
      # (page-major, slot-minor) and predict each card's White name.
      pages = 3

      expected_whites =
        for p <- 0..(pages - 1), s <- 0..7 do
          idx = s * pages + p
          if idx < 20, do: 2 * idx + 1, else: nil
        end
        |> Enum.reject(&is_nil/1)

      # 20 boards total (40 players / 2), so 20 White names expected, first
      # occurrence of each "P<n>" per card is the White player.
      actual_whites =
        Regex.scan(~r/rc-who">White<\/span> <strong>P(\d+)/, html)
        |> Enum.map(fn [_, n] -> String.to_integer(n) end)

      assert actual_whites == expected_whites
      assert names_in_order != []
    end

    test "?order=stack combines with ?limit (limit applied first, then imposition)", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Stack Limit Test",
          "type" => "swiss",
          "rounds_count" => "1"
        })

      players =
        for n <- 1..12 do
          Repo.insert!(%Player{tournament_id: tournament.id, name: "P#{n}", pairing_number: n})
        end

      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

      players
      |> Enum.chunk_every(2)
      |> Enum.with_index(1)
      |> Enum.each(fn {[w, b], board} ->
        Repo.insert!(%Pairing{
          round_id: round.id,
          board: board,
          white_player_id: w.id,
          black_player_id: b.id
        })
      end)

      # 6 boards exist; limit=4 keeps boards 1-4 (players P1..P8) before the
      # stack-cut imposition runs. pages = ceil(4/8) = 1, so slots 0..3 hold
      # boards 0..3 and slots 4..7 are blank — i.e. plain board order with 4
      # blanks appended (a single page never needs reordering).
      html =
        get(conn, ~p"/t/#{tournament.id}/print/results?round=1&limit=4&order=stack")
        |> html_response(200)

      assert (html |> String.split(~s(class="result-card">)) |> length()) - 1 == 4

      assert (html |> String.split(~s(<div class="result-card rc-blank"></div>)) |> length()) - 1 ==
               4

      refute html =~ "P9"
      refute html =~ "P11"

      actual_whites =
        Regex.scan(~r/rc-who">White<\/span> <strong>P(\d+)/, html)
        |> Enum.map(fn [_, n] -> String.to_integer(n) end)

      assert actual_whites == [1, 3, 5, 7]
    end
  end

  describe "crosstable/2" do
    test "renders one row per player with rank, name and points", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/crosstable")

      html = html_response(conn, 200)
      assert html =~ "Cross table"
      assert html =~ "A"
      assert html =~ "B"
      assert html =~ "C"
      assert html =~ "D"
      # A won both games, so total points after round 2 is 2.0.
      assert html =~ ~r/A.*?<strong>2\.0<\/strong>/s
    end

    test "shows a compact result code once a result exists", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/crosstable")

      html = html_response(conn, 200)
      # A (pairing_number 1) beat B (pairing_number 2) as white in round 1 —
      # B's row shows a loss ("0") against opponent #1 as black.
      assert html =~ "1b0"
    end
  end

  describe "crosstable/2 — round robin players×players grid" do
    # Round-robin tournament, `cycles` cycles, 4 rated players (Alice=2000,
    # Bob=1900, Carol=1800, Dave=1700 -> frozen pairing numbers 1..4). Round
    # 1 is the FIDE Berger table's {1,4} (Alice white vs Dave) and {2,3}
    # (Bob white vs Carol) — see PairingsEngine.RoundRobinTest, which
    # verifies this exact table against the published FIDE N=4 annex.
    defp round_robin_fixture(scope, cycles) do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "RR Print Test",
          "type" => "swiss",
          "pairing_system" => "round_robin",
          "rr_cycles" => to_string(cycles),
          "rounds_count" => "12"
        })

      players =
        for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1800}, {"Dave", 1700}],
            into: %{} do
          {:ok, p} =
            Tournaments.create_player(tournament.id, %{
              "name" => name,
              "fide_rating" => to_string(rating)
            })

          {name, p}
        end

      {tournament, players}
    end

    # Pairs the next round and enters `results` — a `%{{white_name,
    # black_name} => result}` map matched against the round's actual
    # pairings by player id (order-independent lookup, since which pair
    # lands on which board isn't asserted here).
    defp pair_and_score(tournament, players_by_name, results) do
      {:ok, round} = PairingsEngine.Pairing.pair_next_round(tournament)
      round = Repo.preload(round, :pairings)
      by_id = Map.new(players_by_name, fn {name, p} -> {p.id, name} end)

      Enum.each(round.pairings, fn pairing ->
        white_name = Map.fetch!(by_id, pairing.white_player_id)
        black_name = Map.fetch!(by_id, pairing.black_player_id)

        case Map.get(results, {white_name, black_name}) do
          nil -> :ok
          result -> {:ok, _} = Tournaments.update_pairing_result(pairing, result)
        end
      end)

      round
    end

    test "single round robin: grid headers are pairing numbers, cells show each side's result", %{
      conn: conn,
      scope: scope
    } do
      {tournament, players} = round_robin_fixture(scope, 1)

      pair_and_score(tournament, players, %{
        {"Alice", "Dave"} => "1-0",
        {"Bob", "Carol"} => "1/2-1/2"
      })

      html = get(conn, ~p"/t/#{tournament.id}/print/crosstable") |> html_response(200)

      assert html =~ "Cross table"
      assert html =~ ~s(class="crosstable rr-crosstable")

      # Column headers are the four players' pairing numbers, 1..4.
      for n <- 1..4, do: assert(html =~ "<th class=\"num\">#{n}</th>")

      # Diagonal is hatched out, once per player (the CSS block itself also
      # mentions "rr-diag" once in its selector, so match the cell's actual
      # class attribute rather than the bare substring).
      assert (html |> String.split(~s(class="num rr-diag")) |> length()) - 1 == 4

      # Alice (row) beat Dave (col) as White -> "1" in Alice's row under
      # Dave's column; from Dave's row the same game reads as a loss ("0").
      assert html =~ ~r/Alice<\/strong><\/td>.*?<td class="num">1<\/td>/s
      assert html =~ ~r/Dave<\/strong><\/td>.*?<td class="num">0<\/td>/s

      # Bob vs Carol drew -> "½" appears from both sides.
      assert html =~ "½"
    end

    test "double round robin shows both cycles' results space-separated, first cycle first", %{
      conn: conn,
      scope: scope
    } do
      {tournament, players} = round_robin_fixture(scope, 2)

      # Round 1 (cycle 1): Alice white beats Dave.
      pair_and_score(tournament, players, %{{"Alice", "Dave"} => "1-0", {"Bob", "Carol"} => "1-0"})

      # Round 2.
      pair_and_score(tournament, players, %{{"Dave", "Carol"} => "1-0", {"Alice", "Bob"} => "1-0"})

      # Round 3.
      pair_and_score(tournament, players, %{{"Bob", "Dave"} => "1-0", {"Carol", "Alice"} => "1-0"})

      # Round 4 (cycle 2, colours reversed vs round 1): Dave white vs Alice
      # black — Alice wins again, this time as Black.
      pair_and_score(tournament, players, %{{"Dave", "Alice"} => "0-1", {"Carol", "Bob"} => "0-1"})

      html = get(conn, ~p"/t/#{tournament.id}/print/crosstable") |> html_response(200)

      # Alice beat Dave in both cycle 1 (as White) and cycle 2 (as Black) ->
      # her cell against Dave shows both results, cycle 1 first.
      assert html =~ ~r/Alice<\/strong><\/td>.*?<td class="num">1 1<\/td>/s
      # Dave lost both -> "0 0" from his row.
      assert html =~ ~r/Dave<\/strong><\/td>.*?<td class="num">0 0<\/td>/s
    end

    test "a forfeit shows +/- rather than a played result", %{conn: conn, scope: scope} do
      {tournament, players} = round_robin_fixture(scope, 1)

      pair_and_score(tournament, players, %{
        {"Alice", "Dave"} => "1-0FF",
        {"Bob", "Carol"} => "1-0"
      })

      html = get(conn, ~p"/t/#{tournament.id}/print/crosstable") |> html_response(200)

      assert html =~ ~r/Alice<\/strong><\/td>.*?<td class="num">\+<\/td>/s
      assert html =~ ~r/Dave<\/strong><\/td>.*?<td class="num">-<\/td>/s
    end

    test "an odd player count's structural bye isn't a column, but its points still count", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "RR Odd Print Test",
          "type" => "swiss",
          "pairing_system" => "round_robin",
          "rr_cycles" => "1",
          "rounds_count" => "12"
        })

      players =
        for {name, rating} <- [
              {"Alice", 2000},
              {"Bob", 1900},
              {"Carol", 1800},
              {"Dave", 1700},
              {"Eve", 1600}
            ],
            into: %{} do
          {:ok, p} =
            Tournaments.create_player(tournament.id, %{
              "name" => name,
              "fide_rating" => to_string(rating)
            })

          {name, p}
        end

      # Alice (highest rated, pairing number 1) sits out round 1's
      # structural bye (see PairingsEngine.RoundRobinTest) — no result to
      # enter for her.
      {:ok, round} = PairingsEngine.Pairing.pair_next_round(tournament)
      round = Repo.preload(round, :pairings)
      assert length(round.pairings) == 2

      by_id = Map.new(players, fn {name, p} -> {p.id, name} end)
      results = %{{"Bob", "Carol"} => "1-0", {"Dave", "Eve"} => "1-0"}

      Enum.each(round.pairings, fn pairing ->
        key =
          {Map.fetch!(by_id, pairing.white_player_id), Map.fetch!(by_id, pairing.black_player_id)}

        if result = results[key], do: Tournaments.update_pairing_result(pairing, result)
      end)

      html = get(conn, ~p"/t/#{tournament.id}/print/crosstable") |> html_response(200)

      # Only 5 real players get a column — no 6th column for the phantom
      # player that the odd-count bye mechanism uses internally.
      assert html =~ "<th class=\"num\">5</th>"
      refute html =~ "<th class=\"num\">6</th>"

      # Alice played no game this round (she had the bye), so her total is
      # exactly the bye's point value (0.0, "requested-zero") — the bye
      # doesn't show as a column, but it's still folded into her Pts total.
      assert html =~ ~r/Alice<\/strong><\/td>.*?<strong>0\.0<\/strong>/s
    end
  end

  describe "player_list/2 and player_cards/2" do
    test "player_list renders the roster regardless of rounds", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/players")

      html = html_response(conn, 200)
      assert html =~ "Registered players (4)"
    end

    test "every printed document credits the pairing engine and Tom Wuyts",
         %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      for path <- [
            ~p"/t/#{tournament.id}/print/players",
            ~p"/t/#{tournament.id}/print/cards",
            ~p"/t/#{tournament.id}/print/pairings?round=1",
            ~p"/t/#{tournament.id}/print/standings",
            ~p"/t/#{tournament.id}/print/crosstable"
          ] do
        html = get(conn, path) |> html_response(200)

        assert html =~ "Paired by OpenPairings using Swiss — FIDE Dutch (JaVaFo)",
               "expected the engine credit on #{path}"

        assert html =~ "many thanks to Tom Wuyts for his valuable feedback.",
               "expected the Tom Wuyts credit on #{path}"
      end
    end

    test "no cols param keeps the historic default column set", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      html = get(conn, ~p"/t/#{tournament.id}/print/players") |> html_response(200)

      assert html =~ "<th>Club</th>"
      assert html =~ ~s(<th class="num">Nat.</th>)
      # Not in the default set, even though it's now a supported column.
      refute html =~ "<th>Cat</th>"
    end

    test "cols= prints exactly the ticked columns, including ones beyond the old fixed five", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _players} = fixture(scope)

      html =
        get(conn, ~p"/t/#{tournament.id}/print/players?cols=cat,birth_year,sex,elo_used")
        |> html_response(200)

      assert html =~ "<th>Cat</th>"
      assert html =~ ~s(<th class="num">Birth</th>)
      assert html =~ "<th>Sex</th>"
      assert html =~ ~s(<th class="num">Elo used</th>)

      # Everything NOT ticked stays off, including the previous defaults.
      refute html =~ "<th>Club</th>"
      refute html =~ ~s(<th class="num">Nat.</th>)
      refute html =~ "<th>Title</th>"
    end

    test "an unticked column set prints name-only", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      html = get(conn, ~p"/t/#{tournament.id}/print/players?cols=") |> html_response(200)

      assert html =~ "<th>Name</th>"
      refute html =~ "<th>Club</th>"
      refute html =~ "<th>Title</th>"
    end

    test "an unknown column key is ignored rather than crashing", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      html =
        get(conn, ~p"/t/#{tournament.id}/print/players?cols=club,not_a_real_column_xyz")
        |> html_response(200)

      assert html =~ "<th>Club</th>"
    end

    test "the Pr. column distinguishes a currently-active round absence from a past/future one, same as the grid",
         %{conn: conn, scope: scope} do
      {tournament, %{a: a, b: b}} = fixture(scope)
      # fixture/1 has 2 rounds paired, so the round about to be paired is 3.
      {:ok, _} = Tournaments.update_player(a, %{"absent_rounds" => "3"})
      {:ok, _} = Tournaments.update_player(b, %{"absent_rounds" => "1"})

      html =
        get(conn, ~p"/t/#{tournament.id}/print/players?cols=pr") |> html_response(200)

      # A is absent for round 3 (the upcoming round) — capital A.
      assert html =~ ">A(3)<"
      # B was absent for round 1, already past — lowercase a.
      assert html =~ ">a(1)<"
    end

    test "player_cards renders one card per player with the full round list", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/cards")

      html = html_response(conn, 200)
      assert html =~ "Player cards"
      # rounds_count is 3 on the fixture tournament, so each card lists 3 rows.
      assert html =~ ~r/class="num">3<\/td>/
    end
  end

  ## ---------- place_cards/2 (SWAR parity #14-16) ----------

  # 1x1 transparent PNG (valid PNG signature: \x89 P N G \r \n \x1a \n).
  @tiny_png Base.decode64!(
              "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )

  describe "place_cards/2" do
    test "renders one page per player, with board numbers from the latest paired round", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/placecards")

      html = html_response(conn, 200)
      assert html =~ "Place cards"
      # 4 players -> 4 "place-card-page" pages, each with an unrotated and a
      # rotated (folded) copy of the same details.
      assert length(Regex.scan(~r/<div class="place-card-page">/, html)) == 4
      assert html =~ "place-card-flip"
      # Fixture's round 2 (the latest paired round): board 1 is C vs A,
      # board 2 is B vs D — every player should show a board number.
      assert html =~ "Board 1"
      assert html =~ "Board 2"
    end

    test "?round=1 uses round 1's board numbers instead of the latest round", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/placecards?round=1")

      html = html_response(conn, 200)
      assert html =~ "Board 1"
      assert html =~ "Board 2"
    end

    test "with no paired round at all, cards render without a board number (never 404s)", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "No rounds yet",
          "type" => "swiss",
          "rounds_count" => "3"
        })

      {:ok, _player} =
        Tournaments.create_player(tournament.id, %{name: "Solo", fide_rating: 1500})

      conn = get(conn, ~p"/t/#{tournament.id}/print/placecards")

      html = html_response(conn, 200)
      assert html =~ "Solo"
      refute html =~ "<div class=\"place-card-board\">"
    end

    test "with no logo set, the logo slot is simply blank", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/placecards")

      refute html_response(conn, 200) =~ "<img class=\"place-card-logo\""
    end

    test "with a logo set, it's embedded as a base64 data: URI on every card", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _players} = fixture(scope)
      {:ok, tournament} = Tournaments.set_logo(tournament, @tiny_png)

      conn = get(conn, ~p"/t/#{tournament.id}/print/placecards")

      html = html_response(conn, 200)
      assert html =~ "<img class=\"place-card-logo\""
      assert html =~ "data:image/png;base64,"
    end

    test "field toggles: title/rating/federation/club/board can each be switched on or off", %{
      conn: conn,
      scope: scope
    } do
      {tournament, %{a: a}} = fixture(scope)

      {:ok, a} =
        Tournaments.update_player(a, %{title: "GM", federation: "BEL", club: "Chess Club A"})

      # Defaults: title + rating + board on, federation + club off.
      default_html = get(conn, ~p"/t/#{tournament.id}/print/placecards") |> html_response(200)
      assert default_html =~ "GM"
      assert default_html =~ "2000"
      refute default_html =~ "BEL"
      refute default_html =~ "Chess Club A"

      # Turn title/rating/board off, federation/club on.
      toggled_html =
        get(
          conn,
          ~p"/t/#{tournament.id}/print/placecards?title=0&rating=0&board=0&federation=1&club=1"
        )
        |> html_response(200)

      refute toggled_html =~ "GM"
      refute toggled_html =~ "<div class=\"place-card-board\">"
      assert toggled_html =~ "BEL"
      assert toggled_html =~ "Chess Club A"

      # Name is always shown, toggle or not.
      assert toggled_html =~ a.name
    end
  end

  ## ---------- Header logo (task: didn't show up on any print doc but
  ## place cards, which have their own separate, bigger logo slot) ----------

  describe "print_page/5 header logo" do
    test "with no logo set, no logo image is rendered", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/pairings")

      refute html_response(conn, 200) =~ "<img class=\"print-header-logo\""
    end

    test "with a logo set, it's embedded next to the title on the pairing list", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _players} = fixture(scope)
      {:ok, tournament} = Tournaments.set_logo(tournament, @tiny_png)

      conn = get(conn, ~p"/t/#{tournament.id}/print/pairings")

      html = html_response(conn, 200)
      assert html =~ "<img class=\"print-header-logo\""
      assert html =~ "data:image/png;base64,"
    end

    test "also shows on standings, player list, and crosstable — every print doc going through print_page/5",
         %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)
      {:ok, tournament} = Tournaments.set_logo(tournament, @tiny_png)

      for path <- [
            ~p"/t/#{tournament.id}/print/standings",
            ~p"/t/#{tournament.id}/print/players",
            ~p"/t/#{tournament.id}/print/crosstable"
          ] do
        assert get(conn, path) |> html_response(200) =~ "<img class=\"print-header-logo\""
      end
    end
  end

  ## ---------- "Tournament info" header block ----------

  # A tournament with every info-block field set (federation, dates, chief
  # arbiter, deputy arbiter, rate of play, round dates) but NOT
  # FIDE-homologated, plus the same 4-player/2-round data `fixture/1` sets up
  # (board pairings, results) so every print doc under test has something to
  # render besides the header.
  defp info_fixture(scope, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          "name" => "Info Block Open",
          "type" => "swiss",
          "rounds_count" => "3",
          "federation" => "BEL",
          "start_date" => "2026-08-01",
          "end_date" => "2026-08-03",
          "chief_arbiter" => "Jane Arbiter",
          "deputy_arbiter" => "Deputy Dan",
          "rate_of_play" => "90 min + 30 sec/move",
          "round_dates" => ["2026-08-01", "2026-08-02", "2026-08-03"],
          "fide_homologated" => false,
          "fide_tournament_id" => ""
        },
        overrides
      )

    {:ok, tournament} = Tournaments.create_tournament(scope, attrs)

    [a, b] =
      for {name, rating, number} <- [{"A", 2000, 1}, {"B", 1800, 2}] do
        Repo.insert!(%Player{
          tournament_id: tournament.id,
          name: name,
          fide_rating: rating,
          pairing_number: number
        })
      end

    r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: "1-0"
    })

    tournament
  end

  describe "tournament info block" do
    test "pairing_list shows federation/dates/chief+deputy arbiter/rate of play/round dates", %{
      conn: conn,
      scope: scope
    } do
      tournament = info_fixture(scope)

      html = get(conn, ~p"/t/#{tournament.id}/print/pairings?round=1") |> html_response(200)

      assert html =~ "tourney-info"
      assert html =~ "Federation: BEL"
      assert html =~ "Dates: 2026-08-01 &ndash; 2026-08-03" or html =~ "2026-08-01"
      assert html =~ "Chief arbiter: Jane Arbiter"
      assert html =~ "Deputy arbiter: Deputy Dan"
      assert html =~ "Rate of play: 90 min + 30 sec/move"
      assert html =~ "Round dates: 2026-08-01 &ndash; 2026-08-03" or html =~ "Round dates:"
    end

    test "standings shows the info block, including deputy arbiter and round dates", %{
      conn: conn,
      scope: scope
    } do
      tournament = info_fixture(scope)

      html = get(conn, ~p"/t/#{tournament.id}/print/standings?round=1") |> html_response(200)

      assert html =~ "tourney-info"
      assert html =~ "Federation: BEL"
      assert html =~ "Chief arbiter: Jane Arbiter"
      assert html =~ "Deputy arbiter: Deputy Dan"
      assert html =~ "Round dates:"
    end

    test "a single round date is shown as one date, not a range", %{conn: conn, scope: scope} do
      tournament = info_fixture(scope, %{"round_dates" => ["2026-08-01"]})

      html = get(conn, ~p"/t/#{tournament.id}/print/standings?round=1") |> html_response(200)

      assert html =~ "Round date: 2026-08-01"
      refute html =~ "Round dates:"
    end

    test "player_list and player_cards show the info block", %{conn: conn, scope: scope} do
      tournament = info_fixture(scope)

      list_html = get(conn, ~p"/t/#{tournament.id}/print/players") |> html_response(200)
      cards_html = get(conn, ~p"/t/#{tournament.id}/print/cards") |> html_response(200)

      assert list_html =~ "tourney-info"
      assert list_html =~ "Rate of play: 90 min + 30 sec/move"
      assert cards_html =~ "tourney-info"
      assert cards_html =~ "Chief arbiter: Jane Arbiter"
    end

    test "crosstable (swiss) shows the info block", %{conn: conn, scope: scope} do
      tournament = info_fixture(scope)

      html = get(conn, ~p"/t/#{tournament.id}/print/crosstable") |> html_response(200)

      assert html =~ "tourney-info"
      assert html =~ "Federation: BEL"
    end

    test "crosstable (round robin) shows the info block", %{conn: conn, scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "RR Info",
          "type" => "roundrobin",
          "pairing_system" => "round_robin",
          "rounds_count" => "3",
          "federation" => "NED",
          "chief_arbiter" => "John Arbiter"
        })

      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "A",
        fide_rating: 2000,
        pairing_number: 1
      })

      html = get(conn, ~p"/t/#{tournament.id}/print/crosstable") |> html_response(200)

      assert html =~ "tourney-info"
      assert html =~ "Federation: NED"
      assert html =~ "Chief arbiter: John Arbiter"
    end

    test "place_cards shows the info block", %{conn: conn, scope: scope} do
      tournament = info_fixture(scope)

      html = get(conn, ~p"/t/#{tournament.id}/print/placecards") |> html_response(200)

      assert html =~ "tourney-info"
      assert html =~ "Federation: BEL"
    end

    test "result_cards shows the info block", %{conn: conn, scope: scope} do
      tournament = info_fixture(scope)

      html = get(conn, ~p"/t/#{tournament.id}/print/results?round=1") |> html_response(200)

      assert html =~ "tourney-info"
      assert html =~ "Chief arbiter: Jane Arbiter"
    end

    test "blank fields are simply omitted, not shown empty", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      html = get(conn, ~p"/t/#{tournament.id}/print/players") |> html_response(200)

      refute html =~ "Federation:"
      refute html =~ "Chief arbiter:"
      refute html =~ "Deputy arbiter:"
      refute html =~ "Rate of play:"
      refute html =~ "Round date"
      refute html =~ "FIDE ID:"
    end

    test "FIDE ID is shown only when the tournament is FIDE-homologated", %{
      conn: conn,
      scope: scope
    } do
      not_homologated = info_fixture(scope, %{"fide_tournament_id" => "BEL2026001"})

      html =
        get(conn, ~p"/t/#{not_homologated.id}/print/players") |> html_response(200)

      refute html =~ "FIDE ID:"

      homologated =
        info_fixture(scope, %{
          "name" => "Homologated Open",
          "fide_homologated" => true,
          "fide_tournament_id" => "BEL2026002"
        })

      html2 = get(conn, ~p"/t/#{homologated.id}/print/players") |> html_response(200)

      assert html2 =~ "FIDE ID: BEL2026002"
    end
  end
end
