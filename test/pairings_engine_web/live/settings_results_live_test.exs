defmodule PairingsEngineWeb.SettingsResultsLiveTest do
  @moduledoc """
  The Results site settings page - everything about a tournament's public
  existence, gathered on one screen on 2026-08-29.

  The takedown and imported-key tests came here from
  `SettingsTournamentLiveTest`, with the cards they exercise. The three
  sliders - On the results site, Automatically, and the before-round-1
  switch beside them - replaced the Published and Listed buttons and the
  publish-mode select on 2026-09-28.
  """
  # async: false: sequential SQLite writes plus self-broadcast/render ordering,
  # same rationale as the other Settings LiveView tests.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Audit, PublicDisplay, Publishing, Repo, Snapshot, Tournaments}

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(
          %{"name" => "Results LV Test", "type" => "swiss", "rounds_count" => "5"},
          attrs
        )
      )

    tournament
  end

  describe "the publish controls when there is no results site" do
    test "unconfigured and not publishing - no control, an explanation instead", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      refute Publishing.configured?()

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      refute has_element?(lv, "#site-presence")
      assert html =~ "No results site is set up yet"
      assert html =~ ~s|href="/fide"|
    end

    test "unconfigured but already publishing - the control stays, so it can be turned off", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, tournament} = Tournaments.set_publish_to_openresults(tournament, true)
      refute Publishing.configured?()

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      assert has_element?(lv, "#site-presence-off")
      refute html =~ "No results site is set up yet"

      html = lv |> element("#site-presence-off") |> render_click()
      refute Tournaments.get_tournament!(tournament.id).publish_to_openresults
      assert html =~ "will not be published again"
    end

    test "configured - the control renders at Off", %{conn: conn, scope: scope} do
      Publishing.put_endpoint("https://openresults.example/")
      Publishing.put_token("s3cret")

      tournament = create_tournament(scope)
      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      assert has_element?(lv, "#site-presence[data-level='0'][data-stops='3']")
      assert has_element?(lv, "#site-presence-off[aria-checked='true']")
      assert has_element?(lv, "#site-presence-link[aria-checked='false']")
      assert has_element?(lv, "#site-presence-listed[aria-checked='false']")
      refute html =~ "No results site is set up yet"
    end
  end

  describe "On the results site: Off · Link only · Listed" do
    setup do
      Publishing.put_endpoint("https://openresults.example/")
      Publishing.put_token("s3cret")
      Req.Test.set_req_test_to_shared(%{})
      :ok
    end

    test "defaults to UNLISTED - publishing is not advertising", %{scope: scope} do
      tournament = create_tournament(scope)

      # This defaulted to listed for a few hours on 2026-08-29 and produced a
      # front page nobody chose: sixteen tournaments appeared at once because
      # a migration had switched publishing on, not because sixteen arbiters
      # decided to advertise their events.
      refute tournament.public_listed
      assert Snapshot.build(tournament)["tournament"]["listed"] == false
    end

    test "Link only publishes without listing, and is audited as the old button was", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      html = lv |> element("#site-presence-link") |> render_click()
      assert html =~ "will be published"

      updated = Tournaments.get_tournament!(tournament.id)
      assert updated.publish_to_openresults
      refute updated.public_listed
      assert Publishing.queued(tournament.id)
      assert has_element?(lv, "#site-presence[data-level='1']")

      assert [log] = Audit.list_for_tournament(tournament.id, action: "openresults.toggled")
      assert log.details["enabled"] == true
      assert Audit.list_for_tournament(tournament.id, action: "openresults.listed") == []
    end

    test "Listed from Off lists before it publishes, so the first copy says so", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      lv |> element("#site-presence-listed") |> render_click()

      updated = Tournaments.get_tournament!(tournament.id)
      assert updated.publish_to_openresults
      assert updated.public_listed
      assert Snapshot.build(updated)["tournament"]["listed"] == true
      assert has_element?(lv, "#site-presence[data-level='2']")

      assert [_] = Audit.list_for_tournament(tournament.id, action: "openresults.listed")
      assert [_] = Audit.list_for_tournament(tournament.id, action: "openresults.toggled")
    end

    test "Listed and back to Link only only changes the listing", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, tournament} = Tournaments.set_publish_to_openresults(tournament, true)
      Repo.delete_all(PairingsEngine.Publishing.QueueEntry)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      html = lv |> element("#site-presence-listed") |> render_click()
      assert html =~ "will appear on the results site"
      # Putting something on a front page - or taking it off - and being told
      # "it will happen when the next result comes in" is not an answer.
      assert Publishing.queued(tournament.id)

      html = lv |> element("#site-presence-link") |> render_click()
      assert html =~ "no longer listed"

      updated = Tournaments.get_tournament!(tournament.id)
      assert updated.publish_to_openresults
      refute updated.public_listed
      assert Audit.list_for_tournament(tournament.id, action: "openresults.toggled") == []
      assert length(Audit.list_for_tournament(tournament.id, action: "openresults.listed")) == 2
    end

    test "going down to Off asks first, and only while publishing", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      refute has_element?(lv, "#site-presence-off[data-confirm]")

      lv |> element("#site-presence-link") |> render_click()

      assert has_element?(lv, "#site-presence-off[data-confirm*='Stop publishing']")
      refute has_element?(lv, "#site-presence-listed[data-confirm]")

      html = lv |> element("#site-presence-off") |> render_click()
      assert html =~ "will not be published again"
      refute Tournaments.get_tournament!(tournament.id).publish_to_openresults
    end

    test "choosing the stop it is already at does nothing", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      lv |> element("#site-presence-off") |> render_click()

      assert Audit.list_for_tournament(tournament.id) == []
    end

    test "says in as many words that Link only is not privacy", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      # An arbiter who reads "unlisted" as "private" will publish something
      # they meant to keep off the web. The page has to say so before they
      # click, not after.
      assert html =~ "Link only is not privacy"
      assert html =~ "still readable by anyone who has its address"
    end
  end

  describe "Automatically: By hand · Pairings once paired · + results live · + standings" do
    test "by hand is the default, and the slider says so", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      assert has_element?(lv, "#auto-publish[data-level='0'][data-stops='4']")
      assert has_element?(lv, "#auto-publish-0[aria-checked='true']", "By hand")
      assert has_element?(lv, "#auto-publish-1", "Pairings once paired")
      assert has_element?(lv, "#auto-publish-2", "+ results live")
      assert has_element?(lv, "#auto-publish-3", "+ standings when the round is finished")
      # No delay to set without the pairings step, and no Save button for it.
      refute has_element?(lv, "#publish-delay-form")
      # Scoped to this card: the hall display card and the entry form's
      # settings card below each have a Save button of their own, on purpose.
      refute has_element?(lv, "#auto-publish-card [type=submit]")
      assert html =~ "auto-publish-card"
      assert has_element?(lv, ~s|#registration-settings-form [type="submit"]|)
    end

    test "each stop saves its step at once, and is audited", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      for {level, mode} <- [{1, "pairings"}, {2, "results"}, {3, "standings"}, {0, "manual"}] do
        lv |> element("#auto-publish-#{level}") |> render_click()

        assert Tournaments.get_tournament!(tournament.id).publish_mode == mode
        assert has_element?(lv, "#auto-publish[data-level='#{level}']")
      end

      logs = Audit.list_for_tournament(tournament.id, action: "openresults.auto_publish")

      assert logs |> Enum.map(& &1.details["mode"]) |> Enum.sort() ==
               Enum.sort(~w(pairings results standings manual))
    end

    test "the pairings step's delay is inline, and saved as it is typed", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      lv |> element("#auto-publish-1") |> render_click()
      assert has_element?(lv, "#publish-delay-form #publish-delay-input")

      lv |> form("#publish-delay-form", %{"delay" => "12"}) |> render_change()

      updated = Tournaments.get_tournament!(tournament.id)
      assert updated.publish_mode == "pairings"
      assert updated.publish_delay_minutes == 12

      assert [log | _] =
               Audit.list_for_tournament(tournament.id, action: "openresults.auto_publish")

      assert log.details["delay_minutes"] == 12

      # Kept through by hand and back.
      lv |> element("#auto-publish-0") |> render_click()
      refute has_element?(lv, "#publish-delay-form")
      lv |> element("#auto-publish-3") |> render_click()
      assert has_element?(lv, "#publish-delay-input[value='12']")
    end

    test "a delay that is not a whole number of minutes is said, not saved", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"publish_mode" => "pairings"})
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      html = lv |> form("#publish-delay-form", %{"delay" => "-3"}) |> render_change()

      assert html =~ "whole number of minutes"
      assert Tournaments.get_tournament!(tournament.id).publish_delay_minutes == 0
    end

    test "a round paired afterwards follows the chosen step", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      for n <- 1..4,
          do: {:ok, _} = Tournaments.create_player(tournament.id, %{"name" => "P#{n}"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")
      lv |> element("#auto-publish-2") |> render_click()

      {:ok, round} =
        PairingsEngine.Pairing.pair_next_round(Tournaments.get_tournament!(tournament.id))

      t = Tournaments.get_tournament!(tournament.id)
      round = Tournaments.get_round(t.id, round.number)

      assert Tournaments.round_published?(t, round)
      assert Tournaments.results_public?(t, round)
      assert Tournaments.round_publish_state(t, round).level == 2
    end

    test "raising the automation over rounds already public asks first", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"publish_mode" => "pairings"})
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      # Nothing public yet: nothing to warn about.
      refute has_element?(lv, "#auto-publish-2[data-confirm]")

      Repo.insert!(%PairingsEngine.Tournaments.Round{
        tournament_id: tournament.id,
        number: 1,
        status: "playing",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      assert has_element?(lv, "#auto-publish-2[data-confirm*='already public']")
      assert has_element?(lv, "#auto-publish-3[data-confirm]")
      # Going down takes nothing off the site, so it asks nothing.
      refute has_element?(lv, "#auto-publish-0[data-confirm]")
    end
  end

  describe "Before round 1, spectators see the starting ranking" do
    test "off by default; switching it on and off is saved and audited", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      assert has_element?(lv, "#initial-standings-toggle[aria-checked='false']")

      lv |> element("#initial-standings-toggle") |> render_click()

      assert has_element?(lv, "#initial-standings-toggle[aria-checked='true']")
      assert Tournaments.get_tournament!(tournament.id).standings_through == 0
      assert [log] = Audit.list_for_tournament(tournament.id, action: "standings.published")
      assert log.details["through_round"] == 0

      # Switching it off asks first.
      assert has_element?(lv, "#initial-standings-toggle[data-confirm]")
      lv |> element("#initial-standings-toggle") |> render_click()

      assert Tournaments.get_tournament!(tournament.id).standings_through == nil
      assert [log] = Audit.list_for_tournament(tournament.id, action: "standings.unpublished")
      assert log.details["from_round"] == 0
    end

    test "the roster reaches the snapshot only while it is on", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _} = Tournaments.create_player(tournament.id, %{"name" => "Solo"})
      assert Snapshot.build(Tournaments.get_tournament!(tournament.id))["players"] == []

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")
      lv |> element("#initial-standings-toggle") |> render_click()

      assert [%{"name" => "Solo"}] =
               Snapshot.build(Tournaments.get_tournament!(tournament.id))["players"]
    end

    test "cannot be changed once a round is public", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      Repo.insert!(%PairingsEngine.Tournaments.Round{
        tournament_id: tournament.id,
        number: 1,
        status: "playing",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      assert has_element?(lv, "#initial-standings-toggle[disabled]")
    end
  end

  describe "the retired Standings and Round pairings switches" do
    test "are not offered", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      refute html =~ ~s|name="display[standings]"|
      refute html =~ ~s|name="display[pairings]"|
      assert html =~ ~s|name="display[player_cards]"|
      refute has_element?(lv, "[id^='legacy-page-']")
    end

    test "a page one of them kept off stays off, with a way to show it", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      tournament
      |> Ecto.Changeset.change(public_display: %{"standings" => false, "club" => false})
      |> Repo.update!()

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      assert has_element?(lv, "#legacy-page-standings")
      refute has_element?(lv, "#legacy-page-pairings")

      # Ticking the other boxes does not bring it back.
      render_change(lv, "save_display", %{
        "display" => PublicDisplay.keys() |> Map.new(&{&1, "true"})
      })

      reloaded = Tournaments.get_tournament!(tournament.id)
      assert reloaded.public_display["standings"] == false
      refute Map.has_key?(reloaded.public_display, "club")
      assert Snapshot.build(reloaded)["tournament"]["display"]["standings"] == false

      assert has_element?(lv, "#show-legacy-page-standings[data-confirm]")
      lv |> element("#show-legacy-page-standings") |> render_click()

      reloaded = Tournaments.get_tournament!(tournament.id)
      refute Map.has_key?(reloaded.public_display, "standings")
      assert Snapshot.build(reloaded)["tournament"]["display"]["standings"] == true
      refute has_element?(lv, "#legacy-page-standings")
      assert [_ | _] = Audit.list_for_tournament(tournament.id, action: "openresults.display")
    end
  end

  describe "the address on the page" do
    test "the real address renders once published, a plain description before that", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/results")
      refute html =~ "https://openresults.example/t/"

      Publishing.put_endpoint("https://openresults.example/")
      {:ok, tournament} = Tournaments.set_publish_to_openresults(tournament, true)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/results")
      assert html =~ "https://openresults.example/t/#{tournament.public_slug}"
    end
  end

  describe "the page stays inside the tournament" do
    test "the top bar keeps the tournament's own tabs", %{conn: conn, scope: scope} do
      # Without `tournament=` on the layout the bar drops Players, Pairings,
      # Standings and Print, and its Home link becomes "Tournaments" - so
      # opening this page read as having left the tournament for a global
      # settings screen. Reported from the live site on 2026-08-30.
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      assert html =~ ~s|href="/t/#{tournament.id}/players"|
      assert html =~ ~s|href="/t/#{tournament.id}/pairings"|
      assert html =~ ~s|href="/t/#{tournament.id}/standings"|
    end

    test "and matches what the other settings pages do", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, _lv, results} = live(conn, ~p"/t/#{tournament.id}/settings/results")
      {:ok, _lv, tournament_page} = live(conn, ~p"/t/#{tournament.id}/settings")

      for path <- ~w(players pairings standings print) do
        href = ~s|href="/t/#{tournament.id}/#{path}"|

        assert results =~ href == (tournament_page =~ href),
               "settings/results and settings disagree about #{path}"
      end
    end
  end

  describe "what the public page shows" do
    setup do
      Publishing.put_endpoint("https://openresults.example/")
      Publishing.put_token("s3cret")
      Req.Test.set_req_test_to_shared(%{})
      :ok
    end

    test "everything is shown until an arbiter says otherwise", %{scope: scope} do
      tournament = create_tournament(scope)

      assert tournament.public_display == nil

      display = Snapshot.build(tournament)["tournament"]["display"]

      assert Enum.sort(Map.keys(display)) ==
               Enum.sort(PublicDisplay.keys() ++ PublicDisplay.legacy_keys())

      # ...with one exception, and the resolved map states it rather than
      # leaving the reader to infer it: the attendance column is opt-in, so a
      # tournament that has said nothing is not publishing it. See
      # `PairingsEngine.PublicDisplay`'s moduledoc for why it is the only key
      # that leans this way.
      assert display["rounds_played"] == false
      assert Enum.all?(Map.values(Map.delete(display, "rounds_played")))
    end

    test "unticking a box hides that column and nothing else", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      # `phx-change` on the form: every ticked box is sent, unticked ones are
      # simply absent, which is what `PublicDisplay.cast/1` reads.
      ticked =
        PublicDisplay.keys()
        |> Enum.reject(&(&1 == "club"))
        |> Map.new(&{&1, "true"})

      render_change(lv, "save_display", %{"display" => ticked})

      display = Tournaments.get_tournament!(tournament.id) |> Snapshot.build()
      display = display["tournament"]["display"]

      refute display["club"]
      assert display["rating"]
      assert display["player_cards"]
    end

    test "a checkbox per tie-break the tournament ranks on", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"tiebreaks" => ~w(BHC1 BH SB)})
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      assert html =~ ~s|name="tiebreak[BHC1]"|
      assert html =~ ~s|name="tiebreak[BH]"|
      assert html =~ ~s|name="tiebreak[SB]"|
      # Not a code this tournament does not use.
      refute html =~ ~s|name="tiebreak[KS]"|
    end

    test "unticking one keeps it out of the published document", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"tiebreaks" => ~w(BHC1 BH SB)})
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      render_change(lv, "save_display", %{
        "display" => Map.new(PublicDisplay.keys(), &{&1, "true"}),
        "tiebreak" => %{"BHC1" => "true", "SB" => "true"}
      })

      reloaded = Tournaments.get_tournament!(tournament.id)
      assert reloaded.public_hidden_tiebreaks == ["BH"]

      standings = Snapshot.build(reloaded)["standings"]
      assert Enum.map(standings["tiebreaks"], & &1["code"]) == ~w(BHC1 SB)
    end

    test "the page warns that a hidden tie-break still decides the order", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"tiebreaks" => ~w(BHC1 BH)})
      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      refute html =~ "keeps deciding placings"

      html =
        render_change(lv, "save_display", %{
          "display" => Map.new(PublicDisplay.keys(), &{&1, "true"}),
          "tiebreak" => %{"BHC1" => "true"}
        })

      assert html =~ "keeps deciding placings"
    end

    test "the tie-break block is gone when the columns are off", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"tiebreaks" => ~w(BHC1 BH)})
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      html =
        render_change(lv, "save_display", %{
          "display" =>
            PublicDisplay.keys() |> Enum.reject(&(&1 == "tiebreaks")) |> Map.new(&{&1, "true"})
        })

      refute html =~ ~s|name="tiebreak[BHC1]"|
    end

    test "the working can be turned off without losing the columns", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"tiebreaks" => ~w(BHC1 BH)})
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      render_change(lv, "save_display", %{
        "display" =>
          PublicDisplay.keys()
          |> Enum.reject(&(&1 == "tiebreak_working"))
          |> Map.new(&{&1, "true"}),
        "tiebreak" => %{"BHC1" => "true", "BH" => "true"}
      })

      standings =
        Tournaments.get_tournament!(tournament.id) |> Snapshot.build() |> Map.fetch!("standings")

      assert Enum.map(standings["tiebreaks"], & &1["code"]) == ~w(BHC1 BH)
      assert Enum.all?(standings["rows"], &(&1["working"] == %{}))
    end

    test "the stored map records only what was turned OFF", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      render_change(lv, "save_display", %{"display" => %{"rating" => "true"}})

      # Storing the positives too would pin every future key to today's
      # default on every tournament that has ever visited this page.
      stored = Tournaments.get_tournament!(tournament.id).public_display
      assert Enum.all?(Map.values(stored), &(&1 == false))
      refute Map.has_key?(stored, "rating")
    end

    test "the snapshot always carries a resolved answer, never the sparse map", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      render_change(lv, "save_display", %{"display" => %{"rating" => "true"}})

      display = Tournaments.get_tournament!(tournament.id) |> Snapshot.build()
      display = display["tournament"]["display"]

      # A reader must not have to know this app's default list to interpret
      # the answer.
      assert Enum.sort(Map.keys(display)) ==
               Enum.sort(PublicDisplay.keys() ++ PublicDisplay.legacy_keys())

      assert display["rating"] == true
      assert display["club"] == false
    end

    test "names and results are not offered as hideable", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      refute html =~ ~s|name="display[name]"|
      refute html =~ ~s|name="display[result]"|
      assert html =~ "they are the tournament"
    end
  end

  describe "the hall display card" do
    setup do
      Publishing.put_endpoint("https://openresults.example/")
      Publishing.put_token("s3cret")
      Req.Test.set_req_test_to_shared(%{})
      :ok
    end

    defp hall_params(overrides) do
      Map.merge(
        %{
          "pairings" => "true",
          "names" => "true",
          "results" => "true",
          "standings" => "true",
          "standings_top" => "10",
          "page_seconds" => "15",
          "hold_new_round" => "true",
          "announcement" => ""
        },
        overrides
      )
    end

    test "renders the form with the defaults, and no address before publishing", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      assert has_element?(lv, "#hall-display-card")
      assert has_element?(lv, "#hall-display-form")
      assert has_element?(lv, "#hall-display-save")

      assert has_element?(
               lv,
               "#hall-display-form input[type=checkbox][name='hall[names]'][checked]"
             )

      assert has_element?(lv, "#hall-display-form input[name='hall[page_seconds]'][value='15']")
      assert has_element?(lv, "#hall-display-form textarea[name='hall[announcement]']")
      refute has_element?(lv, "#hall-display-open")
    end

    test "the hall address is offered once the tournament is public", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, tournament} = Tournaments.set_publish_to_openresults(tournament, true)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      url = "https://openresults.example/t/#{tournament.public_slug}/hall"
      assert has_element?(lv, "#hall-display-open[href='#{url}']")
      assert has_element?(lv, "#hall-display-url", url)
    end

    test "saving stores the settings, enqueues a publish and is audited", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, tournament} = Tournaments.set_publish_to_openresults(tournament, true)
      Repo.delete_all(PairingsEngine.Publishing.QueueEntry)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      lv
      |> form("#hall-display-form",
        hall:
          hall_params(%{
            "standings" => "false",
            "page_seconds" => "30",
            "announcement" => "Round 5 starts at 14:00.\r\nNo phones."
          })
      )
      |> render_submit()

      hall = Tournaments.get_tournament!(tournament.id) |> Snapshot.build()
      hall = hall["tournament"]["hall"]

      assert hall["standings"] == false
      assert hall["page_seconds"] == 30
      assert hall["announcement"] == "Round 5 starts at 14:00.\nNo phones."
      assert Publishing.queued(tournament.id)

      assert [log] = Audit.list_for_tournament(tournament.id, action: "openresults.hall")
      assert log.details["page_seconds"] == 30
      # Whether there is one, never the text itself.
      assert log.details["announcement"] == true
    end

    test "an out-of-range number is an inline error and nothing is saved", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      lv
      |> form("#hall-display-form", hall: hall_params(%{"page_seconds" => "3"}))
      |> render_submit()

      assert has_element?(lv, "#hall-display-form input[name='hall[page_seconds]'][aria-invalid]")
      assert has_element?(lv, "#hall-display-form input[name='hall[page_seconds]'][value='3']")
      assert Tournaments.get_tournament!(tournament.id).public_hall == nil
      assert Audit.list_for_tournament(tournament.id, action: "openresults.hall") == []
    end

    test "a too-long announcement is an inline error and nothing is saved", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      lv
      |> form("#hall-display-form",
        hall: hall_params(%{"announcement" => String.duplicate("x", 501)})
      )
      |> render_submit()

      assert has_element?(
               lv,
               "#hall-display-form textarea[name='hall[announcement]'][aria-invalid]"
             )

      assert Tournaments.get_tournament!(tournament.id).public_hall == nil
    end

    test "an archived tournament refuses the change", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")
      {:ok, _archived} = Tournaments.archive_tournament(tournament)

      html =
        lv
        |> form("#hall-display-form", hall: hall_params(%{"names" => "false"}))
        |> render_submit()

      assert html =~ "archived"
      assert Tournaments.get_tournament!(tournament.id).public_hall == nil
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

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      # The switch being on is a promise about the future. There is nothing
      # out there to take down until a publish has landed.
      refute html =~ "Remove from the results site"
    end

    test "says what goes before it goes", %{conn: conn, scope: scope} do
      tournament = scope |> create_tournament() |> publish_once()

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      assert html =~ "Remove from the results site"
      # An arbiter can reasonably assume this hides a page. The two things
      # they would otherwise only discover afterwards are named.
      assert html =~ "every earlier snapshot in its history"
      assert html =~ "any entries collected for it"
    end

    test "a successful takedown turns publishing off and says so", %{conn: conn, scope: scope} do
      tournament = scope |> create_tournament() |> publish_once()
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

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
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

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

      {:ok, _lv, html} = live(conn, ~p"/t/#{imported.id}/settings/results")

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
      {:ok, lv, _html} = live(conn, ~p"/t/#{imported.id}/settings/results")

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

      {:ok, lv, _html} = live(conn, ~p"/t/#{imported.id}/settings/results")
      html = lv |> element("button", "Take over publishing it") |> render_click()

      assert html =~ "now publishes to the address the backup came from"

      adopted = Tournaments.get_tournament!(imported.id)
      assert adopted.openresults_key == source.openresults_key
      assert adopted.public_slug == source.public_slug
      refute adopted.openresults_claim
    end

    test "a tournament with no claim is offered nothing", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      refute html =~ "A publishing key came with this file"
    end
  end
end
