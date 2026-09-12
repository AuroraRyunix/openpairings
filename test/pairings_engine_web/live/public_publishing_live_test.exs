defmodule PairingsEngineWeb.PublicPublishingLiveTest do
  @moduledoc """
  Public publishing as an arbiter meets it: the consent dialog, what a
  tournament waits on, "Register again", and - on every surface that can
  show one - no public link or QR code before the results site has created
  the address.

  The server is `PairingsEngine.PublicServerStub`, shared with the LiveView
  process (`set_req_test_to_shared`), so every request the page makes is
  reported to the test and "nothing was sent" is an assertion rather than a
  hope.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias PairingsEngine.{Audit, Publishing, Repo, Tournaments}
  alias PairingsEngine.PublicServerStub, as: Server
  alias PairingsEngine.Publishing.{Installation, QueueEntry}
  alias PairingsEngine.Tournaments.Player
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngineWeb.Components.ConnectionStatus

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:pairings_engine, :local_mode)
    Application.put_env(:pairings_engine, :local_mode, true)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:pairings_engine, :local_mode)
        value -> Application.put_env(:pairings_engine, :local_mode, value)
      end
    end)

    Publishing.put_endpoint(nil)
    Publishing.put_public_base(nil)
    Publishing.put_token(nil)
    Req.Test.set_req_test_to_shared(%{})
    Server.install(self())
    :ok
  end

  defp create_tournament(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Public Open", "type" => "swiss", "rounds_count" => "3"}, attrs)
      )

    tournament
  end

  defp paired(tournament) do
    for {name, n} <- [{"A", 1}, {"B", 2}] do
      Repo.insert!(%Player{tournament_id: tournament.id, name: name, pairing_number: n})
    end

    {:ok, _} = Engine.pair_next_round(tournament)
    Tournaments.get_tournament!(tournament.id)
  end

  defp register! do
    {:ok, info} = Installation.server_info()
    Installation.give_consent(info)
    {:ok, _} = Installation.register()
    Server.requests()
    :ok
  end

  defp results_page(conn, tournament), do: live(conn, ~p"/t/#{tournament.id}/settings/results")

  describe "turning publishing on for the first time" do
    test "the page sends nothing until the switch is pressed", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, html} = results_page(conn, tournament)
      render(lv)

      assert html =~ "Turn on"
      assert Server.requests() == []
    end

    test "asks first, naming the operator and linking the terms", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = results_page(conn, tournament)

      lv |> element("button", "Turn on") |> render_click()
      html = render_async(lv)

      assert html =~ "Publish on openresults.zerotwo.cloud?"
      assert html =~ "is run by ZeroTwo"
      assert html =~ ~s|href="https://openresults.zerotwo.cloud/terms"|
      assert html =~ "Agree and publish"

      # Only the question has gone out, and it carried no credential.
      assert [{"GET", "/api/server", headers, _}] = Server.requests()
      refute headers["authorization"]
    end

    test "names the host when the server does not say who runs it", %{conn: conn, scope: scope} do
      Server.install(self(), %{
        {"GET", "/api/server"} =>
          &Server.json(&1, 200, Server.server_body(%{"operator" => nil, "terms_url" => nil}))
      })

      tournament = create_tournament(scope)
      {:ok, lv, _html} = results_page(conn, tournament)
      lv |> element("button", "Turn on") |> render_click()
      html = render_async(lv)

      assert html =~ "Publish on openresults.zerotwo.cloud?"
      refute html =~ "is run by"
      refute html =~ "terms"
    end

    test "declining sends nothing and leaves publishing off", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = results_page(conn, tournament)

      lv |> element("button", "Turn on") |> render_click()
      render_async(lv)
      assert [{"GET", "/api/server", _, _}] = Server.requests()

      html = lv |> element("#public-consent button", "Do not publish") |> render_click()

      assert html =~ "Nothing was sent. Publishing is off for this tournament."
      refute Tournaments.get_tournament!(tournament.id).publish_to_openresults
      refute Publishing.queued(tournament.id)
      refute Installation.consented?()

      # And nothing afterwards either - not the drain, not a check.
      assert {0, 0} = Publishing.drain()
      Publishing.check()
      assert Server.requests() == []
    end

    test "agreeing records it - the operator, not a key - and the drain does the rest", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = results_page(conn, tournament)

      lv |> element("button", "Turn on") |> render_click()
      render_async(lv)
      html = lv |> element("#public-consent button", "Agree and publish") |> render_click()

      assert html =~ "registers with openresults.zerotwo.cloud"
      assert Installation.consented?()
      Server.requests()

      [entry] =
        Audit.list_for_tournament(tournament.id)
        |> Enum.filter(&(&1.action == "openresults.public_consent_given"))

      assert entry.details["operator"] == "ZeroTwo"

      assert {1, 0} = Publishing.drain()

      assert Enum.map(Server.requests(), fn {m, p, _, _} -> {m, p} end) == [
               {"POST", "/api/installations"},
               {"POST", "/api/tournaments"},
               {"POST", "/api/snapshots"}
             ]

      minted = Tournaments.get_tournament!(tournament.id)
      {:ok, _lv, html} = results_page(conn, minted)
      assert html =~ "https://openresults.zerotwo.cloud/t/#{minted.public_slug}"

      # Custody: the page never renders the key, and nor does the audit trail.
      refute html =~ Server.key()
      refute inspect(Audit.list_for_tournament(tournament.id)) =~ "orik_"
    end

    test "a server that needs a token says so and puts publishing back off", %{
      conn: conn,
      scope: scope
    } do
      Server.install(self(), %{
        {"GET", "/api/server"} =>
          &Server.json(
            &1,
            200,
            Server.server_body(%{
              "public_registration" => "unavailable",
              "public_publishing" => "unavailable"
            })
          )
      })

      tournament = create_tournament(scope)
      {:ok, lv, _html} = results_page(conn, tournament)
      lv |> element("button", "Turn on") |> render_click()
      html = render_async(lv)

      assert html =~ "only publishes tournaments sent with a token from its operator"
      refute html =~ "Agree and publish"
      refute Tournaments.get_tournament!(tournament.id).publish_to_openresults
      refute Publishing.queued(tournament.id)
    end

    test "offline: publishing stays requested and the page says what it waits for", %{
      conn: conn,
      scope: scope
    } do
      Server.install(self(), %{
        {"GET", "/api/server"} => &Req.Test.transport_error(&1, :econnrefused)
      })

      tournament = create_tournament(scope)
      {:ok, lv, _html} = results_page(conn, tournament)
      lv |> element("button", "Turn on") |> render_click()
      html = render_async(lv)

      assert html =~ "The connection was refused"
      assert html =~ "Publishing stays on for this tournament"
      assert Tournaments.get_tournament!(tournament.id).publish_to_openresults
      assert Publishing.queued(tournament.id)

      html = lv |> element("#public-consent button", "Close") |> render_click()
      assert html =~ "Waiting for your go-ahead"
      assert html =~ ~s|phx-click="public_consent_open"|
      refute html =~ "Share link"
    end
  end

  describe "no public link or QR code before the address exists" do
    setup %{scope: scope} do
      register!()
      tournament = scope |> create_tournament() |> paired()
      {:ok, tournament} = Tournaments.set_publish_to_openresults(tournament, true)
      Server.requests()
      {:ok, tournament: tournament}
    end

    defp no_link!(html, tournament) do
      refute html =~ "/t/#{tournament.public_slug}"
      refute html =~ "openresults.zerotwo.cloud/t/"
    end

    test "on every surface, until the mint - then on every surface", %{conn: conn, tournament: t} do
      {:ok, _lv, results} = results_page(conn, t)
      {:ok, _lv, pairings} = live(conn, ~p"/t/#{t.id}/pairings")
      {:ok, _lv, standings} = live(conn, ~p"/t/#{t.id}/standings")
      {:ok, _lv, live_view} = live(conn, ~p"/t/#{t.id}/live")

      for html <- [results, pairings, standings, live_view], do: no_link!(html, t)

      refute results =~ "Share link"
      assert results =~ "Waiting for the results site to create this tournament&#39;s address"
      assert results =~ "The form opens on the results site once it has created"
      refute pairings =~ "Public page"
      refute standings =~ "Public page"
      refute live_view =~ "enroll-qr-inner"
      assert live_view =~ "the results site has not created its address yet"

      # The mint, through the queue.
      assert {1, 0} = Publishing.drain()
      minted = Tournaments.get_tournament!(t.id)
      link = "https://openresults.zerotwo.cloud/t/#{minted.public_slug}"

      {:ok, _lv, results} = results_page(conn, minted)
      {:ok, _lv, pairings} = live(conn, ~p"/t/#{t.id}/pairings")
      {:ok, _lv, standings} = live(conn, ~p"/t/#{t.id}/standings")
      {:ok, _lv, live_view} = live(conn, ~p"/t/#{t.id}/live")

      assert results =~ "Share link"
      assert results =~ link
      assert pairings =~ link
      assert standings =~ link
      assert live_view =~ "enroll-qr-inner"
      assert live_view =~ link
    end

    test "the placeholder slug never reaches the snapshot either", %{tournament: t} do
      assert {1, 0} = Publishing.drain()

      snapshot =
        Enum.find_value(Server.requests(), fn
          {"POST", "/api/snapshots", _, body} -> Jason.decode!(body)
          _ -> nil
        end)

      refute snapshot["tournament"]["slug"] == t.public_slug
    end
  end

  describe "a tournament the server stopped" do
    test "not_owner names the slug and this installation, and Try again sends it again", %{
      conn: conn,
      scope: scope
    } do
      register!()
      tournament = create_tournament(scope)
      {:ok, tournament} = Tournaments.set_publish_to_openresults(tournament, true)

      Server.install(self(), %{{"POST", "/api/snapshots"} => Server.error(403, "not_owner")})
      capture_log(fn -> Publishing.drain() end)
      stopped = Tournaments.get_tournament!(tournament.id)

      {:ok, lv, html} = results_page(conn, stopped)
      assert html =~ "A different installation owns this tournament"
      assert html =~ stopped.public_slug
      assert html =~ Server.installation_id()
      refute html =~ Server.key()

      Server.install(self())
      lv |> element("#public-steps button", "Try again") |> render_click()
      refute Repo.one(from q in QueueEntry, where: q.tournament_id == ^tournament.id).stopped_at
    end
  end

  describe "register again" do
    setup %{scope: scope} do
      register!()
      tournament = create_tournament(scope)
      {:ok, tournament} = Tournaments.set_publish_to_openresults(tournament, true)

      Server.install(self(), %{
        {"POST", "/api/snapshots"} => Server.error(403, "installation_revoked")
      })

      capture_log(fn -> Publishing.drain() end)
      Server.install(self())
      Server.requests()
      {:ok, tournament: tournament}
    end

    test "is offered, never done: pressing it asks again, and only agreeing replaces the key", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, lv, html} = results_page(conn, tournament)
      assert html =~ "no longer accepts this computer&#39;s key"
      assert html =~ "Register again"

      # Nothing registered by the page being looked at.
      assert Server.calls() == []

      lv |> element("#public-steps button", "Register again") |> render_click()
      html = render_async(lv)
      assert html =~ "old key is no longer accepted"

      lv |> element("#public-consent button", "Register again") |> render_click()
      refute Installation.stopping_state?()
      refute Installation.registered?()
      assert Installation.consented?()

      assert {1, 0} = Publishing.drain()
      assert {"POST", "/api/installations"} in Server.calls()
    end

    test "the Connections panel offers it too, and shows no Test button", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/fide")

      assert html =~ "no longer accepts this computer&#39;s key"
      assert html =~ "Register again"
      refute html =~ "Test connection"
      refute html =~ Server.key()

      lv |> element("#public-installation button", "Register again") |> render_click()
      html = render_async(lv)
      assert html =~ "old key is no longer accepted"

      lv |> element("#public-consent button", "Cancel") |> render_click()
      assert Installation.stopping_state?()
      assert Server.calls() == [{"GET", "/api/server"}]
    end
  end

  describe "the Connections panel in public mode" do
    test "says what will happen, shows the installation id and never the key", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/fide")
      assert html =~ "Without a token, this computer publishes to openresults.zerotwo.cloud"
      refute html =~ "Test connection"
      refute html =~ "Nothing is published until both an address and a token are set."
      assert Server.requests() == []

      register!()
      {:ok, _lv, html} = live(conn, ~p"/fide")

      assert html =~
               "registered with the results site as installation #{Server.installation_id()}"

      refute html =~ Server.key()
    end

    test "saving the address sends nothing", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/fide")

      lv
      |> form("#fide-publishing-form", %{"endpoint" => "", "public_base" => "", "token" => ""})
      |> render_submit()

      assert Server.requests() == []
    end
  end

  describe "the indicator in both languages" do
    defp card(status, locale) do
      html =
        Gettext.with_locale(PairingsEngineWeb.Gettext, locale, fn ->
          render_component(&ConnectionStatus.connection_status/1, status: status)
        end)

      [_, tone] = Regex.run(~r/class="conn-status is-(\w+)/, html)
      [_, headline] = Regex.run(~r/<strong>([^<]*)<\/strong>/, html)
      [_, detail] = Regex.run(~r/<p class="conn-detail">([^<]*)<\/p>/, html)
      {tone, String.trim(headline), detail |> String.trim() |> String.replace("&#39;", "'")}
    end

    test "idle, waiting, connected, paused and revoked", %{scope: scope} do
      assert card(Publishing.status(), "en") ==
               {"off", "Not publishing",
                "No tournament on this computer is being published, so nothing is sent to the results site."}

      assert card(Publishing.status(), "nl") ==
               {"off", "Publiceert niet",
                "Geen enkel toernooi op deze computer wordt gepubliceerd, dus er wordt niets naar de uitslagensite verzonden."}

      tournament = create_tournament(scope)
      {:ok, _} = Tournaments.set_publish_to_openresults(tournament, true)

      assert card(Publishing.status(), "en") ==
               {"refused", "Waiting for your go-ahead",
                "Publishing is waiting for your go-ahead to register this computer with the results site. Nothing has been sent yet."}

      assert card(Publishing.status(), "nl") ==
               {"refused", "Wacht op je toestemming",
                "Publiceren wacht op je toestemming om deze computer bij de uitslagensite te registreren. Er is nog niets verzonden."}

      assert Server.requests() == []

      register!()
      status = %{Publishing.status() | pending: 0}

      assert card(status, "en") ==
               {"ok", "Connected",
                "This computer publishes with a key of its own, no token needed."}

      assert card(status, "nl") ==
               {"ok", "Verbonden",
                "Deze computer publiceert met een eigen sleutel, zonder token."}

      Server.install(self(), %{
        {"GET", "/api/server"} =>
          &Server.json(&1, 200, Server.server_body(%{"public_publishing" => "paused"}))
      })

      paused = %{Publishing.status() | pending: 0}
      assert {"refused", "Publishing paused", _} = card(paused, "en")
      assert {"refused", "Publiceren gepauzeerd", _} = card(paused, "nl")

      Installation.put_state({:rejected, 403, "installation_revoked", nil})
      revoked = %{Publishing.status() | pending: 0}

      assert card(revoked, "en") ==
               {"down", "Refused by the results site",
                "The results site no longer accepts this computer's key. Publishing has stopped."}

      assert card(revoked, "nl") ==
               {"down", "Geweigerd door de uitslagensite",
                "De uitslagensite aanvaardt de sleutel van deze computer niet meer. Publiceren is gestopt."}
    end
  end
end
