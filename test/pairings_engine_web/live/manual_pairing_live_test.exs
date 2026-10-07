defmodule PairingsEngineWeb.ManualPairingLiveTest do
  @moduledoc """
  The Pairings page's manual pairing alteration (VCL4THP Q63, Q65-Q69): a
  session with an explicit or implicit start and an explicit end (Q65), a
  Level-3 tick on a hand edit that breaks the rules (Q66, Q67), the pairing
  checker at the end and its confirmation (Q68, Q69), and a round created
  by hand when no legal pairing exists (Q63). The checks themselves are
  `PairingsEngine.ManualPairingTest`.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Audit, Pairing, Repo, Tournaments, TrfExport}

  setup :register_and_log_in_user

  defp tournament(scope, rounds, names) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Hand edits",
        "type" => "swiss",
        "start_date" => "2026-07-15",
        "rounds_count" => to_string(rounds),
        "round_dates" => List.duplicate("2026-07-15", rounds),
        "tiebreaks" => ["BH", "SB"],
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

  defp pair!(t) do
    {:ok, round} = Pairing.pair_next_round(Repo.reload!(t))
    Tournaments.get_round(t.id, round.number)
  end

  defp play!(t) do
    round = pair!(t)

    for {p, i} <- Enum.with_index(round.pairings), p.black_player_id do
      {:ok, _} = Tournaments.update_pairing_result(p, Enum.at(~w(1-0 0-1 1/2-1/2), rem(i, 3)))
    end

    Tournaments.get_round(t.id, round.number)
  end

  defp actions(t), do: t.id |> Audit.list_for_tournament() |> Enum.map(& &1.action)

  describe "a session with a start and an end (Q65)" do
    test "started from the More menu, finished with nothing changed", %{conn: conn, scope: scope} do
      {t, _} = tournament(scope, 3, ~w(Ann Ben Cas Dan))
      pair!(t)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      refute has_element?(lv, "#mpa-banner")
      lv |> element("#mpa-start-1") |> render_click()
      assert has_element?(lv, "#mpa-banner #mpa-end")
      refute has_element?(lv, "#mpa-start-1")

      lv |> element("#mpa-end") |> render_click()
      refute has_element?(lv, "#mpa-banner")
      refute has_element?(lv, "#mpa-end-dialog")
      assert Tournaments.get_round(t.id, 1).mpa_pibe == nil
      assert "pairing.mpa_started" in actions(t)
      assert "pairing.mpa_finished" in actions(t)
    end

    test "the first hand edit starts it; finishing shows the checker's pairing and needs a tick",
         %{conn: conn, scope: scope} do
      {t, [_ann, _ben, cas, dan]} = tournament(scope, 3, ~w(Ann Ben Cas Dan))
      pair!(t)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      render_click(lv, "arm_swap", %{"player-id" => to_string(cas.id)})
      render_click(lv, "pick_swap_target", %{"player-id" => to_string(dan.id)})
      render_click(lv, "apply_confirm", %{})

      assert has_element?(lv, "#mpa-banner")
      assert Tournaments.get_round(t.id, 1).mpa_session

      lv |> element("#mpa-end") |> render_click()
      assert has_element?(lv, "#mpa-end-dialog #mpa-checker-pairs li", "Ann")
      assert has_element?(lv, "#mpa-end-dialog #mpa-added-pairs li", "Dan")

      assert has_element?(
               lv,
               "#mpa-end-dialog #mpa-end-line",
               "### MPA @ Round 1: 1-3 4-2 => 1-4 3-2"
             )

      # Level 3: not without the tick.
      assert has_element?(lv, "#mpa-end-confirm[disabled]")
      render_click(lv, "mpa_end_confirm", %{})
      assert Tournaments.get_round(t.id, 1).mpa_pibe == nil

      lv |> element("#mpa-ack") |> render_click()
      lv |> element("#mpa-end-confirm") |> render_click()

      round = Tournaments.get_round(t.id, 1)
      assert round.mpa_pibe == "MPA @ Round 1: 1-3 4-2 => 1-4 3-2"
      assert round.mpa_session == nil
      refute has_element?(lv, "#mpa-banner")
      assert has_element?(lv, "#mpa-pibe-note")

      {:ok, text} = TrfExport.export(Repo.reload!(t))
      assert text =~ "### MPA @ Round 1: 1-3 4-2 => 1-4 3-2"
    end

    test "Keep editing leaves the session open", %{conn: conn, scope: scope} do
      {t, [_ann, _ben, cas, dan]} = tournament(scope, 3, ~w(Ann Ben Cas Dan))
      pair!(t)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      render_click(lv, "arm_swap", %{"player-id" => to_string(cas.id)})
      render_click(lv, "pick_swap_target", %{"player-id" => to_string(dan.id)})
      render_click(lv, "apply_confirm", %{})
      lv |> element("#mpa-end") |> render_click()
      render_click(lv, "mpa_dialog_cancel", %{})

      refute has_element?(lv, "#mpa-end-dialog")
      assert has_element?(lv, "#mpa-banner")
      assert Tournaments.get_round(t.id, 1).mpa_session
    end

    test "the next round is not paired while a session is open", %{conn: conn, scope: scope} do
      {t, _} = tournament(scope, 3, ~w(Ann Ben Cas Dan))
      round = play!(t)
      {:ok, _} = PairingsEngine.ManualPairing.start(round)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings?round=2")
      assert has_element?(lv, "#pair-round[disabled]")

      render_click(lv, "pair", %{})
      refute Tournaments.get_round(t.id, 2)
    end
  end

  describe "a hand edit that breaks the rules (Q66)" do
    test "a rematch is named, and the edit waits for its own tick", %{conn: conn, scope: scope} do
      {t, [ann | _]} = tournament(scope, 4, ~w(Ann Ben Cas Dan))
      r1 = play!(t)
      r2 = pair!(t)

      # Ann's round-1 opponent, brought onto her board in round 2.
      met =
        Enum.find_value(r1.pairings, fn p ->
          cond do
            p.white_player_id == ann.id -> p.black_player_id
            p.black_player_id == ann.id -> p.white_player_id
            true -> nil
          end
        end)

      now =
        Enum.find_value(r2.pairings, fn p ->
          cond do
            p.white_player_id == ann.id -> p.black_player_id
            p.black_player_id == ann.id -> p.white_player_id
            true -> nil
          end
        end)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings?round=2")

      render_click(lv, "arm_swap", %{"player-id" => to_string(now)})
      render_click(lv, "pick_swap_target", %{"player-id" => to_string(met)})

      assert has_element?(lv, "#confirm-rule-warnings", "already played each other, in round 1")
      assert has_element?(lv, "#hand-edit-dialog .pe-modal-go[disabled]")

      render_click(lv, "apply_confirm", %{})

      assert Tournaments.get_round(t.id, 2).pairings |> Enum.map(& &1.white_player_id) ==
               Enum.map(r2.pairings, & &1.white_player_id)

      lv |> element("#confirm-rule-ack") |> render_click()
      render_click(lv, "apply_confirm", %{})

      round = Tournaments.get_round(t.id, 2)

      assert Enum.any?(round.pairings, fn p ->
               Enum.sort([p.white_player_id, p.black_player_id]) == Enum.sort([ann.id, met])
             end)
    end
  end

  describe "no legal pairing: the round paired by hand (Q63)" do
    test "offered after the refusal, created behind a tick, paired and finished",
         %{conn: conn, scope: scope} do
      {t, [ann, ben, cas]} = tournament(scope, 4, ~w(Ann Ben Cas))
      for _ <- 1..3, do: play!(t)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings?round=4")
      refute has_element?(lv, "#pair-by-hand")

      render_click(lv, "pair", %{})
      refute Tournaments.get_round(t.id, 4)
      lv |> element("#pair-by-hand") |> render_click()
      assert has_element?(lv, "#mpa-manual_round-dialog")
      assert has_element?(lv, "#pair-by-hand-confirm[disabled]")

      lv |> element("#mpa-ack") |> render_click()
      lv |> element("#pair-by-hand-confirm") |> render_click()

      round = Tournaments.get_round(t.id, 4)
      assert round.pairings == []
      assert round.mpa_session
      assert has_element?(lv, "#mpa-banner")
      assert has_element?(lv, "#round-pool-4")
      assert "pairing.round_created_by_hand" in actions(t)

      # Ann and Ben on a board (a rematch: ticked), Cas the bye (a second
      # one: ticked).
      render_click(lv, "stage_pool_pair", %{"player-id" => to_string(ann.id)})
      render_click(lv, "stage_pool_pair", %{"player-id" => to_string(ben.id)})
      assert has_element?(lv, "#confirm-rule-warnings")
      lv |> element("#confirm-rule-ack") |> render_click()
      render_click(lv, "apply_confirm", %{})

      render_click(lv, "stage_pool_bye", %{"player-id" => to_string(cas.id)})
      assert has_element?(lv, "#confirm-rule-warnings", "already had a pairing-allocated bye")
      lv |> element("#confirm-rule-ack") |> render_click()
      render_click(lv, "apply_confirm", %{})

      assert length(Tournaments.get_round(t.id, 4).pairings) == 2

      lv |> element("#mpa-end") |> render_click()
      assert has_element?(lv, "#mpa-end-dialog", "No legal pairing exists for this round.")
      lv |> element("#mpa-ack") |> render_click()
      lv |> element("#mpa-end-confirm") |> render_click()

      assert Tournaments.get_round(t.id, 4).mpa_pibe =~
               ~r/^MPA @ Round 4: no legal pairing => \d-\d \d=PAB$/
    end
  end
end
