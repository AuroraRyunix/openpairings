defmodule PairingsEngineWeb.PairingExplainLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Pairing, Repo, Tournaments}
  alias PairingsEngine.Tournaments.Round, as: RoundSchema
  alias PairingsEngine.Tournaments.Pairing, as: PairingSchema

  setup :register_and_log_in_user

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

  ## ---------- Task A: rich hover popovers on the bracket-map dots ----------

  test "renders one hover popover per player-dot with the same rich detail as its board card", %{
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

    # Pure-CSS hover-reveal scaffold: an overlay of dot-wraps, each wrapping
    # a hidden popover shown via CSS (no JS anywhere on this page).
    assert html =~ "pe-dot-overlay"
    assert html =~ "pe-dot-wrap"
    assert html =~ "pe-dot-popover"

    # The popover carries the same per-player facts as the board card below
    # it: name, board/seed, colour, colour-due verdict, rematch check.
    assert html =~ "Alice"
    assert html =~ "no prior meeting"
    assert html =~ "no colour history yet"
    assert html =~ ~r/seed #\d/

    # The native SVG title is still present as a fallback.
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
end
