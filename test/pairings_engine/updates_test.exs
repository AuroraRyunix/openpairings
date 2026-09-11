defmodule PairingsEngine.UpdatesTest do
  @moduledoc """
  The GitHub check itself: what counts as a usable release, whether it is
  newer, and that anything short of a clean 200 is silent - never an error a
  caller has to handle, per `PairingsEngine.Updates`'s moduledoc.

  Desktop/server eligibility and the timer live in
  `PairingsEngine.Updates.CheckerTest`; this module is `check/0` and the
  plain settings functions on their own, with no process boundary between
  the test and the `Req.Test` stub - see that other module's moduledoc for
  why the checker's own tests have to be more careful about that.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.Updates

  defp stub(fun), do: Req.Test.stub(PairingsEngine.UpdatesTest, fun)

  defp release(opts) do
    %{
      "tag_name" => Keyword.fetch!(opts, :tag),
      "html_url" =>
        Keyword.get(
          opts,
          :url,
          "https://github.com/AuroraRyunix/openpairings/releases/tag/#{Keyword.fetch!(opts, :tag)}"
        ),
      "draft" => Keyword.get(opts, :draft, false),
      "prerelease" => Keyword.get(opts, :prerelease, false)
    }
  end

  describe "check/0" do
    test "finds a newer release and says so" do
      stub(fn conn -> Req.Test.json(conn, [release(tag: "v99.0.0")]) end)

      assert {:ok, %{version: "99.0.0", tag: "v99.0.0", url: url}} = Updates.check()
      assert url == "https://github.com/AuroraRyunix/openpairings/releases/tag/v99.0.0"
    end

    test "accepts a tag with no leading v" do
      stub(fn conn -> Req.Test.json(conn, [release(tag: "99.0.0")]) end)

      assert {:ok, %{version: "99.0.0"}} = Updates.check()
    end

    test "ignores prereleases and drafts, using the newest real release" do
      stub(fn conn ->
        Req.Test.json(conn, [
          release(tag: "v100.0.0", prerelease: true),
          release(tag: "v99.5.0", draft: true),
          release(tag: "v99.0.0")
        ])
      end)

      assert {:ok, %{version: "99.0.0"}} = Updates.check()
    end

    test "no_update when the newest usable release is this version" do
      stub(fn conn ->
        Req.Test.json(conn, [release(tag: "v#{PairingsEngine.Build.version()}")])
      end)

      assert Updates.check() == :no_update
    end

    test "no_update when every usable release is older" do
      stub(fn conn -> Req.Test.json(conn, [release(tag: "v0.0.1")]) end)

      assert Updates.check() == :no_update
    end

    test "silent when every release is a draft or a prerelease" do
      stub(fn conn ->
        Req.Test.json(conn, [
          release(tag: "v99.0.0", prerelease: true),
          release(tag: "v98.0.0", draft: true)
        ])
      end)

      assert Updates.check() == :error
    end

    test "silent on a transport failure - offline, no crash" do
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert Updates.check() == :error
    end

    test "silent on a timeout" do
      stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert Updates.check() == :error
    end

    test "silent on the unauthenticated rate limit" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"message" => "API rate limit exceeded"})
      end)

      assert Updates.check() == :error
    end

    test "silent on any other non-2xx" do
      stub(fn conn -> conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{}) end)

      assert Updates.check() == :error
    end

    test "silent on an empty release list" do
      stub(fn conn -> Req.Test.json(conn, []) end)

      assert Updates.check() == :error
    end

    test "does not raise on an unexpected body shape" do
      stub(fn conn -> Req.Test.json(conn, %{"not" => "a list"}) end)

      assert Updates.check() == :error
    end
  end

  describe "enabled?/0 and put_enabled/1" do
    test "on by default" do
      assert Updates.enabled?()
    end

    test "round-trips off and back on" do
      Updates.put_enabled(false)
      refute Updates.enabled?()

      Updates.put_enabled(true)
      assert Updates.enabled?()
    end
  end

  describe "install_and_restart_available?/0" do
    setup do
      on_exit(fn ->
        System.delete_env("OPENPAIRINGS_UPDATE_AVAILABLE")
        Application.delete_env(:pairings_engine, :updates_install_and_restart_override)
      end)

      :ok
    end

    test "false with no signal from the launcher" do
      System.delete_env("OPENPAIRINGS_UPDATE_AVAILABLE")

      refute Updates.install_and_restart_available?()
    end

    test "true once the launcher sets OPENPAIRINGS_UPDATE_AVAILABLE=1" do
      System.put_env("OPENPAIRINGS_UPDATE_AVAILABLE", "1")

      assert Updates.install_and_restart_available?()
    end

    test "false for anything other than the literal \"1\"" do
      System.put_env("OPENPAIRINGS_UPDATE_AVAILABLE", "0")

      refute Updates.install_and_restart_available?()
    end

    test "the test override wins over the environment variable" do
      System.put_env("OPENPAIRINGS_UPDATE_AVAILABLE", "1")
      Application.put_env(:pairings_engine, :updates_install_and_restart_override, false)

      refute Updates.install_and_restart_available?()
    end
  end

  describe "request_install_and_restart/0" do
    setup do
      on_exit(fn ->
        Application.delete_env(:pairings_engine, :updates_stop_fun)
        Application.delete_env(:pairings_engine, :local_mode)
      end)

      :ok
    end

    # Stubbed - the real one would halt the test VM. See rel/windows/launcher.c's
    # "In-app updates" header section for what OP_UPDATE_EXIT_CODE (90 on
    # both sides, cross-referenced by comment rather than shared) is for.
    test "shuts down with the dedicated exit code, on a desktop install" do
      test_pid = self()
      Application.put_env(:pairings_engine, :local_mode, true)

      Application.put_env(:pairings_engine, :updates_stop_fun, fn code ->
        send(test_pid, {:stopped, code})
      end)

      assert Updates.request_install_and_restart() == :ok
      assert_receive {:stopped, 90}, 1000
    end

    test "never stops the BEAM on a hosted server, even if called directly" do
      test_pid = self()
      Application.put_env(:pairings_engine, :local_mode, false)

      Application.put_env(:pairings_engine, :updates_stop_fun, fn code ->
        send(test_pid, {:stopped, code})
      end)

      assert Updates.request_install_and_restart() == :ok
      refute_receive {:stopped, _}, 500
    end
  end
end
