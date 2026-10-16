defmodule PairingsEngineWeb.RoundSwapLiveTest do
  @moduledoc """
  The Pairings page's "Swap rounds…" for a round robin
  (`PairingsEngine.RoundSwap`): the dialog, the swap and its audit row, and
  the refusal shown in the dialog. The rules are `PairingsEngine.RoundSwapTest`.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Audit, Repo, RoundRobin, Tournaments}

  setup :register_and_log_in_user

  defp paired_rr(scope) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Swapped round robin",
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

  test "two rounds swapped from the dialog, with an audit row", %{conn: conn, scope: scope} do
    t = paired_rr(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

    lv |> element("#rr-swap-open") |> render_click()
    assert has_element?(lv, "#rr-swap-dialog")

    lv |> form("#rr-swap-form", swap: %{a: "1", b: "3"}) |> render_submit()
    refute has_element?(lv, "#rr-swap-dialog")

    assert Repo.reload!(t).rr_round_map == [3, 2, 1]

    assert [%{details: %{"rounds" => [1, 3], "table_rounds" => [3, 1]}}] =
             Audit.list_for_tournament(t.id, action: "pairing.rounds_swapped")
  end

  test "a round with a result is refused in the dialog", %{conn: conn, scope: scope} do
    t = paired_rr(scope)
    [p | _] = Tournaments.get_round(t.id, 2).pairings
    {:ok, _} = Tournaments.update_pairing_result(p, "1-0")

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    lv |> element("#rr-swap-open") |> render_click()
    lv |> form("#rr-swap-form", swap: %{a: "2", b: "3"}) |> render_submit()

    assert has_element?(lv, "#rr-swap-error")
    assert Repo.reload!(t).rr_round_map == nil
  end

  test "a Swiss has no swap", %{conn: conn, scope: scope} do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Swiss",
        "type" => "swiss",
        "rounds_count" => "5"
      })

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    refute has_element?(lv, "#rr-swap-open")
  end
end
