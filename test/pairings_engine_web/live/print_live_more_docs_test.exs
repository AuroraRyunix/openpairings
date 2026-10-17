defmodule PairingsEngineWeb.PrintLiveMoreDocsTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.Tournaments

  setup :register_and_log_in_user

  test "place cards and the next round preview are on the Print page", %{
    conn: conn,
    scope: scope
  } do
    {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Print More", "type" => "swiss"})
    {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/print")

    assert has_element?(lv, "#print-doc-placecards a[href='/t/#{t.id}/print/placecards']")
    assert has_element?(lv, "#print-doc-next-round-preview")
    # Nothing worked out yet, so nothing to print and no link pretending otherwise.
    refute has_element?(lv, "#print-doc-next-round-preview a")
  end
end
