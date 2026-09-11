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

      assert html =~ "updates this install in place"
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

      assert html =~ "swap it in when you next update"
      refute html =~ "needs an administrator"
      refute html =~ "updates this install in place"
    end

    test "names a tournament with a round paired but unfinished", %{conn: conn} do
      seed_notice()
      running_tournament("Bruges Open")

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Bruges Open"
      assert html =~ "round paired but not finished"
    end

    test "says nothing about tournaments when none are running", %{conn: conn} do
      seed_notice()

      {:ok, _lv, html} = live(conn, ~p"/")

      refute html =~ "round paired but not finished"
    end
  end
end
