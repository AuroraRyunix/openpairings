defmodule PairingsEngineWeb.RatingInboxLiveTest do
  @moduledoc """
  The rating period inbox: admin only, per rating period what was sent,
  what is missing, the list each goes to (normal, a later list, not rated),
  the file as sent (or a labelled copy for an old receipt) and the check.

  Generated data only: no .swar fixtures, no real players.
  """
  use PairingsEngineWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias PairingsEngine.{Accounts, Repo, SentReceipts, Tournaments}
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.{SentReceipt, Tournament}

  setup :register_and_log_in_user

  setup %{conn: conn, user: user} do
    {:ok, admin} = Accounts.set_role(user.email, "admin")
    {:ok, conn: log_in_user(conn, admin), user: admin}
  end

  defp tournament(scope, name) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => name,
        "type" => "swiss",
        "start_date" => "2026-09-01",
        "rounds_count" => "3",
        "round_dates" => ["2026-09-01", "2026-09-08", "2026-09-15"],
        "tiebreaks" => ["BH", "SB"]
      })

    for {n, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1800}, {"Dave", 1700}] do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => n, "fide_rating" => "#{rating}"})
    end

    {:ok, _} = Engine.pair_next_round(t)
    t = Tournaments.get_tournament!(t.id)

    for p <- Tournaments.get_round(t.id, 1).pairings do
      {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
    end

    t
  end

  defp send!(conn, t) do
    send_with_body!(conn, t) |> elem(0)
  end

  defp send_with_body!(conn, t) do
    sent = post(conn, ~p"/t/#{t.id}/export/trf", %{"rounds" => "1", "finalise" => "true"})
    {Repo.one!(from r in SentReceipt, where: r.tournament_id == ^t.id), response(sent, 200)}
  end

  test "an ordinary account is sent away", %{conn: conn, user: user} do
    {:ok, plain} = Accounts.set_role(user.email, "owner")
    conn = log_in_user(conn, plain)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/rating-inbox")
  end

  test "a sent round is listed under its period", %{conn: conn, scope: scope} do
    t = tournament(scope, "Inbox sent")
    receipt = send!(conn, t)

    {:ok, view, _html} = live(conn, ~p"/admin/rating-inbox")

    assert has_element?(view, "#rating-inbox-period-2026-09")
    assert has_element?(view, "#rating-inbox-2026-09-t#{t.id}")
    assert has_element?(view, "#rating-inbox-receipt-#{receipt.id}", receipt.code)
    refute has_element?(view, "#rating-inbox-drift-#{receipt.id}")
  end

  test "a finished round of a FIDE-rated tournament with no receipt is missing", %{
    conn: conn,
    scope: scope
  } do
    t = tournament(scope, "Inbox missing")
    Repo.update_all(from(x in Tournament, where: x.id == ^t.id), set: [fide_homologated: true])

    {:ok, view, _html} = live(conn, ~p"/admin/rating-inbox")

    assert has_element?(view, "#rating-inbox-missing-#{t.id}-2026-09")
    assert has_element?(view, "#rating-inbox-list-#{t.id}-2026-09")
  end

  describe "the list a missing report goes to (B.02 Art. 9.1)" do
    setup %{scope: scope} do
      t = tournament(scope, "Inbox lists")
      Repo.update_all(from(x in Tournament, where: x.id == ^t.id), set: [fide_homologated: true])
      {:ok, t: t}
    end

    defp level(t, today) do
      period =
        Enum.find(PairingsEngine.RatingInbox.periods(today), fn p ->
          Enum.any?(p.tournaments, &(&1.tournament.id == t.id))
        end)

      bucket = Enum.find(period.tournaments, &(&1.tournament.id == t.id))
      {period.level, bucket.report_list}
    end

    test "in time for the month's list: normal", %{t: t} do
      assert {:normal, %{list: ~D[2026-10-01], closes: ~D[2026-09-30]}} =
               level(t, ~D[2026-09-20])
    end

    test "after it closed: a later list, amber", %{t: t, conn: conn} do
      assert {:later, %{lands_in: lands_in}} = level(t, ~D[2026-10-05])
      assert lands_in == ~D[2026-11-01]

      {:ok, view, _html} = live(conn, ~p"/admin/rating-inbox")
      assert has_element?(view, "#rating-inbox-list-#{t.id}-2026-09[data-level]")
    end

    test "past the third list: will not be rated, red", %{t: t} do
      assert {:late, %{lands_in: nil}} = level(t, ~D[2027-01-05])
    end
  end

  describe "a long event reported once at the end" do
    setup %{scope: scope} do
      t = tournament(scope, "Inbox long")

      Repo.update_all(from(x in Tournament, where: x.id == ^t.id),
        set: [
          fide_homologated: true,
          long_event: true,
          round_dates: ["2026-09-01", "2026-10-20", "2026-12-15"]
        ]
      )

      {:ok, t: t}
    end

    test "monthly: September's round is overdue by November", %{t: t} do
      assert {:later, %{basis: :interim}} = level(t, ~D[2026-11-10])
    end

    test "at the end: counted from the last day, nothing overdue before it", %{t: t} do
      Repo.update_all(from(x in Tournament, where: x.id == ^t.id),
        set: [long_event_reporting: "end"]
      )

      assert {:normal, %{basis: :final, list: ~D[2027-01-01], closes: ~D[2026-12-31]}} =
               level(t, ~D[2026-11-10])

      refute Enum.any?(PairingsEngine.RatingInbox.periods(~D[2026-11-10]), & &1.overdue?)
    end
  end

  describe "which tournaments are listed" do
    test "not marked FIDE-rated and nothing sent: not listed, finished round or not", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope, "Inbox club evening")

      {:ok, view, _html} = live(conn, ~p"/admin/rating-inbox")

      refute has_element?(view, "#rating-inbox-2026-09-t#{t.id}")
      refute has_element?(view, "#rating-inbox-missing-#{t.id}-2026-09")
    end

    test "not marked FIDE-rated but sent once: its receipt, and no round called missing", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope, "Inbox sent once")
      receipt = send!(conn, t)

      {:ok, _} = Engine.pair_next_round(Tournaments.get_tournament!(t.id))

      for p <- Tournaments.get_round(t.id, 2).pairings do
        {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
      end

      {:ok, view, _html} = live(conn, ~p"/admin/rating-inbox")

      assert has_element?(view, "#rating-inbox-receipt-#{receipt.id}")
      assert has_element?(view, "#rating-inbox-unrated-#{t.id}-2026-09")
      refute has_element?(view, "#rating-inbox-missing-#{t.id}-2026-09")
      refute has_element?(view, "#rating-inbox-list-#{t.id}-2026-09")
    end

    test "marked FIDE-rated: the unsent finished round is missing, with its list", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope, "Inbox rated")
      Repo.update_all(from(x in Tournament, where: x.id == ^t.id), set: [fide_homologated: true])

      {:ok, view, _html} = live(conn, ~p"/admin/rating-inbox")

      assert has_element?(view, "#rating-inbox-missing-#{t.id}-2026-09")
      assert has_element?(view, "#rating-inbox-list-#{t.id}-2026-09[data-basis=final]")
      refute has_element?(view, "#rating-inbox-unrated-#{t.id}-2026-09")
    end
  end

  describe "the way in" do
    test "an administrator has it in the account menu and on the admin page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "#account-menu-rating-inbox[href='/admin/rating-inbox']")
      assert has_element?(view, "#admin-rating-inbox-link[href='/admin/rating-inbox']")
    end

    test "an ordinary account has no link to it anywhere", %{conn: conn, user: user, scope: scope} do
      t = tournament(scope, "Inbox no door")
      {:ok, plain} = Accounts.set_role(user.email, "owner")
      conn = log_in_user(conn, plain)

      {:ok, home, _html} = live(conn, ~p"/")
      refute has_element?(home, "#account-menu-rating-inbox")

      {:ok, export, _html} = live(conn, ~p"/t/#{t.id}/settings/export")
      assert has_element?(export, "#trf-send-note")
      refute has_element?(export, "#account-menu-rating-inbox")
      refute has_element?(export, "#rating-inbox-link")
    end

    test "on a tournament's Export page it is a small link, not a button", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope, "Inbox small door")

      {:ok, export, _html} = live(conn, ~p"/t/#{t.id}/settings/export")

      assert has_element?(
               export,
               "#trf-send-note a#rating-inbox-link[href='/admin/rating-inbox']"
             )

      refute has_element?(export, "#rating-inbox-link.pe-btn")
    end
  end

  describe "downloading is not sending" do
    test "the page says so under the Send button", %{conn: conn, scope: scope} do
      t = tournament(scope, "Inbox not delivered")

      {:ok, export, _html} = live(conn, ~p"/t/#{t.id}/settings/export")

      assert has_element?(export, "#trf-send-note", "Downloading is not sending")
      assert has_element?(export, "#trf-send-note", "to your rating officer yourself")
    end

    test "the confirmation says so before anything is recorded", %{conn: conn, scope: scope} do
      t = tournament(scope, "Inbox confirm")

      {:ok, export, _html} = live(conn, ~p"/t/#{t.id}/settings/export")
      # The finished round arrives ticked; the confirmation is on the button
      # as soon as there is something to send.

      assert has_element?(export, "#trf-send[data-confirm*='Downloading is not sending']")
      assert has_element?(export, "#trf-send[data-confirm*='to your rating officer yourself']")
    end

    test "after a send the page repeats it, with the receipt", %{conn: conn, scope: scope} do
      t = tournament(scope, "Inbox reminder")

      {:ok, export, _html} = live(conn, ~p"/t/#{t.id}/settings/export")
      receipt = send!(conn, t)
      _ = :sys.get_state(export.pid)

      assert has_element?(export, "#flash-info", receipt.code)
      assert has_element?(export, "#flash-info", "Nothing has reached your rating officer yet")
    end
  end

  test "a report already sent is not late any more", %{conn: conn, scope: scope} do
    t = tournament(scope, "Inbox sent in time")
    send!(conn, t)

    period =
      PairingsEngine.RatingInbox.periods(~D[2027-01-05])
      |> Enum.find(fn p -> Enum.any?(p.tournaments, &(&1.tournament.id == t.id)) end)

    assert period.level == :normal
    refute period.overdue?
  end

  test "a round changed since it was sent is flagged", %{conn: conn, scope: scope} do
    t = tournament(scope, "Inbox drift")
    receipt = send!(conn, t)
    [board | _] = Tournaments.get_round(t.id, 1).pairings

    {:ok, _} =
      Tournaments.update_pairing_result(board, "0-1", acknowledged: [:finalised_result_changed])

    {:ok, view, _html} = live(conn, ~p"/admin/rating-inbox")
    assert has_element?(view, "#rating-inbox-drift-#{receipt.id}")
  end

  test "the TRF copy downloads and the check reports", %{conn: conn, scope: scope} do
    t = tournament(scope, "Inbox check")
    {receipt, body} = send_with_body!(conn, t)

    # The file that was sent, not a rebuilt copy.
    download = get(conn, ~p"/admin/rating-inbox/receipts/#{receipt.id}/trf")
    assert response(download, 200) == body
    refute body =~ "COPY - NOT FOR RATING"
    assert [disposition] = get_resp_header(download, "content-disposition")
    assert disposition =~ receipt.file_name
    refute disposition =~ "COPY"

    {:ok, view, _html} = live(conn, ~p"/admin/rating-inbox")
    assert has_element?(view, "#rating-inbox-download-#{receipt.id}", "Download file")

    view |> element("#rating-inbox-check-#{receipt.id}") |> render_click()
    render_async(view, 30_000)
    assert has_element?(view, "#rating-inbox-result-#{receipt.id}")
  end

  test "a receipt without a stored file still offers a copy, labelled as one", %{
    conn: conn,
    scope: scope
  } do
    t = tournament(scope, "Inbox old receipt")
    receipt = send!(conn, t)

    Repo.update_all(from(r in SentReceipt, where: r.id == ^receipt.id),
      set: [file: nil, file_name: nil, file_size: nil]
    )

    copy = get(conn, ~p"/admin/rating-inbox/receipts/#{receipt.id}/trf")
    assert response(copy, 200) =~ "COPY - NOT FOR RATING"
    assert [disposition] = get_resp_header(copy, "content-disposition")
    assert disposition =~ "COPY-NOT-FOR-RATING"

    {:ok, view, _html} = live(conn, ~p"/admin/rating-inbox")
    assert has_element?(view, "#rating-inbox-download-#{receipt.id}", "Download TRF copy")
  end

  test "a postponed-games file that was sent can be downloaded and checked", %{
    conn: conn,
    scope: scope
  } do
    t = tournament(scope, "Inbox postponed file")
    receipt = send!(conn, t)

    file = SentReceipts.file(receipt)

    {:ok, late} =
      %SentReceipt{}
      |> Ecto.Changeset.change(%{
        tournament_id: t.id,
        kind: "postponed",
        period: ~D[2026-09-01],
        code: "P·TEST",
        status: "receipt",
        origin: "sent",
        sent_at: ~U[2026-10-01 10:00:00Z],
        file: file,
        file_size: byte_size(file),
        file_name: "late.trf"
      })
      |> Repo.insert()

    {:ok, view, _html} = live(conn, ~p"/admin/rating-inbox")
    assert has_element?(view, "#rating-inbox-download-#{late.id}")
    view |> element("#rating-inbox-check-#{late.id}") |> render_click()
    render_async(view, 30_000)
    assert has_element?(view, "#rating-inbox-result-#{late.id}")
  end

  test "a send that no longer exists says so, in the page and at the download", %{
    conn: conn,
    scope: scope
  } do
    t = tournament(scope, "Inbox vanished")
    receipt = send!(conn, t)

    {:ok, view, _html} = live(conn, ~p"/admin/rating-inbox")
    PairingsEngine.Repo.delete!(receipt)

    view |> render_hook("check", %{"id" => to_string(receipt.id)})
    assert render(view) =~ "This send no longer exists"

    gone = get(conn, ~p"/admin/rating-inbox/receipts/#{receipt.id}/trf")
    assert redirected_to(gone) == ~p"/admin/rating-inbox"
    assert Phoenix.Flash.get(gone.assigns.flash, :error) =~ "no longer exists"
  end

  test "the download is for administrators only", %{conn: conn, scope: scope, user: user} do
    t = tournament(scope, "Inbox gate")
    receipt = send!(conn, t)

    {:ok, plain} = Accounts.set_role(user.email, "owner")
    denied = get(log_in_user(conn, plain), ~p"/admin/rating-inbox/receipts/#{receipt.id}/trf")
    assert response(denied, 403)
  end
end
