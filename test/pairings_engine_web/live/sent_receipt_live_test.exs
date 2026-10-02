defmodule PairingsEngineWeb.SentReceiptLiveTest do
  @moduledoc """
  The sent receipt where people see it: the stamp on a sent round (the
  Pairings page and Settings, Export), the red warning when the round
  changed since, the receipt line in the file "Send…" hands out and the
  copy line in a copy, the code in the audit trail, and the Dutch words.

  Generated data only: no .swar fixtures, no real players.
  """
  use PairingsEngineWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, SentReceipts, Tournaments}
  alias PairingsEngine.Audit.AuditLog
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.SentReceipt
  alias PairingsEngineWeb.AuditLive
  alias PairingsEngineWeb.SentReceipt, as: Words

  setup :register_and_log_in_user

  defp tournament(scope) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Receipt open",
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
    t = Tournaments.get_tournament!(t.id)

    for p <- Tournaments.get_round(t.id, 1).pairings do
      {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
    end

    t
  end

  defp send!(conn, t) do
    sent = post(conn, ~p"/t/#{t.id}/export/trf", %{"rounds" => "1", "finalise" => "true"})
    [receipt] = Repo.all(from r in SentReceipt, where: r.tournament_id == ^t.id)
    {response(sent, 200), receipt}
  end

  test "the file sent carries its receipt line, and parses", %{conn: conn, scope: scope} do
    t = tournament(scope)
    {text, receipt} = send!(conn, t)

    assert receipt.code =~ ~r/^R1·[0-9A-F]{4}$/
    assert receipt.sent_by
    assert text =~ "### SENT FOR RATING. Receipt #{SentReceipts.file_code(receipt.code)}: round 1"
    assert %{players: [_, _, _, _]} = Ainalrami.Trf.parse(text)

    copy = get(conn, ~p"/t/#{t.id}/export/trf?rounds=1")
    assert response(copy, 200) =~ "### Round 1: copy of #{SentReceipts.file_code(receipt.code)}"
  end

  test "a round not sent says so in a copy", %{conn: conn, scope: scope} do
    t = tournament(scope)
    copy = get(conn, ~p"/t/#{t.id}/export/trf")
    assert response(copy, 200) =~ "### Round 1: never sent."
  end

  test "the Export page and the Pairings page show the stamp, and the drift in red", %{
    conn: conn,
    scope: scope
  } do
    t = tournament(scope)
    {_text, receipt} = send!(conn, t)

    {:ok, export, _html} = live(conn, ~p"/t/#{t.id}/settings/export")
    assert has_element?(export, "#trf-receipt-1", receipt.code)
    refute has_element?(export, "#trf-receipt-drift-#{receipt.id}")

    {:ok, pairings, _html} = live(conn, ~p"/t/#{t.id}/pairings?round=1")
    assert has_element?(pairings, "#round-receipt", receipt.code)
    refute has_element?(pairings, "#round-receipt-drift")

    [board | _] = Tournaments.get_round(t.id, 1).pairings

    {:ok, _} =
      Tournaments.update_pairing_result(board, "0-1", acknowledged: [:finalised_result_changed])

    {:ok, export, _html} = live(conn, ~p"/t/#{t.id}/settings/export")
    assert has_element?(export, "#trf-receipt-drift-#{receipt.id}", "Changed since sent")
    assert has_element?(export, "#trf-receipt-drift-#{receipt.id}-change-0", "now 0-1")
    assert has_element?(export, "#trf-round-1.is-changed")

    {:ok, pairings, _html} = live(conn, ~p"/t/#{t.id}/pairings?round=1")
    assert has_element?(pairings, "#round-receipt-drift", receipt.code)
    assert has_element?(pairings, "#round-receipt-drift-change-0", "sent as 1-0")
  end

  test "the audit trail names the receipt", %{conn: conn, scope: scope} do
    t = tournament(scope)
    {_text, receipt} = send!(conn, t)

    row =
      Repo.one!(
        from a in AuditLog, where: a.tournament_id == ^t.id and a.action == "trf.finalised"
      )

    assert row.details["receipts"] == [receipt.code]
    assert AuditLive.describe(row.action, row.details) =~ "Receipt #{receipt.code}."

    # A row written before receipts reads as it always did.
    refute AuditLive.describe("trf.finalised", %{"rounds" => [1], "marked" => 2}) =~ "Receipt"
  end

  test "the words are Dutch in Dutch" do
    receipt = %SentReceipt{
      code: "R5·7F2A",
      sent_at: ~U[2026-10-03 14:02:00Z],
      status: "receipt",
      kind: "report",
      round: 5
    }

    Gettext.with_locale(PairingsEngineWeb.Gettext, "nl", fn ->
      assert Words.stamp_text(receipt) =~ "Verstuurd 03-10-2026 14:02 UTC · R5·7F2A"
      assert Words.drift_title(receipt) =~ "Gewijzigd na verzending (R5·7F2A)"

      assert Words.code_text(%{receipt | code: nil}) == "verstuurd vóór de verzendbewijzen"
    end)

    assert Words.stamp_text(receipt) == "Sent 03-10-2026 14:02 UTC · R5·7F2A"

    assert Words.drift_title(receipt) ==
             "Changed since sent (R5·7F2A) — the rating body has the old version"
  end
end
