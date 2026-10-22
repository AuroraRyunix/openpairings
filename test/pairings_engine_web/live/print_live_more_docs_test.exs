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

    # ... and the disabled button says why, which is not "no rounds paired".
    assert has_element?(
             lv,
             "#print-doc-next-round-preview button[title*='Work out the preview']"
           )
  end

  test "the page follows the tournament while it is open", %{conn: conn, scope: scope} do
    {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Before", "type" => "swiss"})
    {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/print")
    assert render(lv) =~ "Before"

    t |> Ecto.Changeset.change(name: "After") |> PairingsEngine.Repo.update!()
    Tournaments.broadcast_tournament_change(t.id, :settings)

    assert render(lv) =~ "After"
  end
end
