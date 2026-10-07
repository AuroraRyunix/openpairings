defmodule PairingsEngineWeb.RatingInboxLiveTest do
  @moduledoc """
  The rating period inbox: admin only, per rating period what was sent,
  what is missing, the deadline, the TRF copy and the check.

  Generated data only: no .swar fixtures, no real players.
  """
  use PairingsEngineWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias PairingsEngine.{Accounts, Repo, Tournaments}
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
    post(conn, ~p"/t/#{t.id}/export/trf", %{"rounds" => "1", "finalise" => "true"})
    Repo.one!(from r in SentReceipt, where: r.tournament_id == ^t.id)
  end

  test "an ordinary account is sent away", %{conn: conn, user: user} do
    {:ok, plain} = Accounts.set_role(user.email, "owner")
    conn = log_in_user(conn, plain)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/rating-inbox")
  end

  test "a sent round is listed under its period with the deadline", %{conn: conn, scope: scope} do
    t = tournament(scope, "Inbox sent")
    receipt = send!(conn, t)

    {:ok, view, _html} = live(conn, ~p"/admin/rating-inbox")

    assert has_element?(view, "#rating-inbox-period-2026-09")
    assert has_element?(view, "#rating-inbox-2026-09-t#{t.id}")
    assert has_element?(view, "#rating-inbox-receipt-#{receipt.id}", receipt.code)
    assert has_element?(view, "#rating-inbox-period-2026-09", "30-09-2026")
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
    receipt = send!(conn, t)

    copy = get(conn, ~p"/admin/rating-inbox/receipts/#{receipt.id}/trf")
    assert response(copy, 200) =~ "COPY - NOT FOR RATING"

    {:ok, view, _html} = live(conn, ~p"/admin/rating-inbox")
    assert has_element?(view, "#rating-inbox-download-#{receipt.id}")

    view |> element("#rating-inbox-check-#{receipt.id}") |> render_click()
    render_async(view, 30_000)
    assert has_element?(view, "#rating-inbox-result-#{receipt.id}")
  end

  test "the download is for administrators only", %{conn: conn, scope: scope, user: user} do
    t = tournament(scope, "Inbox gate")
    receipt = send!(conn, t)

    {:ok, plain} = Accounts.set_role(user.email, "owner")
    denied = get(log_in_user(conn, plain), ~p"/admin/rating-inbox/receipts/#{receipt.id}/trf")
    assert response(denied, 403)
  end
end
