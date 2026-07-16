defmodule PairingsEngineWeb.PairingExplainLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Pairing, Tournaments}

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

    assert lv |> element("a.filter-picker", "Explain a round") |> render() =~ "active"
    assert lv |> element("#explain-round-selector a", "1") |> render() =~ "active"
    refute lv |> element("#explain-round-selector a", "2") |> render() =~ "active"

    # Hopping to round 2 from the selector lands on a working page.
    {:ok, _lv2, html2} = live(conn, ~p"/t/#{t.id}/pairings/2/explain")
    assert html2 =~ "Round 2"
  end
end
