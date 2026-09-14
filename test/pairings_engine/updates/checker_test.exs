defmodule PairingsEngine.Updates.CheckerTest do
  @moduledoc """
  The two guards that decide whether `PairingsEngine.Updates.Checker` ever
  makes a request at all - the desktop/server split and the on/off setting -
  plus the cache and the broadcast.

  `check_now/0` runs in THIS process, not the singleton's - see its own
  moduledoc - so every test here owns the `Req.Test` stub and the `meta`
  table's sandbox connection it reads, with no `Req.Test.allow/3` needed.
  What it does NOT get for free is `PairingsEngine.Authz.local_mode?/0`
  itself, which is a plain `Application.env` read from whichever process
  asks - so flipping it here is enough to change what `check_now/0` does,
  with no process trickery required.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.Updates
  alias PairingsEngine.Updates.Checker

  setup do
    previous = Application.get_env(:pairings_engine, :local_mode)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:pairings_engine, :local_mode)
        value -> Application.put_env(:pairings_engine, :local_mode, value)
      end

      :ets.delete_all_objects(:update_notice)
      Updates.put_enabled(true)
    end)

    Application.put_env(:pairings_engine, :local_mode, true)
    Updates.put_enabled(true)
    :ets.delete_all_objects(:update_notice)
    :ok
  end

  defp stub(fun), do: Req.Test.stub(PairingsEngine.UpdatesTest, fun)

  defp release(tag) do
    %{
      "tag_name" => tag,
      "html_url" => "https://github.com/AuroraRyunix/openpairings/releases/tag/#{tag}",
      "draft" => false,
      "prerelease" => false
    }
  end

  defp refuse_to_be_called do
    stub(fn _conn -> raise "the update check must not make a request here" end)
  end

  test "current/0 is nil before anything has been checked" do
    assert Checker.current() == nil
  end

  describe "on a hosted server (not local mode)" do
    setup do
      Application.put_env(:pairings_engine, :local_mode, false)
      :ok
    end

    test "check_now/0 makes no request and leaves current/0 nil" do
      refuse_to_be_called()

      Checker.check_now()

      assert Checker.current() == nil
    end
  end

  describe "with the setting off" do
    setup do
      Updates.put_enabled(false)
      :ok
    end

    test "check_now/0 makes no request even on a desktop install" do
      refuse_to_be_called()

      Checker.check_now()

      assert Checker.current() == nil
    end
  end

  describe "on a desktop install with the setting on" do
    test "a newer release is cached and readable without a process call" do
      stub(fn conn -> Req.Test.json(conn, [release("v99.0.0")]) end)

      Checker.check_now()

      assert Checker.current() == %{
               version: "99.0.0",
               tag: "v99.0.0",
               url: "https://github.com/AuroraRyunix/openpairings/releases/tag/v99.0.0"
             }
    end

    test "no update clears a previously cached one" do
      stub(fn conn -> Req.Test.json(conn, [release("v99.0.0")]) end)
      Checker.check_now()
      assert Checker.current() != nil

      stub(fn conn -> Req.Test.json(conn, [release("v0.0.1")]) end)
      Checker.check_now()

      assert Checker.current() == nil
    end

    test "a failed check leaves the previous answer in place" do
      stub(fn conn -> Req.Test.json(conn, [release("v99.0.0")]) end)
      Checker.check_now()
      cached = Checker.current()
      assert cached != nil

      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      Checker.check_now()

      assert Checker.current() == cached
    end

    test "broadcasts only when the answer changes" do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Checker.topic())

      stub(fn conn -> Req.Test.json(conn, [release("v99.0.0")]) end)
      Checker.check_now()
      assert_receive {:update_notice, %{version: "99.0.0"}}

      # Same answer again - no second broadcast.
      Checker.check_now()
      refute_receive {:update_notice, _}, 50

      stub(fn conn -> Req.Test.json(conn, [release("v0.0.1")]) end)
      Checker.check_now()
      assert_receive {:update_notice, nil}
    end
  end

  describe "check_now_manual/0" do
    setup do
      # Manual checks share a rate-limit clock keyed on the same table - a
      # clean slate for each test, same as `current/0`.
      :ets.delete_all_objects(:update_notice)
      :ok
    end

    test "not eligible on a hosted server, even if called directly" do
      Application.put_env(:pairings_engine, :local_mode, false)
      refuse_to_be_called()

      assert Checker.check_now_manual() == :ineligible
      assert Checker.current() == nil
    end

    test "{:ok, info} when a newer release exists, and it is cached like the timer's" do
      stub(fn conn -> Req.Test.json(conn, [release("v99.0.0")]) end)

      assert {:ok, %{version: "99.0.0"}} = Checker.check_now_manual()

      assert Checker.current() == %{
               version: "99.0.0",
               tag: "v99.0.0",
               url: "https://github.com/AuroraRyunix/openpairings/releases/tag/v99.0.0"
             }
    end

    test ":no_update when this is already the newest release" do
      stub(fn conn -> Req.Test.json(conn, [release("v0.0.1")]) end)

      assert Checker.check_now_manual() == :no_update
    end

    test ":error when GitHub cannot be reached" do
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert Checker.check_now_manual() == :error
    end

    test ":rate_limited on a second call shortly after the first" do
      stub(fn conn -> Req.Test.json(conn, [release("v0.0.1")]) end)

      assert Checker.check_now_manual() == :no_update
      assert Checker.check_now_manual() == :rate_limited
    end

    test "allowed again once the configured minimum gap has passed" do
      Application.put_env(:pairings_engine, :updates_manual_min_gap, 0)
      on_exit(fn -> Application.delete_env(:pairings_engine, :updates_manual_min_gap) end)

      stub(fn conn -> Req.Test.json(conn, [release("v0.0.1")]) end)

      assert Checker.check_now_manual() == :no_update
      assert Checker.check_now_manual() == :no_update
    end

    test "ignores the on/off setting - an explicit click still checks" do
      Updates.put_enabled(false)
      stub(fn conn -> Req.Test.json(conn, [release("v99.0.0")]) end)

      assert {:ok, %{version: "99.0.0"}} = Checker.check_now_manual()
    end
  end

  describe "the first check after boot" do
    # A dedicated instance, not the singleton the whole test run already
    # shares - `first_check` and `interval` are given directly rather than
    # through config, which is what makes this an injectable delay rather
    # than a real sleep: milliseconds, not `:timer.seconds(5)`.
    defp start_checker(opts) do
      name = :"checker_boot_test_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          {Checker,
           Keyword.merge([interval: :timer.minutes(30), first_check: 20, name: name], opts)},
          id: name
        )

      # This instance ticks in ITS OWN process, not the test's - unlike
      # `check_now/0`/`check_now_manual/0` (see their moduledocs). It needs
      # explicit ownership of the `Req.Test` stub and the sandboxed DB
      # connection `Updates.enabled?/0` reads, the same way any other
      # non-test-owned process in this app's tests does.
      Req.Test.allow(PairingsEngine.UpdatesTest, self(), pid)
      Ecto.Adapters.SQL.Sandbox.allow(PairingsEngine.Repo, self(), pid)

      pid
    end

    test "schedules soon after boot on a desktop install, not 30 minutes out" do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Checker.topic())
      stub(fn conn -> Req.Test.json(conn, [release("v99.0.0")]) end)

      start_checker([])

      # Well under 30 minutes, and well under a real "wait and see" test
      # would need - the 20ms first_check above is what makes this fast.
      assert_receive {:update_notice, %{version: "99.0.0"}}, 1000
    end

    test "never schedules at all on a hosted server" do
      Application.put_env(:pairings_engine, :local_mode, false)
      refuse_to_be_called()

      start_checker([])

      refute_receive {:update_notice, _}, 200
    end
  end

  describe "conditional requests (ETag)" do
    setup do
      :ets.delete_all_objects(:update_notice)
      :ok
    end

    test "the etag from a 200 is cached and sent on the next check_now/0" do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:if_none_match, Plug.Conn.get_req_header(conn, "if-none-match")})

        conn
        |> Plug.Conn.put_resp_header("etag", ~s("v1"))
        |> Req.Test.json([release("v0.0.1")])
      end)

      Checker.check_now()
      assert_receive {:if_none_match, []}

      Checker.check_now()
      assert_receive {:if_none_match, [~s("v1")]}
    end

    test "a 304 leaves the cached notice and the cached etag exactly as they were" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("etag", ~s("v1"))
        |> Req.Test.json([release("v99.0.0")])
      end)

      Checker.check_now()
      cached = Checker.current()
      assert cached != nil

      stub(fn conn -> Plug.Conn.send_resp(conn, 304, "") end)
      Checker.check_now()

      assert Checker.current() == cached
    end

    test "a 304 does not broadcast - nothing changed" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("etag", ~s("v1"))
        |> Req.Test.json([release("v99.0.0")])
      end)

      Checker.check_now()

      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Checker.topic())
      stub(fn conn -> Plug.Conn.send_resp(conn, 304, "") end)
      Checker.check_now()

      refute_receive {:update_notice, _}, 50
    end
  end
end
