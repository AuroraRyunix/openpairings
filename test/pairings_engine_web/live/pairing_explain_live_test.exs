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
    assert html =~ "— bye, score"
    assert html =~ ~r/aria-label="Board \d+, bye: /
    # The odd field forces a cross-bracket float, shown with direction badges.
    assert html =~ "pe-tag-float"
    assert html =~ "paired down"
    assert html =~ "paired up"
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
    assert html =~ "Anomaly check"
    assert html =~ "not proof of"
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

  @tag :javafo
  test "flags a starting-rank gap left by a mid-field round-specific absentee", %{
    conn: conn,
    scope: scope
  } do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "T",
        "type" => "swiss",
        "start_date" => "2026-07-01"
      })

    for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}] do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name, "fide_rating" => "#{rating}"})
    end

    # Rated between Bob and Dave — after pairing numbers freeze (highest
    # rating first), Carol lands 3rd of 5, so sitting her out round 1 only
    # leaves a gap in the MIDDLE of the starting-rank range.
    {:ok, _carol} =
      Tournaments.create_player(t.id, %{
        "name" => "Carol",
        "fide_rating" => "1800",
        "absent_rounds" => "1"
      })

    for {name, rating} <- [{"Dave", 1700}, {"Eve", 1600}] do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name, "fide_rating" => "#{rating}"})
    end

    assert {:ok, _round} = Pairing.pair_next_round(t)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")

    assert html =~ "pe-warning"
    assert html =~ "gap in the pairing-number sequence"
    assert html =~ "Carol"
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

    # Keyed by player id; every player has one entry per round through 3.
    carol_trail = trails[carol.id]
    assert [r1, r2, r3] = carol_trail

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
    assert Enum.map(trails[alice.id], & &1.score) == [1.0, 1.0, 1.0]

    # Round 1 has no history worth a trail.
    assert PairingRationale.player_trails(t, 1) == %{}
  end

  test "a round-2 explain page renders each dot's trail (history + running scores), hidden until pinned",
       %{conn: conn, scope: scope} do
    {t, _players} = three_round_swiss(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings/2/explain")

    # The trail scaffold is present in the popovers (revealed only when the
    # dot is pinned — pure CSS, no server roundtrip).
    assert html =~ "pe-trail"
    assert html =~ "Tournament so far"
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
    # It scales the shared layout for free (unique to the minimap SVG).
    assert html =~ "preserveAspectRatio"
  end
end
