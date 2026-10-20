defmodule PairingsEngineWeb.PairingSlotsLiveTest do
  @moduledoc """
  The Pairings page under `PairingsEngine.EngineSlots`: a tournament that
  is already being paired - from another tab, or a co-arbiter's - is not
  paired a second time, and the page says why instead of pretending.
  """
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{EngineSlots, Tournaments}

  setup :register_and_log_in_user

  defp tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(
          %{
            "name" => "Slots Open",
            "type" => "swiss",
            "start_date" => "2026-07-01",
            "rounds_count" => "5",
            "round_dates" => List.duplicate("2026-07-01", 5),
            "tiebreaks" => ["BH", "SB"],
            "chief_arbiter" => "Jane Arbiter",
            "federation" => "BEL",
            "rate_of_play" => "90 min + 30 sec/move"
          },
          attrs
        )
      )

    for {name, rating} <- [{"A", 2000}, {"B", 1900}, {"C", 1800}, {"D", 1700}] do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name, "fide_rating" => "#{rating}"})
    end

    t
  end

  # Somebody else's run of the same tournament, holding its lock until told.
  defp hold_lock(tournament_id) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:held, EngineSlots.request(:pairing, tournament_id)})

        receive do
          :go -> :ok
        end
      end)

    assert_receive {:held, {:ok, _ref}}
    pid
  end

  defp let_go(pid) do
    ref = Process.monitor(pid)
    send(pid, :go)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  test "an individual Swiss being paired elsewhere is refused, then pairs once free", %{
    conn: conn,
    scope: scope
  } do
    t = tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

    other = hold_lock(t.id)
    html = render_click(lv, "pair", %{})

    assert html =~ "already being paired"
    assert Tournaments.list_rounds(t.id) == []

    let_go(other)
    render_click(lv, "pair", %{})
    assert [_round] = Tournaments.list_rounds(t.id)
  end
end
