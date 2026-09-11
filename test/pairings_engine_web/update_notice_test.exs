defmodule PairingsEngineWeb.UpdateNoticeTest do
  @moduledoc """
  What the top bar shows about a pending update, and - the property this
  whole feature exists to guarantee - that a hosted server never shows it,
  even when a notice is sitting in the cache.

  The cache (`:update_notice`, a `:public` `:ets` table owned by
  `PairingsEngine.Updates.Checker`) is seeded directly rather than through a
  real `Req.Test`-stubbed check: `PairingsEngine.Updates.CheckerTest` and
  `PairingsEngine.UpdatesTest` already cover the network half, and seeding
  keeps this file about rendering only - the version, the release link, the
  install-kind action (stubbed via the same `updates_install_kind_override`
  `PairingsEngine.Updates.InstallKind` documents), and the in-progress-round
  caveat.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.Repo
  alias PairingsEngine.Tournaments.Tournament

  setup :register_and_log_in_user

  setup do
    previous_local_mode = Application.get_env(:pairings_engine, :local_mode)

    on_exit(fn ->
      case previous_local_mode do
        nil -> Application.delete_env(:pairings_engine, :local_mode)
        value -> Application.put_env(:pairings_engine, :local_mode, value)
      end

      :ets.delete_all_objects(:update_notice)
      Application.delete_env(:pairings_engine, :updates_install_kind_override)
      Application.delete_env(:pairings_engine, :updates_install_and_restart_override)
      Application.delete_env(:pairings_engine, :updates_stop_fun)
    end)

    :ok
  end

  defp seed_notice do
    notice = %{
      version: "99.0.0",
      tag: "v99.0.0",
      url: "https://github.com/AuroraRyunix/openpairings/releases/tag/v99.0.0"
    }

    :ets.insert(:update_notice, {:notice, notice})
    notice
  end

  defp local_mode(on?), do: Application.put_env(:pairings_engine, :local_mode, on?)

  defp running_tournament(name) do
    Repo.insert!(%Tournament{name: name, type: "swiss", rounds_count: 5, status: "running"})
  end

  describe "on a hosted server" do
    test "never shows the notice, even with one cached", %{conn: conn} do
      local_mode(false)
      seed_notice()

      {:ok, _lv, html} = live(conn, ~p"/")

      refute html =~ "update-notice"
      refute html =~ "Update available"
    end
  end

  describe "on a desktop install" do
    setup do
      local_mode(true)
      :ok
    end

    test "shows nothing when nothing has been found", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")

      refute html =~ "update-notice"
    end

    test "renders the version and a link to the release", %{conn: conn} do
      notice = seed_notice()

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Update available"
      assert html =~ "v99.0.0"
      assert html =~ notice.url
    end

    test "a per-user Velopack install is told the installer updates it in place", %{conn: conn} do
      seed_notice()
      Application.put_env(:pairings_engine, :updates_install_kind_override, :velopack_per_user)

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Download the new installer and run it"
      refute html =~ "needs an administrator"
    end

    test "a per-machine Velopack install is told an administrator is needed", %{conn: conn} do
      seed_notice()
      Application.put_env(:pairings_engine, :updates_install_kind_override, :velopack_per_machine)

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "needs an administrator"
    end

    test "the portable/Burrito/other case only offers a plain download", %{conn: conn} do
      seed_notice()
      Application.put_env(:pairings_engine, :updates_install_kind_override, :other)

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "use it in place of this one"
      refute html =~ "needs an administrator"
      refute html =~ "Download the new installer and run it"
    end

    test "names a tournament with a round paired but unfinished", %{conn: conn} do
      seed_notice()
      running_tournament("Bruges Open")

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Bruges Open"
      assert html =~ "is paired but not finished"
    end

    test "says nothing about tournaments when none are running", %{conn: conn} do
      seed_notice()

      {:ok, _lv, html} = live(conn, ~p"/")

      refute html =~ "is paired but not finished"
    end
  end

  describe "the in-app \"Install and restart\" button" do
    setup do
      local_mode(true)
      Application.put_env(:pairings_engine, :updates_install_kind_override, :velopack_per_user)
      :ok
    end

    test "appears when the launcher says in-app updating is available", %{conn: conn} do
      seed_notice()
      Application.put_env(:pairings_engine, :updates_install_and_restart_override, true)

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Install and restart"
      refute html =~ "View the release"
    end

    test "falls back to the plain link when the launcher's signal is absent", %{conn: conn} do
      seed_notice()
      Application.put_env(:pairings_engine, :updates_install_and_restart_override, false)

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "View the release"
      refute html =~ "Install and restart"
    end

    test "per-machine installs never get the button, even with the launcher's signal", %{
      conn: conn
    } do
      seed_notice()
      Application.put_env(:pairings_engine, :updates_install_kind_override, :velopack_per_machine)
      Application.put_env(:pairings_engine, :updates_install_and_restart_override, true)

      {:ok, _lv, html} = live(conn, ~p"/")

      refute html =~ "Install and restart"
      assert html =~ "needs an administrator"
    end

    test "the \"other\" install kind never gets the button, even with the launcher's signal", %{
      conn: conn
    } do
      seed_notice()
      Application.put_env(:pairings_engine, :updates_install_kind_override, :other)
      Application.put_env(:pairings_engine, :updates_install_and_restart_override, true)

      {:ok, _lv, html} = live(conn, ~p"/")

      refute html =~ "Install and restart"
      assert html =~ "use it in place of this one"
    end

    test "the confirm dialog names the version and any in-progress round", %{conn: conn} do
      notice = seed_notice()
      running_tournament("Bruges Open")
      Application.put_env(:pairings_engine, :updates_install_and_restart_override, true)

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "data-confirm="
      assert html =~ "Install OpenPairings v#{notice.version} and restart now?"
      assert html =~ "Bruges Open"
    end

    test "clicking and confirming shuts the app down with the dedicated exit code", %{conn: conn} do
      test_pid = self()
      seed_notice()
      Application.put_env(:pairings_engine, :updates_install_and_restart_override, true)

      Application.put_env(:pairings_engine, :updates_stop_fun, fn code ->
        send(test_pid, {:stopped, code})
      end)

      {:ok, lv, _html} = live(conn, ~p"/")

      html = lv |> element("[phx-click='install_and_restart']") |> render_click()

      assert html =~ "Installing the update"
      refute html =~ ~s(phx-click="install_and_restart")
      assert_receive {:stopped, 90}, 1000
    end

    test "the click is a no-op when the launcher's signal is absent, even if sent", %{conn: conn} do
      test_pid = self()
      seed_notice()
      Application.put_env(:pairings_engine, :updates_install_and_restart_override, false)

      Application.put_env(:pairings_engine, :updates_stop_fun, fn code ->
        send(test_pid, {:stopped, code})
      end)

      {:ok, lv, _html} = live(conn, ~p"/")

      render_click(lv, "install_and_restart", %{})

      refute_receive {:stopped, _}, 500
    end

    test "on a hosted server, the click is a no-op even if a socket somehow sent it", %{
      conn: conn
    } do
      test_pid = self()
      # Overwrites this describe block's own local_mode(true) - a hosted
      # server can never actually get an update_notice assign to begin with
      # (see PairingsEngine.Updates.eligible?/0), which is the real guard;
      # this proves the event handler itself does not trust the event name
      # alone if that ever changed.
      local_mode(false)
      Application.put_env(:pairings_engine, :updates_install_and_restart_override, true)

      Application.put_env(:pairings_engine, :updates_stop_fun, fn code ->
        send(test_pid, {:stopped, code})
      end)

      {:ok, lv, _html} = live(conn, ~p"/")

      render_click(lv, "install_and_restart", %{})

      refute_receive {:stopped, _}, 500
    end
  end
end
