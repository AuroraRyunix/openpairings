defmodule PairingsEngineWeb.SettingsLiveTest do
  # `async: false`: like PairingsEngine.TournamentsTest and friends, several
  # tests here do a handful of sequential writes (tournament + players +
  # forbidden pairings/categories) against SQLite's single writer, and the
  # "self-broadcast" regression tests specifically rely on PubSub delivery
  # ordering relative to `render/1`, which is easiest to reason about
  # without other async tests' writes interleaving.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Fide.FidePlayer

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

  describe "Rate of play — dependent on Type (standard)" do
    test "the active rate-of-play list matches the tournament's standard on load", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"standard" => "blitz"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      # A blitz-only option is offered...
      assert html =~ "5min/end+2sec/move from move 1"
      # ...but a standard-only one (that doesn't also appear on the blitz
      # list) is not.
      refute html =~ "150min/end"
    end

    test "switching Type swaps the Rate of play option list", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"standard" => "standard"})

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")
      assert html =~ "150min/end"
      refute html =~ "59min/end"

      html =
        lv
        |> element("select[name='tournament[standard]']")
        |> render_change(%{"tournament" => %{"standard" => "rapid"}})

      assert html =~ "59min/end"
      refute html =~ "150min/end"
    end

    test "switching Type keeps the current rate of play if it's on the new list, else clears it",
         %{
           conn: conn,
           scope: scope
         } do
      # "10min/end" appears on both the rapid... (no, only blitz/rapid share
      # nothing verbatim) — use a value unique to rapid vs one unique to
      # blitz to prove both branches.
      tournament =
        create_tournament(scope, %{"standard" => "rapid", "rate_of_play" => "45min/end"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

      # "45min/end" only exists on the rapid list — switching to blitz must
      # clear the selection (fall back to the blank option) rather than
      # silently keep an option that no longer exists on the rendered list.
      html =
        lv
        |> element("select[name='tournament[standard]']")
        |> render_change(%{"tournament" => %{"standard" => "blitz"}})

      refute html =~ "45min/end"

      # Switching back to rapid, the value is gone (it was cleared), so the
      # blank option is what's active — saving now should persist blank.
      lv
      |> element("select[name='tournament[standard]']")
      |> render_change(%{"tournament" => %{"standard" => "rapid"}})

      lv
      |> form("form[phx-submit=save]", %{"tournament" => %{"rate_of_play" => "59min/end"}})
      |> render_submit()

      # "save" broadcasts :settings on the tournament topic and this `lv` is
      # subscribed to its own tournament (see SettingsLive's mount) —
      # render_submit/1 only waits for the direct reply to the "save" event,
      # not for that self-broadcast's handle_info reload, which lands in the
      # mailbox microseconds later and runs its own Repo query. Draining it
      # with a synchronous render/1 before the test (and this `lv`'s
      # teardown) proceeds avoids racing that query against the test process
      # supervisor killing `lv` mid-query — which, on SQLite's single-writer
      # file, can wedge the shared sandbox connection for later tests with a
      # spurious `Database busy` (see the same fix in sharing_test.exs).
      render(lv)

      assert Tournaments.get_authorized_tournament!(scope, tournament.id).rate_of_play ==
               "59min/end"
    end

    test "a stored rate_of_play not on any preset list (e.g. from SWAR import) is offered as an extra option instead of silently dropped",
         %{conn: conn, scope: scope} do
      tournament =
        create_tournament(scope, %{
          "standard" => "standard",
          "rate_of_play" => "40min/40moves+finish (SWAR import)"
        })

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      assert html =~ "40min/40moves+finish (SWAR import)"
    end
  end

  describe "Round dates" do
    test "shows the weekday for a filled-in round date and the round labels", %{
      conn: conn,
      scope: scope
    } do
      tournament =
        create_tournament(scope, %{"rounds_count" => "2", "round_dates" => ["2026-07-13", ""]})

      # 2026-07-13 is a Monday.
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      assert html =~ "Round 1"
      assert html =~ "Monday"
      assert html =~ "Round 2"
    end

    test "'Fill sequentially from start date' sets round N = start date + (N-1) days", %{
      conn: conn,
      scope: scope
    } do
      tournament =
        create_tournament(scope, %{"rounds_count" => "3", "start_date" => "2026-07-13"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

      lv |> element("button", "Fill sequentially from start date") |> render_click()

      lv |> form("form[phx-submit=save]", %{}) |> render_submit()

      # Same self-broadcast race as the "switching Type keeps the current
      # rate of play" test above — drain it before the test (and `lv`'s
      # teardown) proceeds.
      render(lv)

      tournament = Tournaments.get_authorized_tournament!(scope, tournament.id)
      assert tournament.round_dates == ["2026-07-13", "2026-07-14", "2026-07-15"]
    end
  end

  describe "Categories toggle" do
    test "the Categories card is a single checkbox saved via the big settings form", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      refute tournament.categories_enabled

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      # The old standalone Categories/Extra points cards are gone — only the
      # enable checkbox (and its label) remains from that area.
      refute html =~ "New category name"
      refute html =~ "id=\"add-category-form\""
      refute html =~ "id=\"extra-points-form\""
      assert html =~ "Enable the Categories tab"

      lv
      |> form("form[phx-submit=save]", %{"tournament" => %{"categories_enabled" => "true"}})
      |> render_submit()

      render(lv)

      assert Tournaments.get_authorized_tournament!(scope, tournament.id).categories_enabled

      lv
      |> form("form[phx-submit=save]", %{"tournament" => %{"categories_enabled" => "false"}})
      |> render_submit()

      render(lv)

      refute Tournaments.get_authorized_tournament!(scope, tournament.id).categories_enabled
    end
  end

  describe "Forbidden pairings (scroll-jump regression)" do
    # Previously, `add_forbidden_pairing`/`remove_forbidden_pairing` wrote
    # through `PairingsEngine.Tournaments` (which broadcasts `:settings` on
    # the tournament's PubSub topic like every write does), and the
    # `settings_dirty_tracker` hook had already flagged the page `dirty`
    # for that very same event — so when the self-broadcast echoed back,
    # the page unconditionally rendered the "updated elsewhere" banner
    # right under the header, which read as the page jumping to the top.
    # It's a false positive: nothing actually changed out from under this
    # session, this session caused it.
    test "adding a forbidden pairing does not show the stale/'updated elsewhere' banner", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, a} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})
      {:ok, b} = Tournaments.create_player(tournament.id, %{"name" => "Bob"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

      html =
        lv
        |> form("#add-forbidden-pairing-form", %{
          "player_a_id" => to_string(a.id),
          "player_b_id" => to_string(b.id)
        })
        |> render_submit()

      refute html =~ "updated elsewhere"

      # Force any pending self-broadcast in the LiveView's mailbox to be
      # processed before asserting again.
      html = render(lv)
      refute html =~ "updated elsewhere"
      assert html =~ "Alice"
      assert html =~ "Bob"
    end

    test "removing a forbidden pairing does not show the stale banner either", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, a} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})
      {:ok, b} = Tournaments.create_player(tournament.id, %{"name" => "Bob"})
      {:ok, fp} = Tournaments.add_forbidden_pairing(tournament, a.id, b.id)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

      lv |> element(~s(button[phx-value-id="#{fp.id}"])) |> render_click()

      html = render(lv)
      refute html =~ "updated elsewhere"
    end

    test "a genuine concurrent change from another session while dirty still shows the stale banner",
         %{
           conn: conn,
           scope: scope
         } do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

      # Mark the page dirty the same way any in-progress edit would (e.g.
      # reordering a tiebreak), without saving.
      lv |> element("button", "Reset to FIDE default") |> render_click()

      # A real external change — bumps `updated_at` on the tournaments row
      # itself, unlike the forbidden-pairings child-table writes above.
      {:ok, _updated} = Tournaments.update_tournament(tournament, %{"venue" => "Somewhere else"})

      html = render(lv)
      assert html =~ "updated elsewhere"
    end
  end

  describe "Club/federation exclusions" do
    test "saving an \"all\" club rule persists it and updates the excluded-pair hint", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, _a} =
        Tournaments.create_player(tournament.id, %{"name" => "Alice", "club" => "Chess Club"})

      {:ok, _b} =
        Tournaments.create_player(tournament.id, %{"name" => "Bob", "club" => "Chess Club"})

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")
      assert html =~ "0 pair(s) currently excluded"

      html =
        lv
        |> form("#exclusion-rules-form", %{"tournament" => %{"club_exclusion" => "all"}})
        |> render_submit()

      assert html =~ "1 pair(s) currently excluded"
      assert Tournaments.get_authorized_tournament!(scope, tournament.id).club_exclusion == "all"

      # Same self-broadcast race noted throughout this file — "save_exclusions"
      # saves through Tournaments.update_tournament/2, which broadcasts
      # :settings. Drain it before the test (and `lv`'s teardown) proceeds.
      render(lv)
    end

    test "the \"listed\" club/federation text inputs only render once their mode is selected", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      refute html =~ "Clubs (comma-separated)"

      html =
        lv
        |> element("select[name='tournament[club_exclusion]']")
        |> render_change(%{"tournament" => %{"club_exclusion" => "listed"}})

      assert html =~ "Clubs (comma-separated)"
    end

    test "a \"listed\" federation rule with a normalized list excludes only the matching pair", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, _a} =
        Tournaments.create_player(tournament.id, %{"name" => "Alice", "federation" => "BEL"})

      {:ok, _b} =
        Tournaments.create_player(tournament.id, %{"name" => "Bob", "federation" => "BEL"})

      {:ok, _c} =
        Tournaments.create_player(tournament.id, %{"name" => "Carol", "federation" => "NED"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

      # The list text input only renders once the mode select's own
      # phx-change flips `fed_exclusion_mode` to "listed" — mirror what a
      # real browser does before the form/2 helper can find that field.
      lv
      |> element("select[name='tournament[fed_exclusion]']")
      |> render_change(%{"tournament" => %{"fed_exclusion" => "listed"}})

      html =
        lv
        |> form("#exclusion-rules-form", %{
          "tournament" => %{"fed_exclusion" => "listed", "fed_exclusion_list" => " bel , FRA"}
        })
        |> render_submit()

      assert html =~ "1 pair(s) currently excluded"

      tournament = Tournaments.get_authorized_tournament!(scope, tournament.id)
      assert tournament.fed_exclusion == "listed"
      # Normalized on save: trimmed and comma-joined, case preserved as typed.
      assert tournament.fed_exclusion_list == "bel, FRA"

      render(lv)
    end
  end

  describe "General/Format field cleanup" do
    test "Deputy arbiter(s) and Time control no longer render, and Chief arbiter moved out of General (into Officials, once each)",
         %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      refute html =~ ~s(name="tournament[deputy_arbiter]")
      refute html =~ ~s(name="tournament[time_control]")
      # Chief arbiter still exists (moved to the Officials card with a FIDE
      # autocomplete), just not duplicated as a plain General text field.
      assert html |> String.split(~s(name="tournament[chief_arbiter]")) |> length() == 2
    end

    test "the mandatory General/Format labels render bold with a red asterisk", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      assert html =~ "Tournament name"
      assert html =~ "Start date"
      assert html =~ "Number of rounds"
      assert html =~ "var(--danger)"
    end

    test "\"Pair by\" no longer offers the \"No rating (random order)\" option", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      refute html =~ "No rating (random order)"
      assert html =~ "FIDE rating"
      assert html =~ "National rating"
    end
  end

  describe "Officials card cleanup" do
    test "removes the standalone Chief arbiter FIDE ID, Pairing mode, Pairing program and Swiss variant inputs",
         %{
           conn: conn,
           scope: scope
         } do
      tournament = create_tournament(scope)
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      refute html =~ "Chief arbiter FIDE ID"
      refute html =~ ~s(name="tournament[officials][pairing_mode]")
      refute html =~ ~s(name="tournament[officials][pairing_program]")
      refute html =~ ~s(name="tournament[officials][swiss_variant]")
      # Only two deputy slots remain (down from four).
      assert html =~ "1st deputy arbiter"
      assert html =~ "2nd deputy arbiter"
      refute html =~ "3rd deputy arbiter"
      refute html =~ "4th deputy arbiter"
      # The FIDE id is only carried as a hidden field (filled by the
      # autocomplete pick) — no editable text box for it any more.
      refute html =~ ~s(type="text" name="tournament[officials][deputy1_fide_id]")
      assert html =~ ~s(type="hidden" name="tournament[officials][deputy1_fide_id]")
    end

    test "typing a chief arbiter query shows FIDE matches, and picking one fills name + FIDE id",
         %{
           conn: conn,
           scope: scope
         } do
      tournament = create_tournament(scope)

      fide_player =
        Repo.insert!(%FidePlayer{
          fide_id: 1_503_014,
          name: "Carlsen, Magnus",
          federation: "NOR",
          title: "GM"
        })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

      html =
        render_change(lv, "arbiter_search", %{
          "role" => "chief_arbiter",
          "tournament" => %{"chief_arbiter" => "Carlsen"}
        })

      assert html =~ "Carlsen, Magnus"

      html =
        render_click(lv, "arbiter_pick", %{
          "role" => "chief_arbiter",
          "fide-id" => to_string(fide_player.fide_id)
        })

      assert html =~ ~s(value="Carlsen, Magnus")
      assert html =~ "FIDE ID: 1503014"
      # The FIDE id the user just picked is carried by a hidden field (no
      # visible/editable input for it) so a plain "Save settings" click,
      # with nothing retyped, still persists it.
      assert html =~ ~s(name="tournament[officials][chief_arbiter_fide_id]" value="1503014")

      render_submit(lv, "save", %{
        "tournament" => %{
          "chief_arbiter" => "Carlsen, Magnus",
          "officials" => %{"chief_arbiter_fide_id" => "1503014"}
        }
      })

      render(lv)

      saved = Tournaments.get_authorized_tournament!(scope, tournament.id)
      assert saved.chief_arbiter == "Carlsen, Magnus"
      # Form-submitted params always arrive as strings, and `:officials` is
      # a plain (untyped) map field — no casting happens on its values, so
      # the FIDE id lands as the string exactly as the hidden field sent it.
      assert saved.officials["chief_arbiter_fide_id"] == "1503014"
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

  describe "Categories/Extra points cards removed from Settings" do
    test "neither the old Categories nor Extra points cards render any more", %{
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

  describe "Logo (SWAR parity #14-16)" do
    # 1x1 transparent PNG — real signature bytes.
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
          # Browser-supplied content-type claims image/svg+xml and the
          # filename claims .png — neither is trusted; only the actual
          # bytes (an SVG's `<svg ...>` opening tag, no raster signature)
          # decide, and they're rejected regardless of what's claimed.
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
