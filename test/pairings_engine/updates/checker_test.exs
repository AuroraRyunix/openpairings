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
end
