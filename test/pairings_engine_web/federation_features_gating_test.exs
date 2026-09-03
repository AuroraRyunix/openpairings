defmodule PairingsEngineWeb.FederationFeaturesGatingTest do
  @moduledoc """
  Every entrance the Belgian pack has into the web layer, checked twice.

  For each of the five switches:

    * **the control is ABSENT** when the switch is off - not rendered and
      disabled, not rendered with an explanation. A button that is there to
      tell you it will not work is worse than a button that was never in the
      row; the point of the switch is a plainer application, not a
      differently-cluttered one.
    * **the event REFUSES** when the switch is off. A `phx-click` payload is
      written by whoever is on the other end of the socket, and a URL is
      typed, bookmarked and shared, so neither markup nor a link is a gate.
      Same reasoning as `PairingsEngineWeb.AdminLive`, which is where the
      pattern comes from.

  And, at the bottom, the rule the whole design rests on: switching the pack
  off changes no stored value. A tournament imported from SWAR keeps its
  scoring settings and produces the same standings with every switch off.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Features, Repo, Standings, Tournaments}
  alias PairingsEngine.Federations.BEL.{Member, SwarImport}

  setup :register_and_log_in_user

  # Setup-complete, so "Add player" is actually available - the add form is
  # where the National ID field's autofill binding lives.
  defp tournament(scope, name) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => name,
        "type" => "swiss",
        "start_date" => "2026-07-15",
        "rounds_count" => "5",
        "round_dates" => List.duplicate("2026-07-15", 5),
        "tiebreaks" => ["BH", "SB"]
      })

    t
  end

  ## ---------- bel_ratings_sync ----------

  describe "bel_ratings_sync, switched off" do
    test "the Connections page shows no Belgian panel at all", %{conn: conn, user: user} do
      {:ok, _} = PairingsEngine.Accounts.set_role(user.email, "admin")

      {:ok, lv, html} = live(conn, ~p"/fide")

      refute html =~ "Belgian national rating list"
      refute has_element?(lv, "button[phx-click='sync_kbsb_api']")
      refute has_element?(lv, "#kbsb-search-form")

      # The FIDE half of the same page is untouched - this hides a pack, not
      # a feature everybody uses.
      assert html =~ "FIDE"
    end

    test "the sync event refuses even though no button offers it", %{conn: conn, user: user} do
      {:ok, _} = PairingsEngine.Accounts.set_role(user.email, "admin")
      {:ok, lv, _html} = live(conn, ~p"/fide")

      html = render_click(lv, "sync_kbsb_api", %{})

      assert html =~ "switched off for your account"
      assert PairingsEngine.Federations.BEL.Sync.status().status == :idle
    end

    test "the search event refuses and returns nobody", %{conn: conn, user: user} do
      {:ok, _} = PairingsEngine.Accounts.set_role(user.email, "admin")
      Repo.insert!(%Member{national_id: "77001", last_name: "Hidden", club_name: "Somewhere"})

      {:ok, lv, _html} = live(conn, ~p"/fide")
      html = render_change(lv, "kbsb_search", %{"q" => "Hidden"})

      assert html =~ "switched off for your account"
      refute html =~ "Hidden"
    end
  end

  describe "bel_ratings_sync, switched on" do
    setup :enable_federation_features

    test "the panel is back", %{conn: conn, user: user} do
      {:ok, _} = PairingsEngine.Accounts.set_role(user.email, "admin")

      {:ok, lv, html} = live(conn, ~p"/fide")

      assert html =~ "Belgian national rating list"
      assert has_element?(lv, "#kbsb-search-form")
    end
  end

  ## ---------- bel_player_lookup ----------

  describe "bel_player_lookup, switched off" do
    setup %{scope: scope}, do: %{tournament: tournament(scope, "Lookup Off")}

    test "no KBSB lookup button, and the National ID box asks nothing as you type", %{
      conn: conn,
      tournament: t
    } do
      {:ok, player} =
        Tournaments.create_player(t.id, %{"name" => "Somebody, Sam", "national_id" => "31000"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")

      # The FIELD is still there - a federation-neutral column - but the
      # binding that turns it into a KBSB query is not.
      add_form = render_click(lv, "add", %{})
      assert add_form =~ "National ID"
      refute add_form =~ ~s(phx-change="lookup_kbsb_add")

      render_click(lv, "done", %{})
      render_click(lv, "edit_player", %{"id" => to_string(player.id)})
      modal = render(lv)

      refute modal =~ "KBSB lookup"
      # Its FIDE twin, on the same row, is untouched.
      assert modal =~ "FIDE lookup"
    end

    test "the edit-modal lookup event refuses", %{conn: conn, tournament: t} do
      {:ok, player} =
        Tournaments.create_player(t.id, %{"name" => "Somebody, Sam", "national_id" => "31000"})

      Repo.insert!(%Member{
        national_id: "31000",
        last_name: "Somebody",
        club_name: "Leuven",
        national_rating: 1875
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
      render_click(lv, "edit_player", %{"id" => to_string(player.id)})

      html = render_click(lv, "refresh_edit_kbsb", %{})

      assert html =~ "switched off for your account"
      refute html =~ "Leuven"
      refute html =~ "1875"
    end

    test "the add-form autofill event fills nothing", %{conn: conn, tournament: t} do
      Repo.insert!(%Member{
        national_id: "31001",
        last_name: "Autofill",
        club_name: "Gent",
        national_rating: 1650
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
      render_click(lv, "add", %{})

      html = render_change(lv, "lookup_kbsb_add", %{"player" => %{"national_id" => "31001"}})

      refute html =~ "Gent"
      refute html =~ "1650"
    end
  end

  describe "bel_player_lookup, switched on" do
    setup :enable_federation_features
    setup %{scope: scope}, do: %{tournament: tournament(scope, "Lookup On")}

    test "the button is back and the lookup fills the form", %{conn: conn, tournament: t} do
      {:ok, player} =
        Tournaments.create_player(t.id, %{"name" => "Somebody, Sam", "national_id" => "31002"})

      Repo.insert!(%Member{
        national_id: "31002",
        last_name: "Somebody",
        club_name: "Brugge",
        national_rating: 1900
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
      assert render_click(lv, "add", %{}) =~ ~s(phx-change="lookup_kbsb_add")

      render_click(lv, "done", %{})
      render_click(lv, "edit_player", %{"id" => to_string(player.id)})
      assert render(lv) =~ "KBSB lookup"

      assert render_click(lv, "refresh_edit_kbsb", %{}) =~ "Brugge"
    end
  end

  ## ---------- bel_club_sync ----------

  describe "bel_club_sync, switched off" do
    setup %{scope: scope}, do: %{tournament: tournament(scope, "Clubs Off")}

    test "no Update clubs button", %{conn: conn, tournament: t} do
      {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/players")

      refute html =~ "Update clubs"
      refute html =~ ~s(phx-click="open_club_refresh")
      # The rating refresh beside it is a FIDE gesture and stays.
      assert html =~ "Refresh ratings"
    end

    test "the preview and the apply both refuse, and nothing is written", %{
      conn: conn,
      tournament: t
    } do
      {:ok, player} =
        Tournaments.create_player(t.id, %{
          "name" => "Clubless, Carl",
          "national_id" => "32000",
          "club" => "Old Club"
        })

      Repo.insert!(%Member{
        national_id: "32000",
        last_name: "Clubless",
        club_name: "New Club",
        club_number: 812
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")

      assert render_click(lv, "open_club_refresh", %{}) =~ "switched off for your account"
      assert render_click(lv, "apply_club_refresh", %{}) =~ "switched off for your account"

      unchanged = Tournaments.get_player!(t.id, player.id)
      assert unchanged.club == "Old Club"
      assert unchanged.club_number == nil
    end
  end

  ## ---------- bel_swar_import ----------

  describe "bel_swar_import, switched off" do
    test "no Import SWAR file button, and the empty state does not offer SWAR", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")

      refute html =~ "Import SWAR file"
      refute html =~ ~s(phx-click="import")
      # The other two import routes are not Belgian and stay.
      assert html =~ "Import TRF file"
      assert html =~ "Import backup (JSON)"
      assert html =~ "import one from TRF16 or a backup"
    end

    test "the panel event and the submit event both refuse", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      assert render_click(lv, "import", %{}) =~ "SWAR import is switched off"
      refute has_element?(lv, "#swar-import-form")

      assert render_click(lv, "import_swar", %{}) =~ "SWAR import is switched off"
    end

    @tag :swar_fixture
    test "a .swar dropped into the TRF panel is refused rather than quietly imported", %{
      conn: conn,
      scope: scope
    } do
      before = length(Tournaments.list_tournaments(scope))

      {:ok, lv, _html} = live(conn, ~p"/")
      lv |> element("button", "Import TRF file") |> render_click()

      trf =
        file_input(lv, "form", :trf, [
          %{
            name: "problemski.swar",
            content: File.read!("test/fixtures/problemski.swar"),
            type: "application/octet-stream"
          }
        ])

      render_upload(trf, "problemski.swar")
      html = lv |> form("#trf-import-form", %{}) |> render_submit()

      assert html =~ "SWAR import is switched off"
      refute has_element?(lv, "h2", "Resolve FIDE ids")
      assert length(Tournaments.list_tournaments(scope)) == before
    end
  end

  ## ---------- bel_swar_export ----------

  describe "bel_swar_export, switched off" do
    setup %{scope: scope}, do: %{tournament: tournament(scope, "Export Off")}

    test "the Export settings page offers no .swar download", %{conn: conn, tournament: t} do
      {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/settings/export")

      refute html =~ "Export .swar"
      refute html =~ ~s(href="/t/#{t.id}/export/swar")
      # The JSON backup on the same row is not Belgian and stays.
      assert html =~ "Export full backup (JSON)"
    end

    test "the route refuses a typed or bookmarked URL", %{conn: conn, tournament: t} do
      conn = get(conn, ~p"/t/#{t.id}/export/swar")

      assert conn.status == 403
      assert conn.resp_body =~ "switched off for your account"
    end
  end

  describe "bel_swar_export, switched on" do
    setup :enable_federation_features
    setup %{scope: scope}, do: %{tournament: tournament(scope, "Export On")}

    test "the link and the download are both back", %{conn: conn, tournament: t} do
      {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/settings/export")
      assert html =~ ~s(href="/t/#{t.id}/export/swar")

      conn = get(conn, ~p"/t/#{t.id}/export/swar")
      assert conn.status == 200
    end
  end

  ## ---------- the rule ----------

  describe "the pack owns entrances, never stored values" do
    setup :enable_federation_features

    @tag :swar_fixture
    test "a SWAR-imported tournament scores identically after every switch is turned off", %{
      user: user,
      scope: scope
    } do
      # Straight through the importer rather than through the upload form:
      # what is being measured here is what the switches do to STORED data,
      # and the page that took the file in has already been tested above.
      {:ok, imported, _warnings} = SwarImport.import_file("test/fixtures/c-reeks.swar", scope)

      assert imported.swar_guid
      before = Standings.standings(imported)

      # These live in the core `Tournament` schema and are deliberately out of
      # the pack's reach - see `PairingsEngine.Features`.
      settings = [
        :abs_value,
        :abs_jusque,
        :abs_nbfois,
        :presence_value,
        :presence_on_allocated_bye,
        :swar_guid
      ]

      settings_before = Map.take(imported, settings)

      {:ok, _user} = Features.set_enabled(user, [])

      after_off = Tournaments.get_tournament!(imported.id)

      assert Map.take(after_off, settings) == settings_before
      assert Standings.standings(after_off) == before

      # And the players it brought in are still all there, national ids and
      # clubs intact - those columns are federation-neutral.
      players = Tournaments.list_players(imported.id)
      assert players != []
      assert Enum.any?(players, &(&1.national_id not in [nil, ""]))
    end
  end
end
