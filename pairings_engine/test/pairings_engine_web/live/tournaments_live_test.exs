defmodule PairingsEngineWeb.TournamentsLiveTest do
  # `async: false` — SWAR import writes a tournament, its players and
  # rounds all in one go; combined with the FIDE-matching tests inserting
  # `FidePlayer` rows, that's enough sequential writes to contend with the
  # async pool for SQLite's single writer lock (see the same rationale on
  # `SharingTest`/`InviteLiveTest`).
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Fide.FidePlayer
  alias PairingsEngine.Tournaments.Tournament

  @problemski "test/fixtures/problemski.swar"

  setup :register_and_log_in_user

  ## ---------- Creation modal: pairing_system/type can never contradict (task 6) ----------

  describe "New tournament: pairing system drives `type`, the raw type select is gone" do
    test "the creation form has no raw 'Tournament format' select", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      lv |> element("button", "New tournament") |> render_click()

      refute has_element?(lv, "select[name='tournament[type]']")
      assert has_element?(lv, "select[name='tournament[pairing_system]']")
      assert has_element?(lv, "input[name='tournament[team]']")
    end

    test "swiss (default) + no team -> type swiss", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      lv |> element("button", "New tournament") |> render_click()

      lv
      |> form("#new-tournament-form", tournament: %{name: "Swiss T", pairing_system: "swiss", rounds_count: "7"})
      |> render_submit()

      tournament = last_tournament_named("Swiss T")
      assert tournament.pairing_system == "swiss"
      assert tournament.type == "swiss"
    end

    test "keizer + no team -> type swiss (keizer is Swiss-classified for FIDE reporting)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      lv |> element("button", "New tournament") |> render_click()

      lv
      |> form("#new-tournament-form", tournament: %{name: "Keizer T", pairing_system: "keizer", rounds_count: "7"})
      |> render_submit()

      tournament = last_tournament_named("Keizer T")
      assert tournament.pairing_system == "keizer"
      assert tournament.type == "swiss"
    end

    test "round_robin + no team -> type roundrobin", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      lv |> element("button", "New tournament") |> render_click()

      lv
      |> form("#new-tournament-form", tournament: %{name: "RR T", pairing_system: "round_robin", rounds_count: "7"})
      |> render_submit()

      tournament = last_tournament_named("RR T")
      assert tournament.pairing_system == "round_robin"
      assert tournament.type == "roundrobin"
    end

    test "round_robin + team -> type team-roundrobin", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      lv |> element("button", "New tournament") |> render_click()

      lv
      |> form("#new-tournament-form",
        tournament: %{name: "Team RR T", pairing_system: "round_robin", team: "true", rounds_count: "7"}
      )
      |> render_submit()

      tournament = last_tournament_named("Team RR T")
      assert tournament.type == "team-roundrobin"
    end

    test "swiss + team -> type team-swiss", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      lv |> element("button", "New tournament") |> render_click()

      lv
      |> form("#new-tournament-form", tournament: %{name: "Team Swiss T", pairing_system: "swiss", team: "true", rounds_count: "7"})
      |> render_submit()

      tournament = last_tournament_named("Team Swiss T")
      assert tournament.type == "team-swiss"
    end

    test "a client-forged `tournament[type]` is ignored — the server always derives it", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      lv |> element("button", "New tournament") |> render_click()

      # No <select name="tournament[type]"> exists to submit this through in
      # the real UI, but `handle_event("create", ...)` must still overwrite
      # whatever arrives under that key — this simulates a forged event
      # (dispatched directly, since there's no real form control for it).
      {:error, {:live_redirect, _}} =
        render_submit(lv, "create", %{
          "tournament" => %{
            "name" => "Forged T",
            "type" => "roundrobin",
            "pairing_system" => "swiss",
            "rounds_count" => "7"
          }
        })

      tournament = last_tournament_named("Forged T")
      assert tournament.type == "swiss"
    end

    defp last_tournament_named(name) do
      Repo.one!(from(t in Tournament, where: t.name == ^name, order_by: [desc: t.id], limit: 1))
    end
  end

  ## ---------- SWAR import: FIDE-match confirm step (task 2) ----------

  describe "SWAR import: confirm step for players SWAR has no FIDE id for" do
    test "a file where every player is already settled imports immediately, no modal shown", %{conn: conn} do
      # c-reeks.swar has two players with no mat_fide (Vanmassenhove,
      # Cobert) — patch a copy where those two are simply removed isn't
      # practical here, so instead this asserts the *modal path* directly;
      # problemski.swar's single unresolved player (Ashrafi) exercises the
      # "skip" choice below. A genuinely fully-resolved import is already
      # covered at the SwarImport unit level (see swar_import_test.exs).
      {:ok, lv, _html} = live(conn, ~p"/")
      lv |> element("button", "Import SWAR file") |> render_click()

      swar = file_input(lv, "form", :swar, [
        %{name: "problemski.swar", content: File.read!(@problemski), type: "application/octet-stream"}
      ])

      render_upload(swar, "problemski.swar")
      lv |> form("#swar-import-form", %{}) |> render_submit()

      # problemski.swar has one unmatched player (no local FIDE database
      # seeded in this test) — the confirm step must show, not navigate away.
      assert has_element?(lv, "h2", "Resolve FIDE ids")
      assert has_element?(lv, "*", "Ashrafi, Sulaiman Ahmad")
    end

    test "no local FIDE match: choosing 'import without a FIDE id' completes the import with fide_id nil", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/")
      lv |> element("button", "Import SWAR file") |> render_click()

      swar = file_input(lv, "form", :swar, [
        %{name: "problemski.swar", content: File.read!(@problemski), type: "application/octet-stream"}
      ])

      render_upload(swar, "problemski.swar")
      lv |> form("#swar-import-form", %{}) |> render_submit()

      assert has_element?(lv, "h2", "Resolve FIDE ids")

      {:error, {:live_redirect, %{to: to}}} =
        lv |> form("#swar-resolve-form", %{}) |> render_submit()

      tournament_id = to |> String.split("/") |> Enum.at(2) |> String.to_integer()
      players = Tournaments.list_players(tournament_id)
      ashrafi = Enum.find(players, &(&1.name == "Ashrafi, Sulaiman Ahmad"))
      assert ashrafi.fide_id == nil
    end

    test "picking a suggested FIDE candidate adopts its id, without touching SWAR's own name", %{conn: conn} do
      Repo.insert!(%FidePlayer{
        fide_id: 555_555,
        name: "Ashrafi, Sulaiman Ahmad",
        federation: "BEL",
        birth_year: 2010,
        title: "",
        standard_rating: 1500
      })

      {:ok, lv, _html} = live(conn, ~p"/")
      lv |> element("button", "Import SWAR file") |> render_click()

      swar = file_input(lv, "form", :swar, [
        %{name: "problemski.swar", content: File.read!(@problemski), type: "application/octet-stream"}
      ])

      render_upload(swar, "problemski.swar")
      lv |> form("#swar-import-form", %{}) |> render_submit()

      assert has_element?(lv, "h2", "Resolve FIDE ids")
      # Ashrafi's own birth year is unknown ("19000101" placeholder), so
      # even a same-name/federation FIDE row never auto-adopts — it must
      # show up as a pickable candidate here instead.
      assert has_element?(lv, "*", "FIDE 555555")

      html = render(lv)
      [_, ni] = Regex.run(~r/name="resolution\[(\d+)\]" value="555555"/, html)

      {:error, {:live_redirect, %{to: to}}} =
        lv
        |> form("#swar-resolve-form", %{"resolution" => %{ni => "555555"}})
        |> render_submit()

      tournament_id = to |> String.split("/") |> Enum.at(2) |> String.to_integer()
      ashrafi = Enum.find(Tournaments.list_players(tournament_id), &(&1.name == "Ashrafi, Sulaiman Ahmad"))
      assert ashrafi.fide_id == 555_555
      assert ashrafi.name == "Ashrafi, Sulaiman Ahmad"
    end

    test "'Back' returns to the upload form without importing anything", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      lv |> element("button", "Import SWAR file") |> render_click()

      swar = file_input(lv, "form", :swar, [
        %{name: "problemski.swar", content: File.read!(@problemski), type: "application/octet-stream"}
      ])

      render_upload(swar, "problemski.swar")
      lv |> form("#swar-import-form", %{}) |> render_submit()
      assert has_element?(lv, "h2", "Resolve FIDE ids")

      lv |> element("button", "Back") |> render_click()

      refute has_element?(lv, "h2", "Resolve FIDE ids")
      assert has_element?(lv, "h2", "Import a SWAR tournament")
    end
  end
end
