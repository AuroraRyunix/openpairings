defmodule PairingsEngineWeb.PairingExplainLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Pairing, PairingRationale, Repo, Tournaments}
  alias PairingsEngine.Tournaments.Round, as: RoundSchema
  alias PairingsEngine.Tournaments.Pairing, as: PairingSchema

  setup :register_and_log_in_user

  # Hand-builds a 5-player, 3-round Swiss (no JaVaFo) exercising every trail
  # case: a player absent an early round, byes, decisive/drawn results, and a
  # still-pending final round. Returns the tournament plus its players. Carol
  # is absent in round 1 (no pairing), then present rounds 2-3; round 3 is
  # left unplayed (the round being explained).
  defp three_round_swiss(scope) do
    {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Trail", "type" => "swiss"})

    players =
      Map.new(~w(Alice Bob Carol Dave Erin), fn name ->
        {:ok, p} = Tournaments.create_player(t.id, %{"name" => name})
        {name, p}
      end)

    %{"Alice" => a, "Bob" => b, "Carol" => c, "Dave" => d, "Erin" => e} = players

    # Round 1 — Carol absent (no pairing); Alice/Dave win.
    r1 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 1, status: "playing"})
    board(r1, 1, a, b, "1-0")
    board(r1, 2, d, e, "1-0")

    # Round 2 — Carol back and wins as Black; Bob/Dave draw; Erin gets the bye.
    r2 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 2, status: "playing"})
    board(r2, 1, a, c, "0-1")
    board(r2, 2, b, d, "1/2-1/2")
    bye_board(r2, 3, e)

    # Round 3 — the round being explained: two unplayed boards + Bob's bye.
    r3 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 3, status: "playing"})
    board(r3, 1, a, d, "")
    board(r3, 2, c, e, "")
    bye_board(r3, 3, b)

    {Tournaments.get_tournament!(t.id), players}
  end

  defp board(round, board, white, black, result) do
    Repo.insert!(%PairingSchema{
      round_id: round.id,
      board: board,
      white_player_id: white.id,
      black_player_id: black.id,
      result: result
    })
  end

  defp bye_board(round, board, player) do
    Repo.insert!(%PairingSchema{
      round_id: round.id,
      board: board,
      white_player_id: player.id,
      black_player_id: nil,
      result: "bye"
    })
  end

  test "shows a not-paired-yet message for an unpaired round", %{conn: conn, scope: scope} do
    {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "T", "type" => "swiss"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")
    assert html =~ "has not been paired yet"
  end

  test "explains a round-robin round via the Berger schedule", %{conn: conn, scope: scope} do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "RR",
        "type" => "roundrobin",
        "pairing_system" => "round_robin"
      })

    for name <- ~w(Alice Bob Carol Dave) do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name})
    end

    assert {:ok, _round} = Pairing.pair_next_round(t)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")

    assert html =~ "Berger schedule"
    assert html =~ "deterministic"

    # The visual redesign: board-by-board cards with white/black colour chips
    # and the score-bracket map, not the old plain table.
    assert html =~ "Board by board"
    assert html =~ "pe-pair-grid"
    assert html =~ "pe-disc-w"
    assert html =~ "pe-disc-b"
    # One score bracket (everyone on 0) is drawn in the bracket map SVG.
    assert html =~ "pe-bracket-svg"
    assert html =~ "Score-bracket map"

    # The bracket map's SVG fills/strokes are CSS custom properties, not
    # fixed light-theme hex values — otherwise the chart is unreadable
    # (wrong contrast, or literally invisible) under every theme but the
    # default light one. Spot-checks the band backgrounds and the player
    # dots specifically, since those are what "does not work with the
    # themes" was actually about.
    assert html =~ "var(--surface)"
    assert html =~ "var(--accent)"
    refute html =~ "#faf9f6"
    refute html =~ "#f1efe9"
  end

  @tag :javafo
  test "identifies the floater pairing and the bye recipient in a Swiss round", %{
    conn: conn,
    scope: scope
  } do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Swiss",
        "type" => "swiss",
        "start_date" => "2026-07-01"
      })

    for {name, rating} <- [
          {"Alice", 2000},
          {"Bob", 1900},
          {"Carol", 1800},
          {"Dave", 1700},
          {"Erin", 1600}
        ] do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name, "fide_rating" => "#{rating}"})
    end

    assert {:ok, round1} = Pairing.pair_next_round(t)
    round1 = PairingsEngine.Repo.preload(round1, :pairings)

    Enum.each(round1.pairings, fn p ->
      if p.black_player_id, do: {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
    end)

    assert {:ok, _round2} = Pairing.pair_next_round(t)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/2/explain")

    # Odd field → a pairing-allocated bye is shown and explained.
    assert html =~ "pairing-allocated bye"
    assert html =~ "lowest-ranked eligible player"
    # Score brackets are rendered, as an SVG map with the bye highlighted.
    assert html =~ "Pre-round score brackets"
    assert html =~ "pe-bracket-svg"
    assert html =~ "pe-bye-card"
    # The bye recipient also appears IN the map: a dashed lone dot in their
    # own score band, with its own single-dot hover wrap.
    assert html =~ "- bye, score"
    assert html =~ ~r/aria-label="Board \d+, bye: /
    # The odd field forces a cross-bracket float, shown with direction badges.
    assert html =~ "pe-tag-float"
    assert html =~ "paired down"
    assert html =~ "paired up"

    # Paired-up/-down triangle markers and the floater/rematch connector
    # lines are themed too (var(--warn)/var(--info)/var(--text-soft)), not
    # fixed hex.
    assert html =~ "var(--warn)"
    assert html =~ "var(--info)"
    refute html =~ "#b5762f"
    refute html =~ "#3a6ea5"
  end

  @tag :javafo
  test "the pairing-numbers list shows starting rank vs. starting rank, the classic pairing-sheet format",
       %{conn: conn, scope: scope} do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Swiss",
        "type" => "swiss",
        "start_date" => "2026-07-01"
      })

    for {name, rating} <- [
          {"Alice", 2000},
          {"Bob", 1900},
          {"Carol", 1800},
          {"Dave", 1700}
        ] do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name, "fide_rating" => "#{rating}"})
    end

    assert {:ok, _round1} = Pairing.pair_next_round(t)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")

    assert html =~ "Pairing numbers"

    players = Tournaments.list_players(t.id)
    alice = Enum.find(players, &(&1.name == "Alice"))
    dave = Enum.find(players, &(&1.name == "Dave"))

    # The section shows each board's two starting ranks alongside the
    # names, not just names — the plain "1 vs 4" format an arbiter reading
    # off a printed pairing sheet expects, no hovering required.
    assert html =~ ~r/<span class="pe-seed">#{alice.pairing_number}<\/span> Alice/
    assert html =~ ~r/<span class="pe-seed">#{dave.pairing_number}<\/span> Dave/
  end

  test "a non-collaborator cannot open the explain page", %{conn: conn} do
    other = user_scope_fixture()
    {:ok, t} = Tournaments.create_tournament(other, %{"name" => "Private", "type" => "swiss"})

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/t/#{t.id}/pairings/1/explain")
    end
  end

  test "still renders at the old bookmarkable route, now nested under Advanced/audit", %{
    conn: conn,
    scope: scope
  } do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "RR",
        "type" => "roundrobin",
        "pairing_system" => "round_robin"
      })

    for name <- ~w(Alice Bob Carol Dave) do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name})
    end

    assert {:ok, _round} = Pairing.pair_next_round(t)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")

    # active="audit" highlights the top-bar Advanced menu, not Pairings.
    assert html =~ ~s(href="/t/#{t.id}/audit/explain")
    # Back link now goes to the audit trail rather than the pairings page.
    assert html =~ ~s(href="/t/#{t.id}/audit")
    assert html =~ "Back to audit trail"
  end

  test "the sub-nav and round selector are present, with the current round highlighted", %{
    conn: conn,
    scope: scope
  } do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "RR",
        "type" => "roundrobin",
        "pairing_system" => "round_robin"
      })

    for name <- ~w(Alice Bob Carol Dave) do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name})
    end

    assert {:ok, _round1} = Pairing.pair_next_round(t)
    assert {:ok, _round2} = Pairing.pair_next_round(t)

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")

    assert lv |> element("a.filter-picker", "Pairing rationale") |> render() =~ "active"
    assert lv |> element("#explain-round-selector a", "1") |> render() =~ "active"
    refute lv |> element("#explain-round-selector a", "2") |> render() =~ "active"

    # Hopping to round 2 from the selector lands on a working page.
    {:ok, _lv2, html2} = live(conn, ~p"/t/#{t.id}/pairings/2/explain")
    assert html2 =~ "Round 2"
  end

  @tag :javafo
  test "flags a genuine prior-bye recipient with the red warning note", %{
    conn: conn,
    scope: scope
  } do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Odd",
        "type" => "swiss",
        "start_date" => "2026-07-01"
      })

    {:ok, alice} = Tournaments.create_player(t.id, %{"name" => "Alice", "fide_rating" => "2000"})
    {:ok, bob} = Tournaments.create_player(t.id, %{"name" => "Bob", "fide_rating" => "1900"})
    {:ok, carol} = Tournaments.create_player(t.id, %{"name" => "Carol", "fide_rating" => "1800"})

    # Round 1 via the real pairing engine: an odd (3-player) field, so the
    # lowest-ranked player (Carol) receives the pairing-allocated bye.
    assert {:ok, round1} = Pairing.pair_next_round(t)
    round1 = Repo.preload(round1, :pairings)

    Enum.each(round1.pairings, fn p ->
      if p.black_player_id, do: {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
    end)

    assert Enum.any?(
             round1.pairings,
             &(&1.result == "bye" and &1.white_player_id == carol.id)
           )

    # Round 2 is hand-built rather than paired by the real engine (which
    # actively avoids re-byeing the same player) so Carol gets the
    # pairing-allocated bye a second time — the one scenario the
    # "already had a bye" warning exists to flag.
    round2 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 2, status: "playing"})

    Repo.insert!(%PairingSchema{
      round_id: round2.id,
      board: 1,
      white_player_id: alice.id,
      black_player_id: bob.id,
      result: ""
    })

    Repo.insert!(%PairingSchema{
      round_id: round2.id,
      board: 2,
      white_player_id: carol.id,
      black_player_id: nil,
      result: "bye"
    })

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/2/explain")

    assert html =~ "pe-warning"
    assert html =~ "already had a bye"
  end

  ## ---------- Task A: rich hover popovers on the bracket map ----------

  test "renders one hover popover per DOT with just that player's detail, plus the sticky gutter",
       %{conn: conn, scope: scope} do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "RR",
        "type" => "roundrobin",
        "pairing_system" => "round_robin"
      })

    for name <- ~w(Alice Bob Carol Dave) do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name})
    end

    assert {:ok, _round} = Pairing.pair_next_round(t)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")

    # Pure-CSS hover-reveal scaffold: one wrap per DOT (not per board), each
    # holding a hidden single-player popover shown via CSS (no JS anywhere
    # on this page) — hovering a specific circle shows only that player.
    assert html =~ "pe-board-overlay"
    assert html =~ "pe-dot-popover"

    # 4 players round robin → 2 boards → exactly 4 hover wraps (one per
    # player, not one per board).
    assert length(String.split(html, "pe-board-wrap")) - 1 == 4

    # Each wrap is focusable (touch/keyboard) and names exactly one player.
    assert html =~ ~r/aria-label="Board \d+, (White|Black): \w+"/

    # Popover content is per-player, not a combined pair: each dot's own
    # name/colour/score/seed/due-colour verdict, not both sides at once.
    assert html =~ "Alice"
    assert html =~ "no colour history yet"

    # The score-band labels moved into the sticky gutter.
    assert html =~ "pe-band-gutter"
    assert html =~ "pe-band-score"

    # Board-number axis under each column, and the native SVG title fallback.
    assert html =~ "pe-bracket-canvas"
    assert html =~ "<title>"
  end

  ## ---------- Task B: anomaly checks ----------

  test "flags a genuine rematch outside match format with a red warning, and explains the framing",
       %{conn: conn, scope: scope} do
    {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Swiss", "type" => "swiss"})

    {:ok, alice} = Tournaments.create_player(t.id, %{"name" => "Alice"})
    {:ok, bob} = Tournaments.create_player(t.id, %{"name" => "Bob"})

    round1 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 1, status: "playing"})

    Repo.insert!(%PairingSchema{
      round_id: round1.id,
      board: 1,
      white_player_id: alice.id,
      black_player_id: bob.id,
      result: "1-0"
    })

    round2 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 2, status: "playing"})

    Repo.insert!(%PairingSchema{
      round_id: round2.id,
      board: 1,
      white_player_id: bob.id,
      black_player_id: alice.id,
      result: ""
    })

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/2/explain")

    assert html =~ "pe-warning"
    assert html =~ "already met in an earlier round"
    # The page's honest, not-proof-of-error framing is present.
    assert html =~ "Worth a look"
    assert html =~ "not proof of"
    refute html =~ "Anomaly check"

    # It also shows up in the top-of-page summary panel, linking to the board.
    assert html =~ "pe-board-1"
  end

  test "does not flag a rematch as an anomaly when swiss_match_format is enabled", %{
    conn: conn,
    scope: scope
  } do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Swiss MF",
        "type" => "swiss",
        "rounds_count" => "4",
        "swiss_match_format" => "true"
      })

    {:ok, alice} = Tournaments.create_player(t.id, %{"name" => "Alice"})
    {:ok, bob} = Tournaments.create_player(t.id, %{"name" => "Bob"})

    round1 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 1, status: "playing"})

    Repo.insert!(%PairingSchema{
      round_id: round1.id,
      board: 1,
      white_player_id: alice.id,
      black_player_id: bob.id,
      result: "1-0"
    })

    round2 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 2, status: "playing"})

    Repo.insert!(%PairingSchema{
      round_id: round2.id,
      board: 1,
      white_player_id: bob.id,
      black_player_id: alice.id,
      result: ""
    })

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/2/explain")

    # The neutral REMATCH tag still shows (unchanged meaning)...
    assert html =~ "REMATCH"
    # ...but the anomaly warning language must not appear for this board.
    refute html =~ "already met in an earlier round"
  end

  test "the top-of-page summary panel is absent for a clean round", %{conn: conn, scope: scope} do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "RR",
        "type" => "roundrobin",
        "pairing_system" => "round_robin"
      })

    for name <- ~w(Alice Bob Carol Dave) do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name})
    end

    assert {:ok, _round} = Pairing.pair_next_round(t)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")

    # The intro hint still names "Worth a look" once (explaining what the
    # label means), but the summary panel itself — a per-item anchor link to
    # a flagged board — must not render when the round is clean.
    refute html =~ ~s(href="#pe-board-)
    refute html =~ "gap in the pairing-number sequence"
  end

  test "the top-of-page summary panel flags a repeat pairing-allocated bye, linking to its board",
       %{conn: conn, scope: scope} do
    {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Swiss", "type" => "swiss"})
    {:ok, alice} = Tournaments.create_player(t.id, %{"name" => "Alice"})

    round1 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 1, status: "playing"})

    Repo.insert!(%PairingSchema{
      round_id: round1.id,
      board: 1,
      white_player_id: alice.id,
      black_player_id: nil,
      result: "bye"
    })

    round2 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 2, status: "playing"})

    Repo.insert!(%PairingSchema{
      round_id: round2.id,
      board: 1,
      white_player_id: alice.id,
      black_player_id: nil,
      result: "bye"
    })

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/2/explain")

    assert html =~ "Worth a look"
    assert html =~ "has now had two engine-assigned byes"
    assert html =~ ~s(href="#pe-board-1")
    assert html =~ "pe-board-1"
  end

  ## ---------- Task 1/2/3/4: legend-as-filter, band counts, colour-due halo, rematch shading ----------

  test "legend items are data-filter buttons and the band gutter shows counts", %{
    conn: conn,
    scope: scope
  } do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "RR",
        "type" => "roundrobin",
        "pairing_system" => "round_robin"
      })

    for name <- ~w(Alice Bob Carol Dave) do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name})
    end

    assert {:ok, _round} = Pairing.pair_next_round(t)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")

    # Legend items are real, clickable filter buttons (task 1).
    assert html =~ ~s(data-filter="w")
    assert html =~ ~s(data-filter="b")
    assert html =~ ~s(data-filter="within")
    assert html =~ ~s(data-filter="float")
    assert html =~ ~s(data-filter="down")
    assert html =~ ~s(data-filter="up")
    assert html =~ "pe-bracket-map"
    assert html =~ ~s(data-active-filter="")

    # The score-band gutter row is itself a clickable filter button, and
    # already showed the per-band player count before this task ("4p" for
    # everyone on 0 — one band, four players).
    assert html =~ ~s(data-filter="band-0")
    assert html =~ "4p"

    # Every SVG dot/link carries data-facets for the client-side filter to
    # match against.
    assert html =~ "data-facets="
    assert html =~ "pe-filterable"
  end

  test "a colour-against-due dot gets a halo ring, its own legend item, and an aria mention", %{
    conn: conn,
    scope: scope
  } do
    {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Swiss", "type" => "swiss"})

    {:ok, alice} = Tournaments.create_player(t.id, %{"name" => "Alice"})
    {:ok, bob} = Tournaments.create_player(t.id, %{"name" => "Bob"})

    # Both hand-built (no real pairing engine involved) so the same colours
    # repeat back-to-back: after round 1, Alice is due Black and Bob is due
    # White, but round 2 gives them the SAME colours again — the one
    # scenario colour_matches_due?/2 flags as a violation for both sides.
    round1 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 1, status: "playing"})

    Repo.insert!(%PairingSchema{
      round_id: round1.id,
      board: 1,
      white_player_id: alice.id,
      black_player_id: bob.id,
      result: "1-0"
    })

    round2 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 2, status: "playing"})

    Repo.insert!(%PairingSchema{
      round_id: round2.id,
      board: 1,
      white_player_id: alice.id,
      black_player_id: bob.id,
      result: ""
    })

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/2/explain")

    assert html =~ "pe-dot-halo"
    assert html =~ ~s(data-filter="against-due")
    assert html =~ "colour against due"
    assert html =~ ~r/aria-label="Board \d+, (White|Black): \w+, against due colour"/
  end

  test "deliberate match-format rematches get their own legend item and neutral link style", %{
    conn: conn,
    scope: scope
  } do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Swiss MF",
        "type" => "swiss",
        "rounds_count" => "4",
        "swiss_match_format" => "true"
      })

    {:ok, alice} = Tournaments.create_player(t.id, %{"name" => "Alice"})
    {:ok, bob} = Tournaments.create_player(t.id, %{"name" => "Bob"})

    round1 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 1, status: "playing"})

    Repo.insert!(%PairingSchema{
      round_id: round1.id,
      board: 1,
      white_player_id: alice.id,
      black_player_id: bob.id,
      result: "1-0"
    })

    round2 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 2, status: "playing"})

    Repo.insert!(%PairingSchema{
      round_id: round2.id,
      board: 1,
      white_player_id: bob.id,
      black_player_id: alice.id,
      result: ""
    })

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/2/explain")

    # A deliberate (non-anomaly) rematch gets its own legend/filter facet,
    # distinct from the danger-red anomaly one.
    assert html =~ ~s(data-filter="rematch")
    assert html =~ "pe-legend-line is-rematch"
    refute html =~ ~s(data-filter="anomaly")
    assert html =~ "rematch (match format)"
  end

  ## ---------- Task A: cross-round trail in the pinned popover ----------

  test "player_trails/2 gives per-round colour/result/opponent + honest running scores", %{
    scope: scope
  } do
    {t, %{"Carol" => carol, "Alice" => alice}} = three_round_swiss(scope)

    trails = PairingRationale.player_trails(t, 3)

    # Keyed by player id; every player has a per-round list plus a summary.
    carol_trail = trails[carol.id]
    assert [r1, r2, r3] = carol_trail.rounds

    # Round 1: Carol wasn't paired → an honest "absent" row, not skipped.
    assert r1.round == 1
    assert r1.colour == "absent"
    assert r1.outcome == :absent
    assert r1.score == 0.0

    # Round 2: Carol won as Black against Alice; running score reflects it.
    assert r2.round == 2
    assert r2.colour == "B"
    assert r2.outcome == :win
    assert r2.opponent_name == "Alice"
    assert r2.score == 1.0

    # Round 3 is the round being explained and is unplayed → pending marker.
    assert r3.round == 3
    assert r3.current
    assert r3.outcome == :pending

    # Alice: win then loss then pending, so her running score stays at 1.0.
    assert Enum.map(trails[alice.id].rounds, & &1.score) == [1.0, 1.0, 1.0]

    # Round 1 has no history worth a trail.
    assert PairingRationale.player_trails(t, 1) == %{}
  end

  ## ---------- "Pairing fairness" summary ----------

  test "player_trails/2 summarises colour balance, float direction and byes", %{scope: scope} do
    {t, %{"Alice" => alice, "Carol" => carol, "Bob" => bob, "Erin" => erin}} =
      three_round_swiss(scope)

    trails = PairingRationale.player_trails(t, 3)

    # Alice played White twice (R1 beat Bob, R2 lost to Carol); her R3 game is
    # still unplayed and so counts nowhere. Entering R2 on 1.0 against Carol's
    # 0.0, she was paired DOWN once.
    assert trails[alice.id].summary.colour == %{w: 2, b: 0}
    assert trails[alice.id].summary.floats == %{up: 0, down: 1}
    assert trails[alice.id].summary.byes == 0

    # Carol is the mirror image of that R2 pairing: one Black game, paired UP.
    assert trails[carol.id].summary.colour == %{w: 0, b: 1}
    assert trails[carol.id].summary.floats == %{up: 1, down: 0}

    # A bye is resolved at creation, so it counts as a bye but never as a
    # colour or a float (Bob: R1 Black, R2 White, R3 bye).
    assert trails[bob.id].summary.colour == %{w: 1, b: 1}
    assert trails[bob.id].summary.byes == 1
    assert trails[erin.id].summary.byes == 1

    # Unrated opponents give no honest average rather than a fake 0.
    assert trails[alice.id].summary.avg_opponent_rating == nil
  end

  test "the fairness summary counts only resolved games, never the pending current round", %{
    scope: scope
  } do
    {t, %{"Alice" => alice}} = three_round_swiss(scope)

    # Alice's R3 pairing (White vs Dave) exists but has no result. Every stat
    # must share one denominator — her two resolved games — so the pending
    # round can't sneak into the float counts while colour/rating ignore it.
    summary = PairingRationale.player_trails(t, 3)[alice.id].summary

    assert summary.colour.w + summary.colour.b == 2
    assert summary.floats.up + summary.floats.down <= 2
    # Entering R2 ahead of Carol is Alice's only float; R1 was an all-square
    # first round and R3 is unplayed.
    assert summary.floats == %{up: 0, down: 1}
  end

  test "player_trails/2 averages real opponents' ratings", %{scope: scope} do
    {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Rated", "type" => "swiss"})

    {:ok, a} = Tournaments.create_player(t.id, %{"name" => "Alice", "fide_rating" => 2000})
    {:ok, b} = Tournaments.create_player(t.id, %{"name" => "Bob", "fide_rating" => 1800})
    {:ok, c} = Tournaments.create_player(t.id, %{"name" => "Carol", "fide_rating" => 1600})
    {:ok, d} = Tournaments.create_player(t.id, %{"name" => "Dave"})

    r1 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 1, status: "playing"})
    board(r1, 1, a, b, "1-0")
    board(r1, 2, c, d, "1-0")

    r2 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 2, status: "playing"})
    board(r2, 1, a, c, "")
    board(r2, 2, b, d, "")

    trails = PairingRationale.player_trails(Tournaments.get_tournament!(t.id), 2)

    # Alice's only resolved game was against Bob (1800) — her pending R2
    # opponent Carol must not drag the average.
    assert trails[a.id].summary.avg_opponent_rating == 1800

    # Carol's only resolved opponent, Dave, is unrated and is skipped rather
    # than averaged in as a zero.
    assert trails[c.id].summary.avg_opponent_rating == nil
  end

  test "head-to-head duo panels render hidden for every playing board, with opponent wiring on the dots",
       %{conn: conn, scope: scope} do
    {t, _players} = three_round_swiss(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/3/explain")

    # Each playing dot carries its opponent's wrap id so the delegated JS
    # listener can detect "pinned player's exact opponent clicked" — a bye
    # dot must carry none.
    assert html =~ ~s(id="pe-dot-1-w")
    assert html =~ ~r/id="pe-dot-1-w"[^>]*data-opponent="pe-dot-1-b"/
    assert html =~ ~r/id="pe-dot-1-b"[^>]*data-opponent="pe-dot-1-w"/
    refute html =~ ~r/id="pe-dot-\d+-bye"[^>]*data-opponent="pe-dot/

    # One hidden duo panel per playing board, keyed to both dots, carrying
    # the head-to-head facts (names in the header, score gap, first-meeting
    # tag). Hidden by default (.pe-duo, revealed by JS adding .is-open).
    assert html =~ ~s(id="pe-duo-1")
    assert html =~ ~r/id="pe-duo-1"[^>]*data-dots="pe-dot-1-w pe-dot-1-b"/
    assert html =~ "pe-duo-head"
    assert html =~ "score gap"
    assert html =~ "first meeting this tournament"
    assert html =~ "pe-duo-close"
  end

  test "the fairness summary renders in the popover, hiding byes when there are none", %{
    conn: conn,
    scope: scope
  } do
    {t, _players} = three_round_swiss(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/3/explain")

    assert html =~ "pe-trail-stats"
    assert html =~ "avg opp"
    # Bob has a round-3 bye, so the bye stat appears on this page at least once.
    assert html =~ ~r/1<\/span>\s*bye/

    # Round 2 has no bye recipient among its own dots' trails-so-far except
    # Erin's; a player with zero byes gets no empty bye chrome.
    refute html =~ "0</span> bye"
  end

  test "a round-2 explain page renders each dot's trail (history + running scores), hidden until pinned",
       %{conn: conn, scope: scope} do
    {t, _players} = three_round_swiss(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/2/explain")

    # The trail scaffold is present in the popovers (revealed only when the
    # dot is pinned — pure CSS, no server roundtrip).
    assert html =~ "pe-trail"
    assert html =~ "Pairing fairness"
    # Sparkline of the running score across rounds.
    assert html =~ "pe-trail-spark"
    # Round-1 history carried into the round-2 popovers, with running scores.
    assert html =~ "pe-trail-rounds"
    assert html =~ "pe-trail-sc"
  end

  test "the trail shows bye and absent rounds honestly, and marks the current round pending", %{
    conn: conn,
    scope: scope
  } do
    {t, _players} = three_round_swiss(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/3/explain")

    # Carol was absent round 1; Erin/Bob had byes — all shown, not skipped.
    assert html =~ "pe-trail-absent"
    assert html =~ "pe-trail-bye"
    # The current (unplayed) round is flagged rather than shown as a result.
    assert html =~ "this round"
  end

  test "round 1 shows no trail chrome (no history)", %{conn: conn, scope: scope} do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "RR",
        "type" => "roundrobin",
        "pairing_system" => "round_robin"
      })

    for name <- ~w(Alice Bob Carol Dave) do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name})
    end

    assert {:ok, _round} = Pairing.pair_next_round(t)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")

    refute html =~ "Tournament so far"
    refute html =~ "pe-trail-rounds"
  end

  ## ---------- Task B: overview minimap ----------

  test "renders the overview minimap SVG and its scroll-sync hook", %{conn: conn, scope: scope} do
    {t, _players} = three_round_swiss(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/3/explain")

    # A second, simplified SVG under the strip, driven by the colocated hook.
    assert html =~ "pe-minimap-wrap"
    assert html =~ "pe-minimap-svg"
    assert html =~ "pe-minimap-viewport"
    # The colocated hook name is compiled to its module-qualified form.
    assert html =~ ~r/phx-hook="[^"]*BracketMinimap"/
    # Stretched, not letterboxed: "meet" left white gutters either side and
    # broke the hook's linear x -> scrollLeft seek math.
    assert html =~ ~s(preserveAspectRatio="none")
  end

  ## ---------- polish: multi-select filters, badges, tooltips ----------

  test "the filter state is a multi-select set, not a single facet", %{conn: conn, scope: scope} do
    {t, _players} = three_round_swiss(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/3/explain")

    # The container carries a set-valued attribute the JS toggles facets in
    # and out of; it starts empty (= nothing filtered, everything lit).
    assert html =~ ~s(data-active-filter="")
    assert html =~ "pe-bracket-map"
  end

  test "paired up/down markers are bare coloured triangles, not circle chips", %{
    conn: conn,
    scope: scope
  } do
    {t, _players} = three_round_swiss(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/3/explain")

    # Round 3 pairs Alice (1.0) against Dave (1.5), so a float marker exists.
    # An interim design wrapped the glyph in a filled `pe-tri-badge` circle;
    # the user asked for the original plain triangles back, so the chip must
    # stay gone and the glyph itself carries the float colour.
    refute html =~ "pe-tri-badge"
    assert html =~ ~r/class="pe-tri pe-filterable"/
  end

  test "the colour-against-due halo and legend explain themselves in plain terms", %{
    conn: conn,
    scope: scope
  } do
    {t, _players} = three_round_swiss(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/3/explain")

    # Alice had White in rounds 1 and 2, so Black is due in round 3; she gets
    # White again, which is exactly what the halo is for. The halo's own title
    # now names both colours instead of the old bare "against due colour".
    assert html =~ ~r/Received \w+; colour history says \w+ was due\./
    assert html =~ "Player&#39;s own colour history says they were due"
  end

  test "a bye recipient never gets a colour-against-due halo", %{conn: conn, scope: scope} do
    {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Bye halo", "type" => "swiss"})

    {:ok, a} = Tournaments.create_player(t.id, %{"name" => "Alice"})
    {:ok, b} = Tournaments.create_player(t.id, %{"name" => "Bob"})
    {:ok, c} = Tournaments.create_player(t.id, %{"name" => "Carol"})

    # Alice plays White twice, so Black is due in round 3 — but she takes the
    # bye there. A bye recipient's side is modelled as the board's White side,
    # so an unguarded colour check would call that "White against a due Black"
    # and halo a round she never played a game in.
    r1 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 1, status: "playing"})
    board(r1, 1, a, b, "1-0")
    bye_board(r1, 2, c)

    r2 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 2, status: "playing"})
    board(r2, 1, a, c, "1-0")
    bye_board(r2, 2, b)

    r3 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 3, status: "playing"})
    board(r3, 1, b, c, "")
    bye_board(r3, 2, a)

    t = Tournaments.get_tournament!(t.id)
    rationale = PairingRationale.for_round(t, 3)
    bye = Enum.find(rationale.boards, & &1.is_bye)

    # The underlying side really does carry the misleading verdict, so this
    # test would pass vacuously if the guard were removed and this changed.
    assert bye.white.player.id == a.id
    assert bye.white.colour_due == :b
    refute bye.white.colour_ok

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/3/explain")

    # The bye dot is drawn and labelled, but carries no against-due note.
    assert html =~ "bye: Alice"
    refute html =~ "bye: Alice, against due colour"
    refute html =~ "Received White; colour history says Black was due"
  end

  describe "vacated seats after pairing (regression, real prod incidents)" do
    test "renders instead of crashing when a seat is vacated on a playing board or a bye recipient is vacated",
         %{conn: conn, scope: scope} do
      {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Vacated", "type" => "swiss"})

      {:ok, a} = Tournaments.create_player(t.id, %{"name" => "Alice"})
      {:ok, b} = Tournaments.create_player(t.id, %{"name" => "Bob"})
      {:ok, c} = Tournaments.create_player(t.id, %{"name" => "Carol"})
      {:ok, d} = Tournaments.create_player(t.id, %{"name" => "Dave"})

      r1 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 1, status: "playing"})
      board(r1, 1, a, b, "1-0")
      bye_board(r1, 2, c)

      r2 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 2, status: "playing"})

      # Board 1: white vacated after pairing (playing board, black stays).
      Repo.insert!(%PairingSchema{
        round_id: r2.id,
        board: 1,
        white_player_id: nil,
        black_player_id: b.id,
        result: ""
      })

      # Board 2: the bye recipient themselves vacated (a "ghost" bye - both
      # seats now empty, but still flagged is_bye since black was already
      # nil before).
      Repo.insert!(%PairingSchema{
        round_id: r2.id,
        board: 2,
        white_player_id: nil,
        black_player_id: nil,
        result: ""
      })

      # Board 3: an ordinary board and a real bye, so there's something
      # unaffected to confirm still renders normally alongside the two
      # vacated boards above.
      board(r2, 3, d, c, "")

      {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/2/explain")

      # Renders (no 500), and says plainly that the vacated seats aren't
      # finished rather than silently omitting them or crashing.
      assert html =~ "Seat vacant"
      assert html =~ "Bob"
      assert html =~ "Dave"
      assert html =~ "Carol"

      # Neither vacated board contributes a dot to the score-bracket graph
      # (nobody to plot) - only the untouched board 3's two real players do.
      assert html =~ ~r/aria-label="Board 3, White: Dave/
      assert html =~ ~r/aria-label="Board 3, Black: Carol/
      refute html =~ ~r/aria-label="Board 1,/
      refute html =~ ~r/aria-label="Board 2,/

      # The "Pairing numbers" table still lists every board, marking the
      # vacant seats rather than crashing on them.
      assert html =~ "— vacant —"
    end
  end
end
