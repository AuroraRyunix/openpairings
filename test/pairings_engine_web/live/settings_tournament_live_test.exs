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

  describe "removing a published tournament from the results site" do
    setup do
      Publishing.put_endpoint("https://openresults.example/")
      Publishing.put_token("s3cret")

      # The request goes out from the LiveView process, not from the test's,
      # so a stub owned by this process would never be found.
      Req.Test.set_req_test_to_shared(%{})
      :ok
    end

    defp publish_once(tournament) do
      Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
        Req.Test.json(conn, %{"ok" => true})
      end)

      {:ok, tournament} = Tournaments.set_publish_to_openresults(tournament, true)
      {:ok, _} = Publishing.publish(tournament)
      Tournaments.get_tournament!(tournament.id)
    end

    test "is not offered before anything has actually been sent", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, tournament} = Tournaments.set_publish_to_openresults(tournament, true)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      # The switch being on is a promise about the future. There is nothing
      # out there to take down until a publish has landed.
      refute html =~ "Remove from the results site"
    end

    test "says what goes before it goes", %{conn: conn, scope: scope} do
      tournament = scope |> create_tournament() |> publish_once()

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      assert html =~ "Remove from the results site"
      # An arbiter can reasonably assume this hides a page. The two things
      # they would otherwise only discover afterwards are named.
      assert html =~ "every earlier snapshot in its history"
      assert html =~ "any entries collected for it"
    end

    test "a successful takedown turns publishing off and says so", %{conn: conn, scope: scope} do
      tournament = scope |> create_tournament() |> publish_once()
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

      Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
        assert conn.method == "DELETE"
        Req.Test.json(conn, %{"status" => "deleted"})
      end)

      html = lv |> element("button", "Remove from the results site") |> render_click()

      assert html =~ "Removed from the results site"

      after_takedown = Tournaments.get_tournament!(tournament.id)
      refute after_takedown.publish_to_openresults
      refute after_takedown.openresults_key
    end

    test "a failed takedown is reported in words and leaves the tournament alone", %{
      conn: conn,
      scope: scope
    } do
      tournament = scope |> create_tournament() |> publish_once()
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

      Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      html = lv |> element("button", "Remove from the results site") |> render_click()

      assert html =~ "Could not remove it from the results site"
      assert html =~ "connection was refused"
      refute html =~ "TransportError"

      # Telling an arbiter their event was withdrawn when it is still up is
      # the one outcome worse than the failure itself.
      unchanged = Tournaments.get_tournament!(tournament.id)
      assert unchanged.publish_to_openresults
      assert unchanged.openresults_key == tournament.openresults_key
    end
  end

  describe "a publishing key carried in from a backup" do
    setup do
      Publishing.put_endpoint("https://openresults.example/")
      Publishing.put_token("s3cret")
      Req.Test.set_req_test_to_shared(%{})
      :ok
    end

    defp imported_copy_of_published(scope) do
      Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
        Req.Test.json(conn, %{"ok" => true})
      end)

      source = create_tournament(scope, %{"name" => "Published Original"})
      {:ok, source} = Tournaments.set_publish_to_openresults(source, true)
      {:ok, _} = Publishing.publish(source)
      source = Tournaments.get_tournament!(source.id)

      {:ok, [imported]} =
        source
        |> PairingsEngine.TournamentExport.export_tournament()
        |> PairingsEngine.TournamentImport.import(scope)

      {source, Tournaments.get_tournament!(imported.id)}
    end

    test "the choice is offered, and nothing has been adopted", %{conn: conn, scope: scope} do
      {source, imported} = imported_copy_of_published(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{imported.id}/settings")

      assert html =~ "A publishing key came with this file"
      assert html =~ "Take over publishing it"
      assert html =~ "Start fresh"
      assert html =~ "https://openresults.example/t/#{source.public_slug}"

      # Offered, not taken. Until somebody chooses, this is a separate
      # tournament that publishes nowhere.
      refute imported.openresults_key
      refute imported.publish_to_openresults
    end

    test "starting fresh throws the key away and leaves the original alone", %{
      conn: conn,
      scope: scope
    } do
      {source, imported} = imported_copy_of_published(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{imported.id}/settings")

      html = lv |> element("button", "Start fresh") |> render_click()

      assert html =~ "Starting fresh"
      refute html =~ "A publishing key came with this file"
      refute Tournaments.get_tournament!(imported.id).openresults_claim

      assert Tournaments.get_tournament!(source.id).openresults_key == source.openresults_key
    end

    test "taking over moves the key and the address across", %{conn: conn, scope: scope} do
      {source, imported} = imported_copy_of_published(scope)

      # The original is gone - the laptop-rebuild case this exists for. With
      # it still here, `public_slug`'s unique index refuses the takeover, and
      # that refusal is itself the right answer.
      Repo.delete!(source)

      {:ok, lv, _html} = live(conn, ~p"/t/#{imported.id}/settings")
      html = lv |> element("button", "Take over publishing it") |> render_click()

      assert html =~ "now publishes to the address the backup came from"

      adopted = Tournaments.get_tournament!(imported.id)
      assert adopted.openresults_key == source.openresults_key
      assert adopted.public_slug == source.public_slug
      refute adopted.openresults_claim
    end

    test "a tournament with no claim is offered nothing", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      refute html =~ "A publishing key came with this file"
    end
  end
end
