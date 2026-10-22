defmodule PairingsEngineWeb.UndoWhileUnplayedLiveTest do
  @moduledoc """
  The Pairings page's ways back while nothing is decided: discarding a
  round's hand edits (and the restore point their session opens with),
  drawing a Chess960 position again, unpairing a round robin's whole
  schedule - and a swap of rounds that is refused leaving no restore point.
  Also the live round lighting the Pairings tab.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias PairingsEngine.{Audit, Pairing, Repo, RoundRobin, Snapshots, Tournaments}

  setup :register_and_log_in_user

  defp swiss(scope, names, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(
          %{
            "name" => "Undo",
            "type" => "swiss",
            "start_date" => "2026-07-15",
            "rounds_count" => "3",
            "round_dates" => List.duplicate("2026-07-15", 3),
            "tiebreaks" => ["BH", "SB"],
            "chief_arbiter" => "Jane Arbiter",
            "federation" => "BEL",
            "rate_of_play" => "90 min + 30 sec/move"
          },
          attrs
        )
      )

    players =
      for {name, i} <- Enum.with_index(names) do
        {:ok, p} = Tournaments.create_player(t.id, %{name: name, fide_rating: 2000 - 50 * i})
        p
      end

    {Repo.reload!(t), players}
  end

  defp round_robin(scope) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Undo round robin",
        "type" => "roundrobin",
        "pairing_system" => "round_robin",
        "rounds_count" => "3"
      })

    for {name, i} <- Enum.with_index(~w(Ann Ben Cas Dan)) do
      {:ok, _} = Tournaments.create_player(t.id, %{name: name, fide_rating: 2000 - 50 * i})
    end

    {:ok, _} = RoundRobin.pair_all_rounds(Repo.reload!(t))
    Repo.reload!(t)
  end

  defp boards(t, n) do
    Tournaments.get_round(t.id, n).pairings
    |> Enum.map(&{&1.id, &1.board, &1.white_player_id, &1.black_player_id, &1.result})
    |> Enum.sort()
  end

  defp byes(t, n) do
    Repo.all(
      from b in "byes",
        where: b.tournament_id == ^t.id and b.round == ^n,
        select: {b.player_id, b.type}
    )
  end

  defp snapshots(t, trigger),
    do: t.id |> Snapshots.list() |> Enum.filter(&(&1.trigger == trigger))

  describe "discarding hand edits" do
    test "puts the boards and the not-playing list back, ends the session, and is logged",
         %{conn: conn, scope: scope} do
      {t, [ann, _ben, cas, dan]} = swiss(scope, ~w(Ann Ben Cas Dan))
      {:ok, _} = Pairing.pair_next_round(t)
      before = boards(t, 1)
      byes_before = byes(t, 1)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      refute has_element?(lv, "#mpa-discard")

      # Two hand edits: a swap, then a seat emptied (a bye row for Ann).
      render_click(lv, "arm_swap", %{"player-id" => to_string(cas.id)})
      render_click(lv, "pick_swap_target", %{"player-id" => to_string(dan.id)})
      render_click(lv, "apply_confirm", %{})
      render_click(lv, "stage_vacate", %{"player-id" => to_string(ann.id)})
      render_click(lv, "apply_confirm", %{})

      assert boards(t, 1) != before
      assert {ann.id, "absent"} in byes(t, 1)

      # The session opened with a restore point of the round before them.
      assert [_] = snapshots(t, "pairing.mpa_started")

      assert has_element?(lv, "#mpa-banner #mpa-discard[data-confirm]")
      lv |> element("#mpa-discard") |> render_click()

      assert boards(t, 1) == before
      assert byes(t, 1) == byes_before
      round = Tournaments.get_round(t.id, 1)
      assert round.mpa_session == nil
      assert round.mpa_pibe == nil
      refute has_element?(lv, "#mpa-banner")

      assert [%{details: %{"round" => 1}}] =
               Audit.list_for_tournament(t.id, action: "pairing.mpa_discarded")
    end

    test "a session started from the More menu takes its restore point too",
         %{conn: conn, scope: scope} do
      {t, _} = swiss(scope, ~w(Ann Ben Cas Dan))
      {:ok, _} = Pairing.pair_next_round(t)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      lv |> element("#mpa-start-1") |> render_click()
      assert [_] = snapshots(t, "pairing.mpa_started")
      assert has_element?(lv, "#mpa-discard")
    end

    test "is not offered once the round has a result", %{conn: conn, scope: scope} do
      {t, _} = swiss(scope, ~w(Ann Ben Cas Dan))
      {:ok, _} = Pairing.pair_next_round(t)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      lv |> element("#mpa-start-1") |> render_click()

      [p | _] = Tournaments.get_round(t.id, 1).pairings
      {:ok, _} = Tournaments.update_pairing_result(p, "1-0")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      assert has_element?(lv, "#mpa-banner")
      refute has_element?(lv, "#mpa-discard")

      # And refused when sent anyway.
      render_click(lv, "mpa_discard", %{})
      assert Tournaments.get_round(t.id, 1).mpa_session
      assert Audit.list_for_tournament(t.id, action: "pairing.mpa_discarded") == []
    end
  end

  describe "Chess960" do
    defp chess960(scope) do
      {t, _} = swiss(scope, ~w(Ann Ben Cas Dan))
      {:ok, t} = Tournaments.update_tournament(t, %{chess960: true})
      {:ok, _} = Pairing.pair_next_round(t)
      {:ok, _} = PairingsEngine.Chess960.draw_for_round(t, 1, fn -> 518 end)
      Repo.reload!(t)
    end

    test "the position is drawn again while the round has no results, and logged",
         %{conn: conn, scope: scope} do
      t = chess960(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      assert has_element?(lv, "#redraw-chess960[data-confirm]")
      lv |> element("#redraw-chess960") |> render_click()

      assert [%{details: %{"round" => 1, "previous" => 518, "position" => position}}] =
               Audit.list_for_tournament(t.id, action: "pairing.chess960_redrawn")

      assert Tournaments.get_round(t.id, 1).chess960_position == position
    end

    test "not once a game has a result", %{conn: conn, scope: scope} do
      t = chess960(scope)
      [p | _] = Tournaments.get_round(t.id, 1).pairings
      {:ok, _} = Tournaments.update_pairing_result(p, "1-0")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      refute has_element?(lv, "#redraw-chess960")

      assert {:error, :has_results} = PairingsEngine.Chess960.redraw_for_round(t, 1)
      assert Tournaments.get_round(t.id, 1).chess960_position == 518
    end
  end

  describe "unpairing a round robin's whole schedule" do
    test "deletes every round after a restore point, logged, with a flash",
         %{conn: conn, scope: scope} do
      t = round_robin(scope)

      numbers =
        Repo.all(
          from p in PairingsEngine.Tournaments.Player,
            where: p.tournament_id == ^t.id,
            select: p.pairing_number
        )

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      assert has_element?(lv, "#rr-unpair-schedule[data-confirm]")
      html = lv |> element("#rr-unpair-schedule") |> render_click()

      assert Pairing.paired_rounds_count(t.id) == 0
      assert Repo.all(from b in "byes", where: b.tournament_id == ^t.id, select: b.id) == []

      # The Berger table's numbers stay.
      assert Repo.all(
               from p in PairingsEngine.Tournaments.Player,
                 where: p.tournament_id == ^t.id,
                 select: p.pairing_number
             ) == numbers

      assert [_] = snapshots(t, "pairing.round_deleted")

      assert [%{details: %{"rounds" => 3}}] =
               Audit.list_for_tournament(t.id, action: "pairing.schedule_unpaired")

      assert html =~ "3 rounds were unpaired"
    end

    test "not while any round has a result", %{conn: conn, scope: scope} do
      t = round_robin(scope)
      [p | _] = Tournaments.get_round(t.id, 1).pairings
      {:ok, _} = Tournaments.update_pairing_result(p, "1-0")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      refute has_element?(lv, "#rr-unpair-schedule")

      render_click(lv, "rr_unpair_schedule", %{})
      assert Pairing.paired_rounds_count(t.id) == 3
      assert snapshots(t, "pairing.round_deleted") == []
    end

    test "a Swiss has no such button", %{conn: conn, scope: scope} do
      {t, _} = swiss(scope, ~w(Ann Ben Cas Dan))
      {:ok, _} = Pairing.pair_next_round(t)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      refute has_element?(lv, "#rr-unpair-schedule")
    end
  end

  test "a refused swap of rounds leaves no restore point", %{conn: conn, scope: scope} do
    t = round_robin(scope)
    [p | _] = Tournaments.get_round(t.id, 2).pairings
    {:ok, _} = Tournaments.update_pairing_result(p, "1-0")

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    lv |> element("#rr-swap-open") |> render_click()
    lv |> form("#rr-swap-form", swap: %{a: "2", b: "3"}) |> render_submit()

    assert has_element?(lv, "#rr-swap-error")
    assert snapshots(t, "pairing.rounds_swapped") == []
  end

  test "the live round lights the Pairings tab", %{conn: conn, scope: scope} do
    {t, _} = swiss(scope, ~w(Ann Ben))
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/live")
    assert has_element?(lv, ~s(a[href="/t/#{t.id}/pairings"][aria-current="page"]))
  end
end
