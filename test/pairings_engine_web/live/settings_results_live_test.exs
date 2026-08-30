defmodule PairingsEngineWeb.SettingsResultsLiveTest do
  @moduledoc """
  The Results site settings page - everything about a tournament's public
  existence, gathered on one screen on 2026-08-29.

  The takedown and imported-key tests came here from
  `SettingsTournamentLiveTest`, and the "Public pairings publish mode card"
  tests from `SettingsOptionsLiveTest`, with the cards they exercise. The
  rest is new, and covers the controls the page was created for.
  """
  # async: false: sequential SQLite writes plus self-broadcast/render ordering,
  # same rationale as the other Settings LiveView tests.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{PublicDisplay, Publishing, Repo, Snapshot, Tournaments}

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

  describe "listing a tournament on the front page" do
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

    test "listing travels in the snapshot", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      html = lv |> element("button", "List it") |> render_click()
      assert html =~ "will appear on the results site"

      updated = Tournaments.get_tournament!(tournament.id)
      assert updated.public_listed
      assert Snapshot.build(updated)["tournament"]["listed"] == true

      # And back off again.
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")
      html = lv |> element("button", "Unlist it") |> render_click()
      assert html =~ "no longer listed"

      assert Snapshot.build(Tournaments.get_tournament!(tournament.id))["tournament"]["listed"] ==
               false
    end

    test "says in as many words that it is not privacy", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      # An arbiter who reads "unlisted" as "private" will publish something
      # they meant to keep off the web. The page has to say so before they
      # click, not after.
      assert html =~ "This is not privacy"
      assert html =~ "still readable by anyone who has its address"
    end

    test "changing the listing pushes rather than waiting for the next result", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, tournament} = Tournaments.set_publish_to_openresults(tournament, true)
      Repo.delete_all(PairingsEngine.Publishing.QueueEntry)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")
      lv |> element("button", "List it") |> render_click()

      # Putting something on a front page - or taking it off - and being told
      # "it will happen when the next result comes in" is not an answer.
      assert Publishing.queued(tournament.id)
    end
  end

  describe "Public pairings publish mode card" do
    test "defaults to Immediately and renders every mode option", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      assert html =~ "Public pairings"
      assert html =~ "Publish each round"
      assert html =~ "Immediately"
      assert html =~ "Manually"
      assert html =~ "After a delay"
      assert html =~ "On the round&#39;s own date"
    end

    test "switching to manual mode saves it", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      lv
      |> form("#publish-settings-form", %{"tournament" => %{"publish_mode" => "manual"}})
      |> render_submit()

      assert Tournaments.get_authorized_tournament!(scope, tournament.id).publish_mode == "manual"
    end

    test "switching to timed mode with a delay saves both fields", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      # The "Delay (minutes)" field only renders once the mode select is
      # actually switched to "timed" (see the "field is hidden by default"
      # / "appears live" tests below) - flip it first so the form the
      # submit below reads from actually has the field in it.
      lv
      |> element("select[name='tournament[publish_mode]']")
      |> render_change(%{"tournament" => %{"publish_mode" => "timed"}})

      lv
      |> form("#publish-settings-form", %{
        "tournament" => %{"publish_mode" => "timed", "publish_delay_minutes" => "20"}
      })
      |> render_submit()

      updated = Tournaments.get_authorized_tournament!(scope, tournament.id)
      assert updated.publish_mode == "timed"
      assert updated.publish_delay_minutes == 20
    end

    test "the \"Delay (minutes)\" field is hidden by default (mode is Immediately)", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      refute html =~ "Delay (minutes)"
    end

    test "the \"Delay (minutes)\" field appears live when the mode is switched to 'timed', and hides again when switched away",
         %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      html =
        lv
        |> element("select[name='tournament[publish_mode]']")
        |> render_change(%{"tournament" => %{"publish_mode" => "timed"}})

      assert html =~ "Delay (minutes)"

      html =
        lv
        |> element("select[name='tournament[publish_mode]']")
        |> render_change(%{"tournament" => %{"publish_mode" => "manual"}})

      refute html =~ "Delay (minutes)"
    end

    test "a tournament already saved in 'timed' mode shows the Delay field on initial render", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, _updated} =
        Tournaments.update_tournament(tournament, %{
          "publish_mode" => "timed",
          "publish_delay_minutes" => "15"
        })

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/results")

      assert html =~ "Delay (minutes)"
    end

    test "the real address renders once published, a plain description before that", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/results")
      assert html =~ "this tournament&#39;s page on the results site"

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
      assert Enum.sort(Map.keys(display)) == Enum.sort(PublicDisplay.keys())
      assert Enum.all?(Map.values(display))
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
      assert Enum.sort(Map.keys(display)) == Enum.sort(PublicDisplay.keys())
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
