defmodule PairingsEngineWeb.FideDownloadNoticeTest do
  @moduledoc """
  A desktop install does not fetch 41 MB without a yes. The daily look at FIDE
  stays; what it finds becomes a pending state and a banner with three
  buttons. A hosted server is untouched: it downloads, as it always did.

  Not async: the edition (`:local_mode`), the setting and the `Sync` singleton
  are all process-wide.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Fide, Meta, Repo}
  alias PairingsEngine.Fide.{AutoSync, Sync}
  alias PairingsEngine.Tournaments.Tournament

  setup :register_and_log_in_user

  # An administrator: on a hosted server the plain account is not allowed to
  # download the list, which is the other half of what these tests are about.
  setup %{conn: conn, user: user} do
    {:ok, admin} = PairingsEngine.Accounts.set_role(user.email, "admin")
    {:ok, conn: log_in_user(conn, admin), user: admin}
  end

  setup do
    previous_local = Application.get_env(:pairings_engine, :local_mode)
    previous_fide = Application.get_env(:pairings_engine, :fide)

    # Should a test ever reach the real download, it meets a closed port.
    Application.put_env(:pairings_engine, :fide, list_url: "http://127.0.0.1:1/players_list.zip")
    :sys.replace_state(Sync, fn _ -> struct(Sync) end)

    on_exit(fn ->
      # A download these tests started must die with them: wiping the state
      # alone would leave its task broadcasting into the next test file.
      Sync.cancel_sync()
      _ = Sync.status()
      restore(:local_mode, previous_local)
      restore(:fide, previous_fide)
      :sys.replace_state(Sync, fn _ -> struct(Sync) end)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:pairings_engine, key)
  defp restore(key, value), do: Application.put_env(:pairings_engine, key, value)

  defp desktop(on?), do: Application.put_env(:pairings_engine, :local_mode, on?)

  defp sync_at(datetime) do
    Repo.query!(
      "INSERT INTO meta (key, value) VALUES ('fide_last_sync', ?) " <>
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      [datetime]
    )
  end

  defp stub_head(last_modified) do
    Req.Test.stub(PairingsEngine.Fide.FreshnessTest, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("last-modified", last_modified)
      |> Plug.Conn.send_resp(200, "")
    end)
  end

  defp opts do
    test = self()
    [sync: fn -> send(test, :sync_started) end, busy?: fn -> false end]
  end

  defp tournament(user, name) do
    Repo.insert!(%Tournament{
      name: name,
      type: "swiss",
      rounds_count: 5,
      status: "running",
      user_id: user.id
    })
  end

  describe "the mode" do
    test "hosted defaults to automatic, desktop to ask, and a stored off is never on both" do
      desktop(false)
      assert AutoSync.mode() == :auto
      assert AutoSync.download_unasked?()

      desktop(true)
      assert AutoSync.mode() == :ask
      refute AutoSync.download_unasked?()

      Meta.put("fide_auto_sync", "off")
      assert AutoSync.mode() == :never
      desktop(false)
      assert AutoSync.mode() == :never
    end

    test "automatic on desktop is written down, since nothing stored means ask" do
      desktop(true)
      AutoSync.put_mode(:auto)
      assert AutoSync.mode() == :auto
      assert AutoSync.download_unasked?()

      AutoSync.put_mode(:ask)
      assert AutoSync.mode() == :ask
    end
  end

  describe "the daily look on desktop, asking" do
    setup do
      desktop(true)
      :ok
    end

    test "no list at all: nothing downloads, the question is pending" do
      assert AutoSync.run_once(opts()) == :pending
      refute_received :sync_started
      assert AutoSync.pending() == :missing
    end

    test "a newer list at FIDE: nothing downloads, the question is pending" do
      sync_at("2026-10-01 08:00:00")
      stub_head("Thu, 15 Oct 2026 12:00:00 GMT")

      assert AutoSync.run_once(opts()) == :pending
      refute_received :sync_started
      assert AutoSync.pending() == :newer
    end

    test "a download, however it came about, retires the question" do
      assert AutoSync.run_once(opts()) == :pending
      Fide.put_last_sync()
      assert AutoSync.pending() == nil
    end

    test "automatic still downloads, as before" do
      AutoSync.put_mode(:auto)
      assert AutoSync.run_once(opts()) == :updating
      assert_received :sync_started
      assert AutoSync.pending() == nil
    end

    test "never does not even look" do
      AutoSync.put_mode(:never)
      assert AutoSync.run_once(opts()) == :disabled
      refute_received :sync_started
    end
  end

  describe "hosted" do
    test "no list: downloads, raises nothing, shows no banner", %{conn: conn} do
      desktop(false)
      assert AutoSync.run_once(opts()) == :updating
      assert_received :sync_started
      assert AutoSync.pending() == nil

      # Even with a marker lying around, a hosted server has no such banner.
      Meta.put("fide_download_pending", "none")
      {:ok, view, _} = live(conn, ~p"/")
      refute has_element?(view, "#fide-download-notice")
    end
  end

  describe "the banner" do
    setup do
      desktop(true)
      AutoSync.raise_pending()
      :ok
    end

    test "is on the dashboard, Players and Connections, with its three buttons", %{
      conn: conn,
      user: user
    } do
      t = tournament(user, "Banner")

      for path <- [~p"/", ~p"/t/#{t.id}/players", ~p"/fide"] do
        {:ok, view, _} = live(conn, path)
        assert has_element?(view, "#fide-download-notice")
        assert has_element?(view, "#fide-download-now")
        assert has_element?(view, "#fide-download-later")
        assert has_element?(view, "#fide-download-never")
      end
    end

    test "is not there when nothing is pending", %{conn: conn} do
      AutoSync.clear_pending()
      {:ok, view, _} = live(conn, ~p"/")
      refute has_element?(view, "#fide-download-notice")
    end

    test "Download now starts the download", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      view |> element("#fide-download-now") |> render_click()

      assert Sync.status().status in [:downloading, :importing, :error]

      assert Enum.any?(
               PairingsEngine.Audit.list_machine_wide(),
               &(&1.action == "fide.sync_started")
             )
    end

    test "Later hides it for a day and downloads nothing", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      view |> element("#fide-download-later") |> render_click()

      refute has_element?(view, "#fide-download-notice")
      assert AutoSync.snoozed?()
      assert Sync.status().status == :idle

      # Still hidden on the next page, and back after the day is up.
      {:ok, view, _} = live(conn, ~p"/")
      refute has_element?(view, "#fide-download-notice")
      refute AutoSync.snoozed?(DateTime.add(DateTime.utc_now(), 25 * 3600))
    end

    test "Dont-ask-again stores never, and the Connections page can undo it", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      view |> element("#fide-download-never") |> render_click()

      refute has_element?(view, "#fide-download-notice")
      assert AutoSync.mode() == :never
      assert Sync.status().status == :idle

      {:ok, fide, _} = live(conn, ~p"/fide")
      assert has_element?(fide, "#fide-auto-sync")
      fide |> form("#fide-auto-mode-form", %{"mode" => "ask"}) |> render_change()
      assert AutoSync.mode() == :ask
    end
  end

  describe "the Players page" do
    test "does not start a download on desktop; it raises the question and checks what is here",
         %{conn: conn, user: user} do
      desktop(true)
      sync_at("2026-10-01 08:00:00")
      stub_head("Thu, 15 Oct 2026 12:00:00 GMT")

      t = tournament(user, "Players")
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/players")

      render_click(view, "open_rating_refresh", %{})
      _ = render_async(view)

      assert Sync.status().status == :idle
      assert AutoSync.pending() == :newer
    end

    test "hosted still updates first", %{conn: conn, user: user} do
      desktop(false)
      sync_at("2026-10-01 08:00:00")
      stub_head("Thu, 15 Oct 2026 12:00:00 GMT")

      t = tournament(user, "Players")
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/players")

      render_click(view, "open_rating_refresh", %{})
      _ = render_async(view)

      assert Sync.status().status in [:downloading, :importing, :error]
    end
  end
end
