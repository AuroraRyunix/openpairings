defmodule PairingsEngineWeb.BadgeLiveTest do
  # async: false - SQLite writes, and the FIDE stub is shared with the
  # LiveView's async task (see the "Fetch from FIDE" test).
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Badges, RateLimit, Repo, Tournaments}

  setup :register_and_log_in_user

  setup do
    RateLimit.clear_all()
    :ok
  end

  defp png(w \\ 400, h \\ 500),
    do: <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 13::32, "IHDR", w::32, h::32, 8, 6, 0, 0, 0>>

  defp tournament_with_people(scope) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Ghent Open",
        "type" => "swiss",
        "chief_arbiter" => "De Vet, Pieter",
        "officials" => %{"chief_arbiter_fide_id" => "209848"}
      })

    for name <- ["Carlsen, Magnus", "Burssens, Jorian", "Doe, Jane"] do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name, "federation" => "BEL"})
    end

    t
  end

  describe "events page" do
    test "creates a stand-alone event", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/badges")

      assert has_element?(lv, "#badge-event-form")

      assert {:error, {:live_redirect, %{to: "/badges/" <> _}}} =
               lv
               |> form("#badge-event-form", event: %{name: "Press Day 2026"})
               |> render_submit()

      assert [%{name: "Press Day 2026", tournament_id: nil}] = Badges.list_events(scope)
    end

    test "creates an event linked to a tournament, preselected from the tournament menu", %{
      conn: conn,
      scope: scope
    } do
      t = tournament_with_people(scope)

      conn = get(conn, ~p"/t/#{t.id}/badges")
      assert redirected_to(conn) == ~p"/badges?new=1&tournament_id=#{t.id}"

      {:ok, lv, _html} = live(recycle(conn), ~p"/badges?new=1&tournament_id=#{t.id}")
      assert has_element?(lv, "#badge-event-tournament option[selected][value='#{t.id}']")

      {:error, {:live_redirect, %{to: to}}} =
        lv
        |> form("#badge-event-form", event: %{name: "Ghent badges", tournament_id: t.id})
        |> render_submit()

      [event] = Badges.list_events(scope)
      assert to == ~p"/badges/#{event.id}"
      assert event.tournament_id == t.id

      # With an event linked, the menu entry opens it.
      assert redirected_to(get(recycle(conn), ~p"/t/#{t.id}/badges")) == ~p"/badges/#{event.id}"
    end
  end

  describe "studio" do
    setup %{scope: scope} do
      t = tournament_with_people(scope)

      {:ok, event} =
        Badges.create_event(scope, %{"name" => "Ghent badges", "tournament_id" => t.id})

      %{t: t, event: event}
    end

    test "imports players and officials into the list", %{conn: conn, scope: scope, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/badges/#{event.id}")

      assert has_element?(lv, "#badges-empty")
      lv |> element("#import-players") |> render_click()
      lv |> element("#import-officials") |> render_click()

      badges = Badges.list_badges(scope, event)
      assert length(badges) == 4

      for badge <- badges, do: assert(has_element?(lv, "#badges-#{badge.id}"))

      # Running it again adds nothing.
      lv |> element("#import-players") |> render_click()
      assert length(Badges.list_badges(scope, event)) == 4
    end

    test "edits a badge with a live preview and records the edited field", %{
      conn: conn,
      scope: scope,
      event: event
    } do
      {:ok, _} = Badges.import_players(scope, event)
      badge = hd(Badges.list_badges(scope, event))

      {:ok, lv, _html} = live(conn, ~p"/badges/#{event.id}/badge/#{badge.id}")
      assert has_element?(lv, "#preview-front")
      assert has_element?(lv, "#preview-back")

      lv |> form("#badge-form", badge: %{first_name: "Maggie"}) |> render_change()
      assert has_element?(lv, "#preview-front", "Maggie")

      badge = Repo.reload!(badge)
      assert badge.first_name == "Maggie"
      assert badge.edited_fields == ["first_name"]
      assert has_element?(lv, "#revert-badge")

      lv |> element("#role-preset-vip") |> render_click()
      assert Repo.reload!(badge).role == "VIP"

      lv |> element("#room-toggle-3") |> render_click()
      assert 3 in Repo.reload!(badge).room_access

      lv |> element("#preview-flip") |> render_click()
      assert has_element?(lv, "#badge-flip")
      lv |> element("#badge-flip") |> render_click()
      assert has_element?(lv, ".badge-flip-inner.is-flipped")
    end

    test "adds a manual badge and opens it in the editor", %{
      conn: conn,
      scope: scope,
      event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/badges/#{event.id}")
      lv |> element("#add-badge") |> render_click()

      [badge] = Badges.list_badges(scope, event)
      assert_patch(lv, ~p"/badges/#{event.id}/badge/#{badge.id}")
      assert badge.source == "manual"
      assert has_element?(lv, "#badge-form")
    end

    test "uploads a photo, and refuses a file that is not an image", %{
      conn: conn,
      scope: scope,
      event: event
    } do
      {:ok, badge} = Badges.create_badge(scope, event)
      {:ok, lv, _html} = live(conn, ~p"/badges/#{event.id}/badge/#{badge.id}")

      fake =
        file_input(lv, "#photo-upload-form", :photo, [
          %{
            name: "photo.png",
            content: "<svg xmlns='http://www.w3.org/2000/svg'/>",
            type: "image/png"
          }
        ])

      render_upload(fake, "photo.png")
      assert Badges.photo(badge) == nil
      assert render(lv) =~ "Only PNG, JPEG, GIF or WebP images can be used."

      real =
        file_input(lv, "#photo-upload-form", :photo, [
          %{name: "me.png", content: png(), type: "image/png"}
        ])

      render_upload(real, "me.png")
      assert {_, "image/png"} = Badges.photo(badge)
      assert has_element?(lv, "#badge-photo-thumb")

      too_big =
        file_input(lv, "#photo-upload-form", :photo, [
          %{name: "big.png", content: png() <> :binary.copy(<<0>>, 1_100_000), type: "image/png"}
        ])

      assert {:error, [[_, :too_large]]} = render_upload(too_big, "big.png")
    end

    test "fetches a photo from FIDE once, through the stub", %{
      conn: conn,
      scope: scope,
      event: event
    } do
      Req.Test.set_req_test_to_shared()
      on_exit(fn -> Req.Test.set_req_test_to_private() end)
      me = self()

      Req.Test.stub(PairingsEngine.Badges.FideProfileTest, fn conn ->
        send(me, :fide_request)

        Plug.Conn.send_resp(conn, 200, """
        <h1 class="player-title">Burssens, Jorian</h1>
        <img class="profile-top__photo" src="data:image/png;base64,#{Base.encode64(png())}">
        """)
      end)

      {:ok, badge} = Badges.create_badge(scope, event, %{"fide_id" => "255424"})
      {:ok, lv, _html} = live(conn, ~p"/badges/#{event.id}/badge/#{badge.id}")

      lv |> element("#fetch-fide-photo") |> render_click()
      render_async(lv)

      assert_received :fide_request
      assert Repo.reload!(badge).photo_source == "fide"
      assert has_element?(lv, "#badge-photo-thumb")
      assert has_element?(lv, "#fetch-fide-photo[disabled]")

      # A second press sends nothing.
      render_click(lv, "fetch_fide", %{})
      refute_received :fide_request
    end

    test "the FIDE failure message says what to do", %{conn: conn, scope: scope, event: event} do
      Req.Test.set_req_test_to_shared()
      on_exit(fn -> Req.Test.set_req_test_to_private() end)

      Req.Test.stub(PairingsEngine.Badges.FideProfileTest, fn conn ->
        Plug.Conn.send_resp(conn, 200, "<html><body><div>redesigned</div></body></html>")
      end)

      {:ok, badge} = Badges.create_badge(scope, event, %{"fide_id" => "255424"})
      {:ok, lv, _html} = live(conn, ~p"/badges/#{event.id}/badge/#{badge.id}")

      lv |> element("#fetch-fide-photo") |> render_click()
      assert render_async(lv) =~ "upload the photo by hand"
      assert Badges.photo(badge) == nil
    end

    test "settings save the printed text and rooms", %{conn: conn, scope: scope, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/badges/#{event.id}/settings")

      lv
      |> form("#event-settings-form",
        event: %{
          name: "Gent Open / Open de Gand",
          conditions_title: "GEBRUIKSVOORWAARDEN / CONDITIONS",
          room_count: "3",
          room_names: %{"1" => "SPEELZAAL / SALLE DE JEU"}
        }
      )
      |> render_submit()

      event = Badges.get_event!(scope, event.id)
      assert event.name == "Gent Open / Open de Gand"
      assert event.conditions_title == "GEBRUIKSVOORWAARDEN / CONDITIONS"
      assert event.room_count == 3
      assert event.room_names["1"] == "SPEELZAAL / SALLE DE JEU"
      assert has_element?(lv, "#preview-back", "GEBRUIKSVOORWAARDEN")

      lv |> element("#add-role") |> render_click()
      assert render(lv) =~ "NEW ROLE"
      refute has_element?(lv, "#remove-role-player")
      assert has_element?(lv, "#remove-role-press")
    end

    test "uploads an event logo from the settings page", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/badges/#{event.id}/settings")

      logo =
        file_input(lv, "#logo-upload-form-emblem", :emblem, [
          %{name: "logo.png", content: png(900, 300), type: "image/png"}
        ])

      render_upload(logo, "logo.png")
      assert {_, "image/png"} = Badges.logo(event, :emblem)
      assert has_element?(lv, "#clear-logo-emblem")
    end

    test "another user gets a 404 everywhere", %{event: event} do
      other = user_fixture()
      conn = log_in_user(build_conn(), other)

      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/badges/#{event.id}") end
      assert_raise Ecto.NoResultsError, fn -> get(conn, ~p"/badges/#{event.id}/print") end
      refute has_element?(elem(live(conn, ~p"/badges"), 1), "a[href='/badges/#{event.id}']")
    end
  end

  describe "print sheet" do
    setup %{scope: scope} do
      t = tournament_with_people(scope)

      {:ok, event} =
        Badges.create_event(scope, %{"name" => "Ghent badges", "tournament_id" => t.id})

      {:ok, _} = Badges.import_players(scope, event)
      %{event: event}
    end

    test "renders every badge, two to a sheet, with the print trigger", %{
      conn: conn,
      scope: scope,
      event: event
    } do
      {:ok, badge} = Badges.create_badge(scope, event)
      {:ok, _} = Badges.set_photo(scope, badge, png())

      conn = get(conn, ~p"/badges/#{event.id}/print")
      html = html_response(conn, 200)
      doc = LazyHTML.from_document(html)

      assert doc |> LazyHTML.query(".badge-print-pair") |> Enum.count() == 4
      assert doc |> LazyHTML.query(".badge-print-page") |> Enum.count() == 2
      assert doc |> LazyHTML.query("[data-badge-card=front]") |> Enum.count() == 4
      assert doc |> LazyHTML.query("[data-badge-card=back]") |> Enum.count() == 4
      assert html =~ "window.print()"
      assert html =~ "/badges/#{event.id}/photo/#{badge.id}"
      assert html =~ ~r/<script nonce="[^"]+">/
    end

    test "prints a single badge", %{conn: conn, scope: scope, event: event} do
      badge = hd(Badges.list_badges(scope, event))
      html = conn |> get(~p"/badges/#{event.id}/print?badge=#{badge.id}") |> html_response(200)
      doc = LazyHTML.from_document(html)

      assert doc |> LazyHTML.query(".badge-print-pair") |> Enum.count() == 1
    end

    test "serves the photo to its owner only", %{conn: conn, scope: scope, event: event} do
      badge = hd(Badges.list_badges(scope, event))
      {:ok, _} = Badges.set_photo(scope, badge, png())

      conn = get(conn, ~p"/badges/#{event.id}/photo/#{badge.id}")
      assert response(conn, 200) == png()
      assert get_resp_header(conn, "content-type") == ["image/png"]

      other = log_in_user(build_conn(), user_fixture())

      assert_raise Ecto.NoResultsError, fn ->
        get(other, ~p"/badges/#{event.id}/photo/#{badge.id}")
      end
    end
  end

  describe "entry points" do
    test "the tools page links to the badge maker when signed in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/tools/norms")
      assert has_element?(lv, "#tools-badges-link[href='/badges']")
    end

    test "the tools page asks a visitor to log in" do
      {:ok, lv, _html} = live(build_conn(), ~p"/tools/norms")
      assert has_element?(lv, "#tools-badges-login")
      refute has_element?(lv, "#tools-badges-link")
    end

    test "the badge maker itself needs a login" do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/badges")
      assert redirected_to(get(build_conn(), ~p"/badges/1/print")) == ~p"/users/log-in"
    end

    test "the tournament's print page links to its badges", %{conn: conn, scope: scope} do
      t = tournament_with_people(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/print")
      assert has_element?(lv, "#print-badges-link[href='/t/#{t.id}/badges']")
    end
  end
end
