defmodule PairingsEngineWeb.AnnouncedBoardsLiveTest do
  @moduledoc """
  Announced boards on the Pairings page: announcing from the preview (and
  by printing), the strip for the round about to be paired, the warning
  when something changes and "Check again", and the comparison once the
  round is paired - a warning nobody can miss when a board differs, a quiet
  line when they all hold. Ainalrami only, so no JVM.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias PairingsEngine.{BoardAnnouncements, NextRoundPreview, Repo, Tournaments}
  alias PairingsEngine.Audit.AuditLog
  alias PairingsEngine.Pairing, as: Engine

  setup [:register_and_log_in_user]

  setup %{user: user} do
    {:ok, _} = PairingsEngine.Features.set_enabled(user, ["next_round_preview"])
    Application.put_env(:pairings_engine, :next_round_preview_debounce_ms, 0)
    NextRoundPreview.Memo.clear()

    on_exit(fn ->
      Application.delete_env(:pairings_engine, :next_round_preview_debounce_ms)
    end)
  end

  # Two rounds played, the third paired, its last board still open.
  defp tournament(scope) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Announce",
        "type" => "swiss",
        "start_date" => "2026-07-01",
        "rounds_count" => "5",
        "round_dates" => List.duplicate("2026-07-01", 5),
        "tiebreaks" => ["BH", "SB"],
        "chief_arbiter" => "Jane Arbiter",
        "federation" => "BEL",
        "rate_of_play" => "90 min + 30 sec/move"
      })

    for i <- 1..24 do
      {:ok, _} =
        Tournaments.create_player(t.id, %{
          "name" => "Player #{String.pad_leading(to_string(i), 2, "0")}",
          "fide_rating" => to_string(2300 - i * 10)
        })
    end

    for _ <- 1..2 do
      {:ok, round} = Engine.pair_next_round(Tournaments.get_tournament!(t.id))

      for p <- Repo.preload(round, :pairings).pairings, p.black_player_id do
        {:ok, _} =
          Tournaments.update_pairing_result(p, Enum.at(~w(1-0 1/2-1/2 0-1), rem(p.board, 3)))
      end
    end

    {:ok, round} = Engine.pair_next_round(Tournaments.get_tournament!(t.id))
    games = round |> Repo.preload(:pairings) |> Map.get(:pairings)
    games = games |> Enum.filter(& &1.black_player_id) |> Enum.sort_by(& &1.board)
    {open, decided} = List.pop_at(games, -1)
    Enum.each(decided, &({:ok, _} = Tournaments.update_pairing_result(&1, "1-0")))
    {t, open, decided}
  end

  defp open_preview(conn, t) do
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    lv |> element("#next-round-preview-open") |> render_click()
    render_async(lv, 30_000)
    assert has_element?(lv, "#next-round-preview-announce")
    lv
  end

  defp audit_actions(t) do
    Repo.all(from a in AuditLog, where: a.tournament_id == ^t.id, select: a.action)
  end

  test "announcing the fixed boards shows them for the next round, in the audit trail too",
       %{conn: conn, scope: scope} do
    {t, _open, _decided} = tournament(scope)
    lv = open_preview(conn, t)
    refute has_element?(lv, "#announced-boards")

    lv |> element("#next-round-preview-announce") |> render_click()

    assert has_element?(lv, "#announced-boards", "Round 4")
    assert has_element?(lv, "#announced-boards-list tbody tr")
    refute has_element?(lv, "#announcement-changed")
    assert "pairing.boards_announced" in audit_actions(t)
  end

  test "printing announces them when the box is ticked, and not when it is not",
       %{conn: conn, scope: scope} do
    {t, _open, _decided} = tournament(scope)
    lv = open_preview(conn, t)
    assert has_element?(lv, "#next-round-preview-announce-on-print-box[checked]")

    lv |> element("#next-round-preview-announce-on-print-box") |> render_click()
    refute has_element?(lv, "#next-round-preview-announce-on-print-box[checked]")
    lv |> element("#next-round-preview-print") |> render_click()
    refute has_element?(lv, "#announced-boards")

    lv |> element("#next-round-preview-announce-on-print-box") |> render_click()
    lv |> element("#next-round-preview-print") |> render_click()
    assert has_element?(lv, "#announced-boards")

    [entry] = Repo.all(from a in AuditLog, where: a.action == "pairing.boards_announced")
    assert entry.details["via"] == "print"
  end

  test "something changing after the announcement is said, and Check again answers it",
       %{conn: conn, scope: scope} do
    {t, _open, [decided | _]} = tournament(scope)
    lv = open_preview(conn, t)
    lv |> element("#next-round-preview-announce") |> render_click()
    lv |> element("#next-round-preview-close") |> render_click()

    render_click(lv, "result", %{"pairing-id" => to_string(decided.id), "result" => "0-1"})
    assert has_element?(lv, "#announcement-changed")

    lv |> element("#announcement-check") |> render_click()
    render_async(lv, 30_000)

    refute has_element?(lv, "#announcement-changed")

    assert has_element?(lv, "#announcement-check-ok") or
             has_element?(lv, "#announcement-uncertain")

    assert "pairing.announcement_checked" in audit_actions(t)
  end

  test "a result entered for the open game is no change at all", %{conn: conn, scope: scope} do
    {t, open, _decided} = tournament(scope)
    lv = open_preview(conn, t)
    lv |> element("#next-round-preview-announce") |> render_click()

    render_click(lv, "result", %{"pairing-id" => to_string(open.id), "result" => "1/2-1/2"})
    assert has_element?(lv, "#announced-boards")
    refute has_element?(lv, "#announcement-changed")
  end

  test "withdrawn", %{conn: conn, scope: scope} do
    {t, _open, _decided} = tournament(scope)
    lv = open_preview(conn, t)
    lv |> element("#next-round-preview-announce") |> render_click()

    lv |> element("#announcement-withdraw") |> render_click()
    refute has_element?(lv, "#announced-boards")
    assert BoardAnnouncements.pending(t.id) == nil
    assert "pairing.announcement_withdrawn" in audit_actions(t)
  end

  test "paired as announced: a quiet confirmation", %{conn: conn, scope: scope} do
    {t, open, _decided} = tournament(scope)
    lv = open_preview(conn, t)
    lv |> element("#next-round-preview-announce") |> render_click()

    render_click(lv, "result", %{"pairing-id" => to_string(open.id), "result" => "0-1"})
    render_click(lv, "pair", %{})

    assert has_element?(lv, "#announced-hold")
    refute has_element?(lv, "#announced-mismatch-dialog")
    refute has_element?(lv, "#announced-changed")
    assert "pairing.announcement_compared" in audit_actions(t)
  end

  test "paired differently: the unmissable warning, until acknowledged - and the pairing stands",
       %{conn: conn, scope: scope} do
    {t, open, _decided} = tournament(scope)
    lv = open_preview(conn, t)
    lv |> element("#next-round-preview-announce") |> render_click()

    # What was announced, as if the cards had gone out for another board.
    [first | _] = BoardAnnouncements.pending(t.id).boards
    Repo.update!(Ecto.Changeset.change(first, label: "99"))

    render_click(lv, "result", %{"pairing-id" => to_string(open.id), "result" => "0-1"})
    render_click(lv, "pair", %{})

    assert has_element?(lv, "#announced-mismatch-dialog")
    assert has_element?(lv, "#announced-mismatch-#{first.id}", "99")
    assert has_element?(lv, "#announced-changed")

    paired = Tournaments.get_round(t.id, 4).pairings
    assert Enum.all?(paired, &(&1.display_board != "99"))

    # Closed without acknowledging: the banner stays.
    lv |> element("#announced-mismatch-close") |> render_click()
    refute has_element?(lv, "#announced-mismatch-dialog")
    assert has_element?(lv, "#announced-changed")

    lv |> element("#announcement-acknowledge") |> render_click()
    refute has_element?(lv, "#announced-changed")
    assert has_element?(lv, "#announced-changed-ack")
    assert "pairing.announcement_acknowledged" in audit_actions(t)

    [compared] = Repo.all(from a in AuditLog, where: a.action == "pairing.announcement_compared")
    assert [%{"changes" => ["board"]}] = compared.details["changed"]
  end

  test "unpaired and paired again: compared again", %{conn: conn, scope: scope} do
    {t, open, _decided} = tournament(scope)
    lv = open_preview(conn, t)
    lv |> element("#next-round-preview-announce") |> render_click()
    [first | _] = BoardAnnouncements.pending(t.id).boards
    Repo.update!(Ecto.Changeset.change(first, label: "99"))

    render_click(lv, "result", %{"pairing-id" => to_string(open.id), "result" => "0-1"})
    render_click(lv, "pair", %{})
    lv |> element("#announced-mismatch-acknowledge") |> render_click()
    refute has_element?(lv, "#announced-changed")

    render_click(lv, "unpair", %{})
    assert has_element?(lv, "#announced-boards")

    render_click(lv, "pair", %{})
    assert has_element?(lv, "#announced-mismatch-dialog")
    assert has_element?(lv, "#announced-changed")
  end
end
