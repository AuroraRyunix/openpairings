defmodule PairingsEngineWeb.RatingCorrectionLiveTest do
  @moduledoc """
  The Pairings page's correction for the rating report only (C.04.2:4.3,
  VCL4THP Q192): offered on the boards of a round whose next round is over,
  recorded beside the board's own result, which stays. The rules are
  `PairingsEngine.RatingCorrectionTest`.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Audit, Pairing, Repo, Tournaments}

  setup :register_and_log_in_user

  defp played_event(scope, rounds_played) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Rating correction",
        "type" => "swiss",
        "start_date" => "2026-07-15",
        "rounds_count" => "4",
        "round_dates" => List.duplicate("2026-07-15", 4),
        "tiebreaks" => ["BH", "SB"],
        "chief_arbiter" => "Jane Arbiter",
        "federation" => "BEL",
        "rate_of_play" => "90 min + 30 sec/move"
      })

    for {name, i} <- Enum.with_index(~w(Ann Ben Cas Dan)) do
      {:ok, _} =
        Tournaments.create_player(t.id, %{
          tournament_id: t.id,
          name: name,
          fide_rating: 2000 - 50 * i
        })
    end

    for _ <- 1..rounds_played do
      {:ok, round} = Pairing.pair_next_round(Repo.reload!(t))

      for p <- Tournaments.get_round(t.id, round.number).pairings, p.black_player_id do
        {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
      end
    end

    Repo.reload!(t)
  end

  test "a round whose next round is over: corrected for rating, the board keeps its result",
       %{conn: conn, scope: scope} do
    t = played_event(scope, 3)
    pairing = hd(Tournaments.get_round(t.id, 1).pairings)

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

    # The last round played offers nothing of the kind.
    render_click(lv, "select_round", %{"number" => "3"})
    refute has_element?(lv, "[id^=rating-fix-open-]")

    render_click(lv, "select_round", %{"number" => "1"})
    lv |> element("#rating-fix-open-#{pairing.id}") |> render_click()
    assert has_element?(lv, "#rating-fix-hint-#{pairing.id}")

    lv
    |> form("#rating-fix-form-#{pairing.id}", %{"rating_result" => "0-1"})
    |> render_submit()

    assert has_element?(lv, "#rating-fix-badge-#{pairing.id}", "0-1")

    updated = Repo.get!(PairingsEngine.Tournaments.Pairing, pairing.id)
    assert updated.result == "1-0"
    assert updated.rating_result == "0-1"

    assert "pairing.rating_correction" in (t.id
                                           |> Audit.list_for_tournament()
                                           |> Enum.map(& &1.action))
  end
end
