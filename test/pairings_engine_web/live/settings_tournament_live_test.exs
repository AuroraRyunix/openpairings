defmodule PairingsEngineWeb.SettingsTournamentLiveTest do
  # async: false: sequential SQLite writes plus self-broadcast/render ordering,
  # same rationale as the other Settings LiveView tests.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Publishing, Repo, Tournaments}

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(
          %{"name" => "Settings LV Test", "type" => "swiss", "rounds_count" => "5"},
          attrs
        )
      )

    tournament
  end

  describe "General/Format field cleanup" do
    test "Deputy arbiter and Time control no longer render on the Tournament page", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      refute html =~ ~s(name="tournament[deputy_arbiter]")
      refute html =~ ~s(name="tournament[time_control]")
      # Chief arbiter is no longer a Settings field at all - it moved to the
      # Officials card on the Norms tab.
      refute html =~ ~s(name="tournament[chief_arbiter]")
    end

    test "Settings points at where the chief arbiter actually lives", %{conn: conn, scope: scope} do
      # The field moving to Norms left Settings silent about it, and an
      # arbiter looking for "chief arbiter" looks under Settings - reported
      # by someone who could not find it while holding a direct link. Nothing
      # here should ever edit the value; the point is that the page says
      # where it is and shows whether it is set.
      tournament = create_tournament(scope)
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      assert html =~ "Officials"
      assert html =~ "Chief arbiter"
      assert html =~ ~s(href="/t/#{tournament.id}/norms")
      refute html =~ ~s(name="tournament[chief_arbiter]")
    end

    test "the Officials pointer shows the chief arbiter once it is set", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, tournament} =
        Tournaments.update_tournament(tournament, %{"chief_arbiter" => "Nona G"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      assert html =~ "Nona G"
      refute html =~ "Not set."
    end

    test "the mandatory labels render bold with a red asterisk", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      assert html =~ "Tournament name"
      assert html =~ "Number of rounds"
      # Start date used to be here too - it's derived from round_dates now
      # (Dates page), not entered on this page at all.
      refute html =~ "Start date"
      # The bold label + red asterisk are now `.set-label.req` / `.set-req`
      # (styled in app.css) rather than inline styles.
      assert html =~ ~s(class="set-label req")
      assert html =~ ~s(class="set-req")
    end
  end

  describe "Tiebreaks preset labelling" do
    test "the custom preset radio is labelled \"Custom\" (internal key stays \"personel\")", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      refute html =~ "Personel"
      assert html =~ "Custom"
      assert html =~ ~s(phx-value-key="personel")
    end
  end

  describe "Categories/Extra points cards removed from the Tournament page" do
    test "neither the category-management nor extra-points forms render here", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      refute html =~ "Elo bands (rating:bonus, comma-separated)"
      refute html =~ "Apply bands to players"
      refute html =~ "Tournament-defined groups (SWAR CATEGORIES)"
    end
  end

  describe "saving" do
    test "saving the tournament form persists the changed field", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

      lv
      |> form("form[phx-submit=save]", %{"tournament" => %{"venue" => "Grand Hall"}})
      |> render_submit()

      render(lv)

      assert Tournaments.get_authorized_tournament!(scope, tournament.id).venue == "Grand Hall"
    end
  end

  describe "stale banner" do
    test "a genuine concurrent change from another session while dirty shows the stale banner", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

      # Mark the page dirty the same way any in-progress edit would (reordering
      # a tiebreak), without saving.
      lv |> element("button", "Reset to FIDE default") |> render_click()

      {:ok, _updated} = Tournaments.update_tournament(tournament, %{"venue" => "Somewhere else"})

      html = render(lv)
      assert html =~ "updated elsewhere"
    end
  end

  describe "Logo (SWAR parity #14-16)" do
    @tiny_png Base.decode64!(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
              )
    @tiny_svg "<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>"

    test "uploading a valid PNG sets the logo and shows a preview", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

      logo =
        file_input(lv, "#logo-upload-form", :logo, [
          %{name: "logo.png", content: @tiny_png, type: "image/png"}
        ])

      render_upload(logo, "logo.png")
      html = lv |> form("#logo-upload-form", %{}) |> render_submit()

      assert html =~ "Logo uploaded."
      assert html =~ "Current logo"
      assert html =~ "data:image/png;base64,"
      assert Repo.reload!(tournament).logo_content_type == "image/png"
    end

    test "uploading an SVG is rejected with a friendly flash, nothing stored", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

      logo =
        file_input(lv, "#logo-upload-form", :logo, [
          %{name: "logo.png", content: @tiny_svg, type: "image/svg+xml"}
        ])

      render_upload(logo, "logo.png")
      html = lv |> form("#logo-upload-form", %{}) |> render_submit()

      assert html =~ "a supported image"
      refute Repo.reload!(tournament).logo_data
    end

    test "an image over the 2 MB cap says so instead of failing silently", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

      logo =
        file_input(lv, "#logo-upload-form", :logo, [
          %{
            name: "huge.png",
            content: @tiny_png <> :binary.copy(<<0>>, 2_000_001),
            type: "image/png"
          }
        ])

      assert {:error, [[_ref, :too_large]]} = render_upload(logo, "huge.png")

      assert render(lv) =~ "Image is larger than 2 MB"
      refute Repo.reload!(tournament).logo_data
    end

    test "removing a set logo clears it", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, tournament} = Tournaments.set_logo(tournament, @tiny_png)

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")
      assert html =~ "Current logo"

      html = lv |> element("button", "Remove logo") |> render_click()

      assert html =~ "Logo removed."
      refute html =~ "Current logo"
      refute Repo.reload!(tournament).logo_data
    end
  end

  describe "the publishing controls that moved" do
    test "the Tournament page carries no pointer card for them any more", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      # The pointer card was a signpost to Settings -> Results site, added
      # when everything about this tournament's public existence moved
      # there on 2026-08-29. Removed as clutter now that the sub-nav itself
      # has an "OpenResults" tab - the arbiter it was written for is already
      # looking at it.
      refute html =~ "the share link, what the public page shows and the entry form"
      assert html =~ "OpenResults"
    end
  end

  describe "Export / backup card removed from the Tournament page" do
    test "the export card and its links no longer render here", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      # Moved to its own tab - see SettingsExportLiveTest.
      refute html =~ "Export full backup (JSON)"
      refute html =~ ~s(href="/t/#{tournament.id}/export/json")
    end
  end
end
