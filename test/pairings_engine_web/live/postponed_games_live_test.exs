defmodule PairingsEngineWeb.PostponedGamesLiveTest do
  @moduledoc """
  Postponed games on the arbiter's screens (VCL4THP Q157-169): the Pairings
  page's result select, its confirmations and pair buttons, the Standings
  page's "not final" banner, the printed standings and the phone.
  """
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Audit, Mobile, Repo, Tournaments}
  alias PairingsEngine.Pairing, as: Engine

  setup :register_and_log_in_user

  # Complete setup, four players, round 1 paired: Alice-Carol and Bob-Dave.
  defp tournament(scope) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Club championship",
        "type" => "swiss",
        "start_date" => "2026-09-01",
        "rounds_count" => "3",
        "round_dates" => ["2026-09-01", "2026-09-08", "2026-09-15"],
        "tiebreaks" => ["BH", "SB"],
        "postponed_games" => "true"
      })

    for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1800}, {"Dave", 1700}] do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name, "fide_rating" => "#{rating}"})
    end

    {:ok, _} = Engine.pair_next_round(t)
    Tournaments.get_tournament!(t.id)
  end

  defp boards(t, round_number), do: Tournaments.get_round(t.id, round_number).pairings

  defp set!(pairing, result, opts \\ []) do
    {:ok, updated} = Tournaments.update_pairing_result(pairing, result, opts)
    updated
  end

  defp change_result(lv, pairing, result) do
    lv
    |> element("#result-form-#{pairing.id}")
    |> render_change(%{"pairing-id" => pairing.id, "result" => result})
  end

  describe "the Pairings page" do
    test "offers postponed, records it, and lists the game until it is played", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      [board | _] = boards(t, 1)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      assert has_element?(lv, "#result-select-#{board.id} option[value='*W']")
      refute has_element?(lv, "#postponed-games")

      change_result(lv, board, "*W")

      assert Repo.reload!(board).result == "*W"
      assert has_element?(lv, "#postponed-games #postponed-game-#{board.id}")
      {:ok, export, _html} = live(conn, ~p"/t/#{t.id}/settings/export")
      assert has_element?(export, "#postponed-trf-not-final")
    end

    test "a decisive result for a postponed game waits for confirmation (Q163)", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      [board | _] = boards(t, 1)
      set!(board, "*")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      change_result(lv, board, "1-0")

      assert has_element?(lv, "#confirm-postponed-#{board.id}")
      assert Repo.reload!(board).result == "*"

      lv |> element("#confirm-postponed-yes-#{board.id}") |> render_click()

      assert Repo.reload!(board).result == "1-0"
      refute has_element?(lv, "#confirm-postponed-#{board.id}")
      refute has_element?(lv, "#postponed-games")

      [entry | _] = Audit.list_for_tournament(t.id)
      assert entry.action == "pairing.result_changed"
      assert entry.details["confirmed"] == "adjourned_non_draw_result"
    end

    test "cancelling the confirmation leaves the game postponed", %{conn: conn, scope: scope} do
      t = tournament(scope)
      [board | _] = boards(t, 1)
      set!(board, "*")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      change_result(lv, board, "0-1")
      lv |> element("#confirm-postponed-cancel-#{board.id}") |> render_click()

      refute has_element?(lv, "#confirm-postponed-#{board.id}")
      assert Repo.reload!(board).result == "*"
    end

    test "a draw over a postponed game is written straight away", %{conn: conn, scope: scope} do
      t = tournament(scope)
      [board | _] = boards(t, 1)
      set!(board, "*")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      change_result(lv, board, "1/2-1/2")

      refute has_element?(lv, "#confirm-postponed-#{board.id}")
      assert Repo.reload!(board).result == "1/2-1/2"
    end

    test "missing results can be recorded as postponed to pair the next round (Q159, Q160)", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      [open, reported] = boards(t, 1)
      set!(reported, "1-0")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      lv |> element(".round-picker button[phx-value-number='2']") |> render_click()

      # The ordinary button stays disabled; recording is its own click, and
      # carries a confirmation.
      assert has_element?(lv, "#pair-round[disabled]")

      assert has_element?(
               lv,
               "#pair-recording-postponed[data-confirm][phx-value-acknowledged='missing_results_recorded_as_adjourned']"
             )

      lv |> element("#pair-recording-postponed") |> render_click()
      render(lv)

      assert Tournaments.get_round(t.id, 2)
      assert Repo.reload!(open).result == "*"
      assert has_element?(lv, "#postponed-game-#{open.id}")

      assert Enum.any?(
               Audit.list_for_tournament(t.id),
               &(&1.action == "pairing.missing_recorded_postponed")
             )
    end

    test "pairing with a postponed game from an older round asks first (Q168)", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      [postponed, other] = boards(t, 1)
      set!(postponed, "*")
      set!(other, "1-0")
      {:ok, _} = Engine.pair_next_round(Tournaments.get_tournament!(t.id))
      for p <- boards(t, 2), p.black_player_id, do: set!(p, "1-0")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      lv |> element(".round-picker button[phx-value-number='3']") |> render_click()

      assert has_element?(
               lv,
               "#pair-round[data-confirm][phx-value-acknowledged='adjourned_older_round_open']"
             )

      refute has_element?(lv, "#pair-recording-postponed")
    end

    test "a postponed game in the last round is noted beside the pair button", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      [postponed, other] = boards(t, 1)
      set!(postponed, "*")
      set!(other, "1-0")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      lv |> element(".round-picker button[phx-value-number='2']") |> render_click()

      assert has_element?(lv, "#postponed-counted-as-draw")
      refute has_element?(lv, "#pair-round[disabled]")
      refute has_element?(lv, "#pair-round[data-confirm]")
    end
  end

  describe "the Standings page (Q161, Q169)" do
    test "says not final while a game is postponed, and nothing once it is played", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      [postponed, other] = boards(t, 1)
      set!(postponed, "*")
      set!(other, "1-0")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/standings")
      assert has_element?(lv, "#postponed-not-final")

      set!(postponed, "1/2-1/2")
      render(lv)

      refute has_element?(lv, "#postponed-not-final")
    end
  end

  describe "printed standings" do
    test "carry the not-final banner while a game is postponed", %{conn: conn, scope: scope} do
      t = tournament(scope)
      [postponed, other] = boards(t, 1)
      set!(postponed, "*")
      set!(other, "1-0")

      banner = fn ->
        conn
        |> get(~p"/t/#{t.id}/print/standings")
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#postponed-not-final")
        |> Enum.count()
      end

      assert banner.() == 1

      set!(postponed, "0-1", acknowledged: [:adjourned_non_draw_result])

      assert banner.() == 0
    end
  end

  describe "sending the TRF" do
    test "finalising on download marks the round, and a second try is refused", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      [postponed, other] = boards(t, 1)
      set!(postponed, "*B")
      set!(other, "1-0")

      sent = post(conn, ~p"/t/#{t.id}/export/trf", %{"rounds" => "1", "finalise" => "true"})
      assert response(sent, 200) =~ "?"
      assert %{finalised_open: true} = Repo.reload!(postponed)
      assert %{finalised_open: false, finalised_at: %DateTime{}} = Repo.reload!(other)

      again = post(conn, ~p"/t/#{t.id}/export/trf", %{"rounds" => "1", "finalise" => "true"})
      assert redirected_to(again) == ~p"/t/#{t.id}/settings/export"
      assert Phoenix.Flash.get(again.assigns.flash, :error) =~ "twice"

      # A copy, not finalised, can always be downloaded.
      copy = post(conn, ~p"/t/#{t.id}/export/trf", %{"rounds" => "1", "finalise" => "false"})
      assert response(copy, 200) =~ "?"

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/export")
      assert has_element?(lv, "#trf-sent-rounds")

      {:ok, pairings, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      assert has_element?(pairings, "#postponed-page-link")
    end

    test "changing a sent result asks first, and the confirmation writes it", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      [first, second] = boards(t, 1)
      set!(first, "1-0")
      set!(second, "1-0")
      post(conn, ~p"/t/#{t.id}/export/trf", %{"rounds" => "1", "finalise" => "true"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      change_result(lv, first, "0-1")

      assert has_element?(lv, "#confirm-finalised-#{first.id}")
      assert Repo.reload!(first).result == "1-0"

      lv |> element("#confirm-postponed-yes-#{first.id}") |> render_click()

      assert Repo.reload!(first).result == "0-1"
      [entry | _] = Audit.list_for_tournament(t.id)
      assert entry.details["confirmed"] == "finalised_result_changed"
    end

    test "the postponed-games page lists the game and sends its file once", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      [postponed, other] = boards(t, 1)
      set!(postponed, "*W")
      set!(other, "1-0")
      post(conn, ~p"/t/#{t.id}/export/trf", %{"rounds" => "1", "finalise" => "true"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/postponed")
      assert has_element?(lv, "#postponed-row-#{postponed.id}")
      assert has_element?(lv, "#postponed-trf-empty")

      set!(Repo.reload!(postponed), "1/2-1/2")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/postponed")
      assert has_element?(lv, "#postponed-trf-round-1")

      file = post(conn, ~p"/t/#{t.id}/export/postponed-trf", %{"finalise" => "true"})
      assert response(file, 200) =~ "001"
      assert Repo.reload!(postponed).postponed_reported_at

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/postponed")
      assert has_element?(lv, "#postponed-trf-empty")
    end

    test "going back past a sent round warns loudly and needs its own tick", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      {:ok, before} = PairingsEngine.Snapshots.capture(t, "manual", scope)
      for p <- boards(t, 1), do: set!(p, "1-0")
      post(conn, ~p"/t/#{t.id}/export/trf", %{"rounds" => "1", "finalise" => "true"})
      assert {:error, :round_sent_in_trf} = Engine.delete_round(t.id, 1)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/history")
      render_click(lv, "restore_start", %{"id" => to_string(before.id)})

      assert has_element?(lv, "#restore-sent-warning")
      render_change(lv, "restore_confirm_input", %{"confirm" => "RESTORE", "sent_ack" => "false"})
      assert has_element?(lv, "#restore-confirm-form button[type=submit][disabled]")

      # Without the tick nothing happens, even with the word typed.
      render_submit(lv, "restore_confirmed", %{"confirm" => "RESTORE", "sent_ack" => "false"})
      assert Enum.all?(boards(t, 1), &(&1.result == "1-0"))

      render_change(lv, "restore_confirm_input", %{"confirm" => "RESTORE", "sent_ack" => "true"})
      render_submit(lv, "restore_confirmed", %{"confirm" => "RESTORE", "sent_ack" => "true"})

      # Back to the blank round - still marked as sent.
      assert Enum.all?(boards(t, 1), &(&1.result == "" and &1.finalised_at))
      [entry | _] = Audit.list_for_tournament(t.id)
      assert entry.action == "snapshot.restored"
      assert entry.details["sent_games_changed"] == 2
    end

    test "changing who plays whom in a sent round is blocked behind its own warning", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      [first, second] = boards(t, 1)
      set!(first, "1-0")
      set!(second, "1-0")
      post(conn, ~p"/t/#{t.id}/export/trf", %{"rounds" => "1", "finalise" => "true"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      render_click(lv, "arm_swap", %{"player-id" => to_string(first.white_player_id)})
      render_click(lv, "pick_swap_target", %{"player-id" => to_string(second.white_player_id)})

      assert has_element?(lv, "#confirm-sent-round")
      assert has_element?(lv, ".pe-modal-go[disabled]")

      # Refused server-side too.
      render_click(lv, "apply_confirm", %{})
      assert Repo.reload!(first).white_player_id == first.white_player_id

      render_click(lv, "toggle_sent_ack", %{})
      refute has_element?(lv, ".pe-modal-go[disabled]")
      render_click(lv, "apply_confirm", %{})

      assert Repo.reload!(first).white_player_id == second.white_player_id
      [entry | _] = Audit.list_for_tournament(t.id)
      assert entry.action == "pairing.players_swapped"
      assert entry.details["confirmed"] == "sent_round_changed"
      # Still sent: it is never sent a second time.
      assert {:error, {:already_sent, [1]}} =
               PairingsEngine.PostponedGames.finalise(Tournaments.get_tournament!(t.id), [1])
    end

    test "every seat change in a sent round is refused without the acknowledgement", %{
      scope: scope
    } do
      t = tournament(scope)
      [first, second] = boards(t, 1)
      set!(first, "1-0")
      set!(second, "1-0")
      {:ok, _} = PairingsEngine.PostponedGames.finalise(t, [1])
      round = Tournaments.get_round(t.id, 1)
      refused = {:error, {:needs_acknowledgement, [:sent_round_changed]}}

      assert refused ==
               Tournaments.swap_players_in_round(
                 round,
                 first.white_player_id,
                 second.white_player_id
               )

      assert refused == Tournaments.vacate_seat(round, first.white_player_id)

      assert refused ==
               Tournaments.swap_seated_with_pool_player(round, first.white_player_id, 0)

      assert refused == Tournaments.award_bye_for_vacancy(round, first)
      assert refused == Tournaments.fill_seat(round, first, first.white_player_id)

      assert refused ==
               Tournaments.pair_from_pool(round, first.white_player_id, second.white_player_id, 9)
    end

    test "an absence edited on the Players page in a sent round needs its own tick", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      for p <- boards(t, 1), do: set!(p, "1-0")
      post(conn, ~p"/t/#{t.id}/export/trf", %{"rounds" => "1", "finalise" => "true"})
      player = Enum.find(Tournaments.list_players(t.id), &(&1.name == "Alice"))

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
      render_click(lv, "edit_player", %{"id" => to_string(player.id)})
      refute has_element?(lv, "#player-sent-absence")

      lv
      |> element("#player-edit-form")
      |> render_change(%{"player" => %{"absent_rounds" => "1"}})

      assert has_element?(lv, "#player-sent-absence")
      assert has_element?(lv, "#player-edit-save[disabled]")

      # Refused server-side without the tick.
      lv
      |> element("#player-edit-form")
      |> render_submit(%{"player" => %{"absent_rounds" => "1"}})

      assert Repo.reload!(player).absent_rounds == ""
      assert has_element?(lv, "#player-sent-absence")

      lv
      |> element("#player-edit-form")
      |> render_submit(%{"player" => %{"absent_rounds" => "1", "sent_ack" => "true"}})

      assert Repo.reload!(player).absent_rounds == "1"
      [entry | _] = Audit.list_for_tournament(t.id)
      assert entry.action == "player.updated"
      assert entry.details["confirmed"] == "sent_round_changed"

      # Still sent: it is never sent a second time.
      assert {:error, {:already_sent, [1]}} =
               PairingsEngine.PostponedGames.finalise(Tournaments.get_tournament!(t.id), [1])
    end

    test "an absence in a round not sent needs no tick", %{scope: scope} do
      t = tournament(scope)
      for p <- boards(t, 1), do: set!(p, "1-0")
      {:ok, _} = PairingsEngine.PostponedGames.finalise(t, [1])
      player = hd(Tournaments.list_players(t.id))

      assert [] = Tournaments.sent_absence_rounds(player, %{"absent_rounds" => "2-3"})

      assert {:ok, %{absent_rounds: "2,3"}} =
               Tournaments.update_player(player, %{"absent_rounds" => "2-3"}, [])

      assert {:error, {:needs_acknowledgement, [:sent_round_changed]}} =
               Tournaments.update_player(Repo.reload!(player), %{"absent_rounds" => "1-3"}, [])

      assert {:ok, %{absent_rounds: "1,2,3"}} =
               Tournaments.update_player(Repo.reload!(player), %{"absent_rounds" => "1-3"},
                 acknowledged: [:sent_round_changed]
               )
    end
  end

  describe "players the sent-games record cannot tell apart" do
    # Two "Jan Peeters" with no FIDE ID, told apart only by case and spaces.
    defp with_namesakes(scope) do
      t = tournament(scope)
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => "Jan Peeters"})
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => " jan peeters"})
      t
    end

    test "are found the way the record compares names, FIDE IDs aside", %{scope: scope} do
      t = with_namesakes(scope)

      {:ok, _} =
        Tournaments.create_player(t.id, %{"name" => "Eve", "fide_id" => "1000001"})

      {:ok, _} =
        Tournaments.create_player(t.id, %{"name" => "Eve", "fide_id" => "1000002"})

      assert [%{key: "name:jan peeters", count: 2}] =
               PairingsEngine.PostponedGames.ambiguous_players(t.id)

      # Nobody of them has a sent game yet.
      assert [] = PairingsEngine.PostponedGames.ambiguous_sent_players(t.id)
    end

    test "warn beside sending, and sending notes it in the audit trail", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/export")
      refute has_element?(lv, "#sent-games-ambiguous-players")

      t = with_namesakes(scope) |> then(&Tournaments.get_tournament!(&1.id))
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/export")
      assert has_element?(lv, "#sent-games-ambiguous-players", "Jan Peeters")

      for p <- boards(t, 1), do: set!(p, "1-0")
      file = post(conn, ~p"/t/#{t.id}/export/trf", %{"rounds" => "1", "finalise" => "true"})
      assert response(file, 200) =~ "001"

      [entry | _] = Audit.list_for_tournament(t.id)
      assert entry.action == "trf.finalised"
      assert entry.details["ambiguous_players"] == ["Jan Peeters"]
    end

    test "warn after a restore re-applies marks to their sent games", %{
      conn: conn,
      scope: scope
    } do
      t = with_namesakes(scope)
      # Pair round 1 again so the namesakes are in it.
      :ok = Engine.delete_round(t.id, 1)
      {:ok, _} = Engine.pair_next_round(Tournaments.get_tournament!(t.id))
      t = Tournaments.get_tournament!(t.id)
      {:ok, point} = PairingsEngine.Snapshots.capture(t, "manual", scope)
      for p <- boards(t, 1), do: set!(p, "1-0")
      {:ok, _} = PairingsEngine.PostponedGames.finalise(t, [1])

      assert [%{key: "name:jan peeters"}] =
               PairingsEngine.PostponedGames.ambiguous_sent_players(t.id)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/history")
      render_click(lv, "restore_start", %{"id" => to_string(point.id)})
      render_change(lv, "restore_confirm_input", %{"confirm" => "RESTORE", "sent_ack" => "true"})

      html =
        render_submit(lv, "restore_confirmed", %{"confirm" => "RESTORE", "sent_ack" => "true"})

      [entry | _] = Audit.list_for_tournament(t.id)
      assert entry.action == "snapshot.restored"
      assert entry.details["ambiguous_players"] == ["Jan Peeters"]
      assert html =~ "Jan Peeters"
    end
  end

  describe "the outside-checker note" do
    test "says a downloaded TRF cannot reproduce the pairing when a postponed game is not a draw",
         %{conn: conn, scope: scope} do
      t = tournament(scope)

      {:ok, t} =
        Tournaments.update_tournament(t, %{"postponed_requester_outcome" => "win"})

      [board | _] = boards(t, 1)
      set!(board, "*W")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/export")
      assert has_element?(lv, "#postponed-trf-outside-checkers")
    end

    test "with postponed games off, no postponed result is offered", %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, _} = Tournaments.update_tournament(t, %{"postponed_games" => "false"})
      [board | _] = boards(t, 1)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      refute has_element?(lv, "#result-select-#{board.id} option[value='*W']")
      refute has_element?(lv, "#result-select-#{board.id} option[value='*B']")
      refute has_element?(lv, "#postponed-page-link")
    end
  end

  describe "the phone" do
    test "a deputy is sent to the Pairings page for a decisive result on a postponed game", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      [postponed | _] = boards(t, 1)
      set!(postponed, "*")

      {:ok, enrollment} = Mobile.create_enrollment(t.id, level: "deputy")
      conn = init_test_session(conn, %{mobile_enrollment_id: enrollment.id})
      {:ok, lv, _html} = live(conn, ~p"/m/results")

      render_click(lv, "set_result", %{"id" => to_string(postponed.id), "result" => "1-0"})

      assert has_element?(lv, "#flash-error", "was postponed")
      assert Repo.reload!(postponed).result == "*"
    end
  end
end
