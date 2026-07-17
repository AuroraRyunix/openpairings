defmodule PairingsEngineWeb.SettingsTournamentLiveTest do
  # async: false: sequential SQLite writes plus self-broadcast/render ordering,
  # same rationale as the other Settings LiveView tests.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Settings LV Test", "type" => "swiss", "rounds_count" => "5"}, attrs)
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
      # Chief arbiter is no longer a Settings field at all — it moved to the
      # Officials card on the Norms tab.
      refute html =~ ~s(name="tournament[chief_arbiter]")
    end

    test "the mandatory labels render bold with a red asterisk", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      assert html =~ "Tournament name"
      assert html =~ "Start date"
      assert html =~ "Number of rounds"
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
end
