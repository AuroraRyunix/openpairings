defmodule PairingsEngineWeb.FideLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.Repo
  alias PairingsEngine.Kbsb.KbsbPlayer

  setup :register_and_log_in_user

  test "renders both the FIDE and KBSB sections under the 'Rating lists' heading", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/fide")

    assert html =~ "Rating lists</h1>"
    assert html =~ "FIDE database"
    assert html =~ "Belgian national rating list (KBSB/FRBE)"
    assert html =~ "players in the local database."
  end

  test "the nav label reads 'Rating lists', not 'FIDE database'", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/fide")

    assert html =~ ~s(href="/fide")
    assert html =~ "Rating lists"
  end

  test "the KBSB import form is a file upload, not a plain sync button", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/fide")

    assert html =~ ~s(id="kbsb-import-form")
    assert html =~ "Import file"
  end

  test "submitting the KBSB import form with no file chosen shows an error instead of crashing",
       %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/fide")

    html = render_submit(lv, "import_kbsb", %{})

    assert html =~ "Choose a file first"
  end

  test "searching the local KBSB database returns matches", %{conn: conn} do
    Repo.insert!(%KbsbPlayer{
      national_id: "12345",
      last_name: "Peeters",
      first_name: "Jan",
      national_rating: 1850,
      club_number: 42,
      club_name: "KSK Antwerpen",
      federation: "VSF",
      birth_year: 1990
    })

    {:ok, lv, _html} = live(conn, ~p"/fide")

    html = render_change(lv, "kbsb_search", %{"q" => "Peet"})

    assert html =~ "Peeters"
    assert html =~ "KSK Antwerpen"
  end

  test "an unknown KBSB search query returns no results", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/fide")

    html = render_change(lv, "kbsb_search", %{"q" => "Nobody"})

    refute html =~ "kbsb-result-row"
  end
end
