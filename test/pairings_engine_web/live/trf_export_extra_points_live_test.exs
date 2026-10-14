defmodule PairingsEngineWeb.TrfExportExtraPointsLiveTest do
  @moduledoc """
  The Export page's line under the TRF downloads for extra points a TRF has
  no record for: points that neither count in the standings nor reach the
  pairing (`TrfExport.export_notes/1`). Points that do either are written
  and come back, and get no line.
  """
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Pairing, Tournaments}

  setup :register_and_log_in_user

  defp tournament(scope, attrs) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(
          %{
            "name" => "Extra points",
            "type" => "swiss",
            "start_date" => "2026-07-01",
            "rounds_count" => "5",
            "round_dates" => List.duplicate("2026-07-01", 5),
            "tiebreaks" => ["BH", "SB"],
            "chief_arbiter" => "Jane Arbiter",
            "federation" => "BEL"
          },
          attrs
        )
      )

    for i <- 1..6 do
      {:ok, _} =
        Tournaments.create_player(t.id, %{
          "name" => "P#{i}",
          "fide_rating" => 2000 - i * 10,
          "extra_points" => if(i == 6, do: 1.0, else: 0.0)
        })
    end

    {:ok, _} = Pairing.pair_next_round(Tournaments.get_tournament!(t.id))
    t
  end

  test "a handicap the tournament does not count is said to stay behind", %{
    conn: conn,
    scope: scope
  } do
    t = tournament(scope, %{"count_extra_points" => false})
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/export")

    assert has_element?(lv, "#trf-export-note-0", "1 player holds extra points")
  end

  test "points that count are in the file, and nothing is said", %{conn: conn, scope: scope} do
    t = tournament(scope, %{"count_extra_points" => true})
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/export")

    refute has_element?(lv, "#trf-export-note-0")
  end

  test "acceleration points reach the pairing, and nothing is said", %{
    conn: conn,
    scope: scope
  } do
    t = tournament(scope, %{"extra_points_mode" => "acceleration"})
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/export")

    refute has_element?(lv, "#trf-export-note-0")
  end
end
