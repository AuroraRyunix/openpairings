defmodule PairingsEngineWeb.PairingsLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Round, Pairing}

  setup :register_and_log_in_user

  defp fixture(scope) do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Pairings Print Test", "type" => "swiss", "rounds_count" => "3"})

    [a, b] =
      for {name, rating} <- [{"A", 2000}, {"B", 1800}] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name, fide_rating: rating})
      end

    r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})
    r2 = Repo.insert!(%Round{tournament_id: tournament.id, number: 2, status: "finished"})

    Repo.insert!(%Pairing{round_id: r1.id, board: 1, white_player_id: a.id, black_player_id: b.id, result: "1-0"})
    Repo.insert!(%Pairing{round_id: r2.id, board: 1, white_player_id: b.id, black_player_id: a.id, result: "1-0"})

    tournament
  end

  test "print pairings/standings links open the currently selected round in a new tab", %{
    conn: conn,
    scope: scope
  } do
    tournament = fixture(scope)

    {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    # Two rounds are paired, so the view defaults to the latest one (round 2).
    assert html =~ ~s(href="/t/#{tournament.id}/print/pairings?round=2")
    assert html =~ ~s(href="/t/#{tournament.id}/print/standings?round=2")
    assert html =~ ~s(target="_blank")

    html = lv |> element("button[phx-value-number='1']") |> render_click()

    assert html =~ ~s(href="/t/#{tournament.id}/print/pairings?round=1")
    assert html =~ ~s(href="/t/#{tournament.id}/print/standings?round=1")
  end

  test "no print links are shown for an unpaired round", %{conn: conn, scope: scope} do
    tournament = fixture(scope)

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    html = lv |> element("button[phx-value-number='3']") |> render_click()

    refute html =~ ~s(print/pairings?round=3)
    refute html =~ ~s(print/standings?round=3)
  end

  test "shows a public pairings link pointing at the tournament's public slug", %{conn: conn, scope: scope} do
    tournament = fixture(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    assert tournament.public_slug
    assert html =~ ~s(href="/p/#{tournament.public_slug}/pairings")
    assert html =~ "Public pairings link"
  end

  test "shows a PGN export link for the currently selected round", %{conn: conn, scope: scope} do
    tournament = fixture(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    assert html =~ ~s(href="/t/#{tournament.id}/export/pgn?round=2")
    assert html =~ "Export PGN"
  end

  test "shows a fixed-board annotation next to the board number", %{conn: conn, scope: scope} do
    tournament = fixture(scope)
    player_a = Repo.get_by!(Player, tournament_id: tournament.id, name: "A")
    Repo.update!(Ecto.Changeset.change(player_a, fixed_board: 7))

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    assert html =~ "(table 7)"
  end

  ## ---------- CSV results import ----------

  defp import_fixture(scope) do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Import Test", "type" => "swiss", "rounds_count" => "2"})

    [a, b, c, d] =
      for name <- ["A", "B", "C", "D"] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name})
      end

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})
    Repo.insert!(%Pairing{round_id: round.id, board: 1, white_player_id: a.id, black_player_id: b.id, result: ""})
    Repo.insert!(%Pairing{round_id: round.id, board: 2, white_player_id: c.id, black_player_id: d.id, result: ""})

    tournament
  end

  test "the import panel is hidden until the toggle button is clicked", %{conn: conn, scope: scope} do
    tournament = import_fixture(scope)

    {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")
    refute html =~ "results-csv-import-form"

    html = lv |> element("button", "Import results (CSV)") |> render_click()
    assert html =~ "results-csv-import-form"
  end

  test "importing a valid CSV writes results and shows a success flash", %{conn: conn, scope: scope} do
    tournament = import_fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    lv |> element("button", "Import results (CSV)") |> render_click()

    csv =
      file_input(lv, "#results-csv-import-form", :results_csv, [
        %{name: "results.csv", content: "1,1-0\n2,0-1\n", type: "text/csv"}
      ])

    render_upload(csv, "results.csv")
    html = lv |> form("#results-csv-import-form", %{}) |> render_submit()

    assert html =~ "Imported 2 results."

    round = Tournaments.get_round(tournament.id, 1)
    assert Enum.find(round.pairings, &(&1.board == 1)).result == "1-0"
    assert Enum.find(round.pairings, &(&1.board == 2)).result == "0-1"

    # A successful import writes results, which broadcasts on the
    # tournament's PubSub topic — this LiveView is subscribed to its own
    # topic, so drain that message before the test process exits.
    render(lv)
  end

  test "an invalid CSV shows per-line errors and writes nothing (all-or-nothing)", %{conn: conn, scope: scope} do
    tournament = import_fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    lv |> element("button", "Import results (CSV)") |> render_click()

    csv =
      file_input(lv, "#results-csv-import-form", :results_csv, [
        %{name: "results.csv", content: "1,1-0\n99,0-1\n", type: "text/csv"}
      ])

    render_upload(csv, "results.csv")
    html = lv |> form("#results-csv-import-form", %{}) |> render_submit()

    assert html =~ "Nothing was saved"
    assert html =~ "board 99"

    round = Tournaments.get_round(tournament.id, 1)
    assert Enum.find(round.pairings, &(&1.board == 1)).result == ""
  end

  ## ---------- Setup-completion gate ----------

  test "pairing is blocked, with a banner, when the tournament is missing a start date", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "No Start Date", "type" => "swiss"})

    Repo.insert!(%Player{tournament_id: tournament.id, name: "A"})
    Repo.insert!(%Player{tournament_id: tournament.id, name: "B"})

    {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    assert html =~ "Finish the tournament setup"
    assert html =~ ~s(href="/t/#{tournament.id}/settings")

    button = lv |> element("button", "Pair round")
    assert render(button) =~ "disabled"

    html = render_click(lv, "pair", %{})
    assert html =~ "Finish the tournament setup"
    refute Tournaments.get_round(tournament.id, 1)
  end

  test "pairing is allowed once the tournament setup is complete", %{conn: conn, scope: scope} do
    tournament = complete_setup_tournament(scope)

    {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    refute html =~ "Finish the tournament setup"

    button = lv |> element("button", "Pair round")
    refute render(button) =~ "disabled"
  end

  # Only this half of the setup-gate coverage actually runs the pairing, which
  # shells out to javafo.jar — the gate assertions above stay untagged so they
  # keep running where the (gitignored) jar isn't present, e.g. CI.
  @tag :javafo
  test "pairing with a complete setup creates the round", %{conn: conn, scope: scope} do
    tournament = complete_setup_tournament(scope)

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    render_click(lv, "pair", %{})

    # do_pair writes the round/pairings and broadcasts on the tournament's
    # topic, which this `lv` is subscribed to — drain the self-broadcast
    # before teardown (same race as the CSV import test above).
    render(lv)

    assert Tournaments.get_round(tournament.id, 1)
  end

  defp complete_setup_tournament(scope) do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Complete Setup",
        "type" => "swiss",
        "start_date" => "2026-07-15",
        "rounds_count" => "2"
      })

    Repo.insert!(%Player{tournament_id: tournament.id, name: "A"})
    Repo.insert!(%Player{tournament_id: tournament.id, name: "B"})

    tournament
  end
end
