defmodule PairingsEngineWeb.DeployNoticeTest do
  @moduledoc """
  The "this server restarts in N minutes" warning: the state that holds it,
  the endpoint the deploy script calls, and the banner every open page shows.
  """
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.Deploy

  setup do
    # Every test leaves the notice clear, or the next one inherits a banner.
    on_exit(fn -> Deploy.cancel() end)
    :ok
  end

  describe "the notice itself" do
    test "announcing sets a deadline and tells pages that are already open" do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Deploy.topic())

      assert {:ok, restart_at} = Deploy.announce(600)

      assert_receive {:deploy_notice, ^restart_at}
      assert Deploy.restart_at() == restart_at

      # ~10 minutes out, allowing for the clock moving during the call.
      assert DateTime.diff(restart_at, DateTime.utc_now()) in 595..600
    end

    test "a page opening MID-countdown still sees it" do
      # The whole reason a deadline is stored rather than only broadcast: an
      # arbiter who opens the results page two minutes in is exactly the
      # person the warning exists for, and a broadcast reaches nobody who
      # was not already connected.
      {:ok, restart_at} = Deploy.announce(600)

      assert Deploy.restart_at() == restart_at
    end

    test "cancelling clears it and says so" do
      {:ok, _} = Deploy.announce(600)
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Deploy.topic())

      assert :ok = Deploy.cancel()

      assert_receive {:deploy_notice, nil}
      assert Deploy.restart_at() == nil
    end

    test "re-announcing replaces the deadline rather than racing it" do
      {:ok, first} = Deploy.announce(600)
      {:ok, second} = Deploy.announce(120)

      assert Deploy.restart_at() == second
      assert DateTime.compare(second, first) == :lt
    end
  end

  describe "the endpoint the deploy script calls" do
    test "refuses when no token is configured", %{conn: conn} do
      # Fails CLOSED. An unset variable in production must not silently open
      # a route that puts a banner on every user's screen.
      previous = Application.get_env(:pairings_engine, :deploy_notice_token)
      Application.delete_env(:pairings_engine, :deploy_notice_token)
      on_exit(fn -> Application.put_env(:pairings_engine, :deploy_notice_token, previous) end)

      conn = post(conn, ~p"/internal/deploy-notice", %{"minutes" => "10"})

      assert json_response(conn, 401)
      assert Deploy.restart_at() == nil
    end

    test "refuses a wrong token", %{conn: conn} do
      with_token("right-token", fn ->
        conn =
          conn
          |> put_req_header("authorization", "Bearer wrong-token")
          |> post(~p"/internal/deploy-notice", %{"minutes" => "10"})

        assert json_response(conn, 401)
        assert Deploy.restart_at() == nil
      end)
    end

    test "announces with the right token", %{conn: conn} do
      with_token("right-token", fn ->
        conn =
          conn
          |> put_req_header("authorization", "Bearer right-token")
          |> post(~p"/internal/deploy-notice", %{"minutes" => "10"})

        assert %{"ok" => true, "restart_at" => at} = json_response(conn, 200)
        assert {:ok, _, _} = DateTime.from_iso8601(at)
        assert Deploy.restart_at() != nil
      end)
    end

    test "caps the delay, so a typo cannot leave a banner up for days", %{conn: conn} do
      with_token("right-token", fn ->
        conn =
          conn
          |> put_req_header("authorization", "Bearer right-token")
          |> post(~p"/internal/deploy-notice", %{"minutes" => "6000"})

        assert json_response(conn, 400)
        assert Deploy.restart_at() == nil
      end)
    end
  end

  describe "the banner" do
    setup :register_and_log_in_user

    test "the empty banner is on every page, so there is no per-page plumbing to forget",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")

      # Rendered hidden and empty in the ROOT layout. It is not conditional
      # on anything server-side, which is the point: `Layouts.app` is a
      # function component and cannot see the LiveView's assigns, so a
      # per-page attr would be 29 call sites and one of them eventually
      # missed.
      assert html =~ ~s(id="deploy-banner")
      assert html =~ "Server update"
    end

    test "a page opening mid-countdown is told the deadline", %{conn: conn} do
      {:ok, restart_at} = Deploy.announce(600)

      {:ok, lv, _html} = live(conn, ~p"/")

      assert_push_event(lv, "deploy-notice", %{restart_at: pushed})
      assert pushed == DateTime.to_iso8601(restart_at)
    end

    test "a page already open is told when the deploy is announced", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      # Mount always pushes the current state first - nil here - so consume
      # that before asserting on the announcement, or the binding below
      # picks up the mount push and compares nil against a timestamp.
      assert_push_event(lv, "deploy-notice", %{restart_at: nil})

      {:ok, restart_at} = Deploy.announce(600)

      assert_push_event(lv, "deploy-notice", %{restart_at: pushed})
      assert pushed == DateTime.to_iso8601(restart_at)
    end

    test "cancelling tells open pages to clear it", %{conn: conn} do
      {:ok, restart_at} = Deploy.announce(600)
      {:ok, lv, _html} = live(conn, ~p"/")

      # Mount pushes the pending deadline, then the cancel pushes nil.
      assert_push_event(lv, "deploy-notice", %{restart_at: at})
      assert at == DateTime.to_iso8601(restart_at)

      Deploy.cancel()

      assert_push_event(lv, "deploy-notice", %{restart_at: nil})
    end

    test "no notice pending means nothing is pushed", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      assert_push_event(lv, "deploy-notice", %{restart_at: nil})
    end
  end

  describe "coverage" do
    test "every live_session carries the DeployNotice hook" do
      # There is no central place that catches them all: a `live_session`
      # added later without this hook silently shows no warning, which looks
      # exactly like "no deploy pending". Checked against the router source
      # because that is where the omission would be.
      source = File.read!("lib/pairings_engine_web/router.ex")

      # `live_session :name` specifically. An earlier version split on the
      # bare string and matched the words "live_session" inside a COMMENT,
      # reporting a session called "- it only ever redirects".
      missing =
        Regex.scan(~r/live_session\s+:(\w+)(.{0,400}?)do/s, source)
        |> Enum.reject(fn [_all, _name, between] -> between =~ "DeployNotice" end)
        |> Enum.map(fn [_all, name, _between] -> name end)

      assert missing == [],
             """
             These live_sessions have no DeployNotice on_mount, so pages in
             them will never show the restart warning:

               #{Enum.join(missing, ", ")}

             Add PairingsEngineWeb.DeployNotice to their on_mount list.
             """
    end

    test "the router really does declare the sessions this checks" do
      # Guards the guard: a regex that matches nothing would make the test
      # above pass no matter what the router said.
      source = File.read!("lib/pairings_engine_web/router.ex")
      found = Regex.scan(~r/live_session\s+:(\w+)/, source)

      assert length(found) >= 7, "expected to find every live_session, found #{length(found)}"
    end
  end

  defp with_token(token, fun) do
    previous = Application.get_env(:pairings_engine, :deploy_notice_token)
    Application.put_env(:pairings_engine, :deploy_notice_token, token)

    try do
      fun.()
    after
      Application.put_env(:pairings_engine, :deploy_notice_token, previous)
    end
  end
end
