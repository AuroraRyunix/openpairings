defmodule PairingsEngineWeb.ManualRoundRobinLiveTest do
  @moduledoc """
  The Pairings page's round robin paired by hand (VCL4THP Q100-Q102): the
  next round created empty behind a tick, paired from the not-playing list,
  each board checked as it is made (a pair meeting twice in a cycle, Q101;
  a third colour running, Q102), and the round held to the Berger table's
  when the hand edits finish. The rules themselves are
  `PairingsEngine.ManualRoundRobinTest`.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Audit, Repo, Tournaments}

  setup :register_and_log_in_user

  defp tournament(scope, names) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Round robin by hand",
        "type" => "roundrobin",
        "pairing_system" => "round_robin",
        "start_date" => "2026-07-15",
        "rounds_count" => "3",
        "round_dates" => List.duplicate("2026-07-15", 3),
        "tiebreaks" => ["SB"],
        "chief_arbiter" => "Jane Arbiter",
        "federation" => "BEL",
        "rate_of_play" => "90 min + 30 sec/move"
      })

    players =
      for {name, i} <- Enum.with_index(names) do
        {:ok, p} =
          Tournaments.create_player(t.id, %{
            tournament_id: t.id,
            name: name,
            fide_rating: 2000 - 50 * i
          })

        p
      end

    {Repo.reload!(t), players}
  end

  defp pool_pair(lv, white, black) do
    render_click(lv, "stage_pool_pair", %{"player-id" => to_string(white.id)})
    render_click(lv, "stage_pool_pair", %{"player-id" => to_string(black.id)})
  end

  defp create_round(lv) do
    lv |> element("#rr-pair-by-hand") |> render_click()
    assert has_element?(lv, "#mpa-rr_round-dialog")
    assert has_element?(lv, "#rr-pair-by-hand-confirm[disabled]")
    lv |> element("#mpa-ack") |> render_click()
    lv |> element("#rr-pair-by-hand-confirm") |> render_click()
  end

  test "a round paired by hand, differing from the table, is recorded (Q100)",
       %{conn: conn, scope: scope} do
    {t, [ann, ben, cas, dan]} = tournament(scope, ~w(Ann Ben Cas Dan))
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

    assert has_element?(lv, "#pair-round")
    create_round(lv)

    round = Tournaments.get_round(t.id, 1)
    assert round.pairings == []
    assert round.mpa_session
    assert has_element?(lv, "#mpa-banner")

    assert "pairing.round_created_by_hand" in Enum.map(
             Audit.list_for_tournament(t.id),
             & &1.action
           )

    # The table pairs 1-4 2-3 in round 1; these are not its boards.
    pool_pair(lv, ann, ben)
    render_click(lv, "apply_confirm", %{})
    pool_pair(lv, cas, dan)
    render_click(lv, "apply_confirm", %{})
    assert length(Tournaments.get_round(t.id, 1).pairings) == 2

    lv |> element("#mpa-end") |> render_click()
    assert has_element?(lv, "#mpa-end-dialog", "Berger table")
    assert has_element?(lv, "#mpa-checker-pairs")
    lv |> element("#mpa-ack") |> render_click()
    lv |> element("#mpa-end-confirm") |> render_click()

    round = Tournaments.get_round(t.id, 1)
    refute round.mpa_session
    assert round.mpa_pibe == "MPA @ Round 1: 1-4 2-3 => 1-2 3-4"
  end

  test "a pair meeting twice in the cycle, and a third White, each need a tick (Q101, Q102)",
       %{conn: conn, scope: scope} do
    {t, [ann, ben, cas, dan]} = tournament(scope, ~w(Ann Ben Cas Dan))
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

    for {boards, n} <- Enum.with_index([[{ann, ben}, {cas, dan}], [{ann, cas}, {dan, ben}]], 1) do
      render_click(lv, "select_round", %{"number" => to_string(n)})
      create_round(lv)

      for {w, b} <- boards do
        pool_pair(lv, w, b)
        render_click(lv, "apply_confirm", %{})
      end

      lv |> element("#mpa-end") |> render_click()

      if has_element?(lv, "#mpa-end-confirm") do
        lv |> element("#mpa-ack") |> render_click()
        lv |> element("#mpa-end-confirm") |> render_click()
      end

      refute Tournaments.get_round(t.id, n).mpa_session
    end

    render_click(lv, "select_round", %{"number" => "3"})
    create_round(lv)

    # Ann and Ben again: met in round 1 of this cycle.
    pool_pair(lv, ann, ben)
    assert has_element?(lv, "#confirm-rule-warnings", "already meet in round 1")
    render_click(lv, "cancel_confirm", %{})

    # Ann White a third round running.
    pool_pair(lv, ann, dan)
    assert has_element?(lv, "#confirm-rule-warnings", "third round running")
    assert has_element?(lv, "#hand-edit-dialog .pe-modal-go[disabled]")
    lv |> element("#confirm-rule-ack") |> render_click()
    render_click(lv, "apply_confirm", %{})
    assert length(Tournaments.get_round(t.id, 3).pairings) == 1
  end

  test "a team round robin is not offered it", %{conn: conn, scope: scope} do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Teams",
        "type" => "team-roundrobin",
        "pairing_system" => "round_robin"
      })

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    refute has_element?(lv, "#rr-pair-by-hand")
  end
end
