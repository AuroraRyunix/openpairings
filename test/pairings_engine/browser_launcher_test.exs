defmodule PairingsEngine.BrowserLauncherTest do
  @moduledoc """
  The decision behind opening a browser at boot, not the browser itself.

  Every test below calls `plan/1` (or `command/2`) with explicit overrides
  rather than mutating real application or system state, precisely so none
  of them depend on - or could leak into - whatever `OPENPAIRINGS_LOCAL`
  happens to be set to in the shell a `mix test` run started from. The one
  exception manages `OPENPAIRINGS_NO_BROWSER` itself, deliberately, to prove
  the real default reads it - and restores it afterwards.

  `maybe_open/0` is exercised too, but only to confirm it stays quiet and
  returns fast under the real test config - never to check that a browser
  actually opened, which nothing here should ever do. `open/1`, the one
  function that calls `System.cmd/3`, is private and untested for the same
  reason.
  """
  use ExUnit.Case, async: true

  alias PairingsEngine.BrowserLauncher

  describe "plan/1 - the decision, with no side effect" do
    test "not local mode means skip, regardless of anything else" do
      assert BrowserLauncher.plan(local_mode?: false, suppressed?: false, port: 4000) == :skip
    end

    test "local mode and not suppressed opens at the given port" do
      assert BrowserLauncher.plan(local_mode?: true, suppressed?: false, port: 4321) ==
               {:open, "http://localhost:4321"}
    end

    test "local mode but suppressed still means skip" do
      assert BrowserLauncher.plan(local_mode?: true, suppressed?: true, port: 4000) == :skip
    end

    test "suppressed is checked before the port is even read" do
      # No :port override here - if this read a port at all it would have to
      # ask the real endpoint for one, and the point is that it must not.
      assert BrowserLauncher.plan(local_mode?: true, suppressed?: true) == :skip
    end

    test "the real default port, unless overridden, comes from the endpoint's own config" do
      # Read the same way `plan/1` does rather than hardcoding the number:
      # `config/runtime.exs` sets `:http, port:` for every environment, not
      # just prod, and unconditionally wins over whatever `config/test.exs`
      # put there - so asserting a literal here would really be asserting on
      # that merge order rather than on what this function does.
      port = PairingsEngineWeb.Endpoint.config(:http)[:port]

      assert BrowserLauncher.plan(local_mode?: true, suppressed?: false) ==
               {:open, "http://localhost:#{port}"}
    end

    test "the real default local_mode?, unless overridden, comes from Authz - off in test" do
      assert BrowserLauncher.plan(suppressed?: false) == :skip
    end

    test "the real default suppressed?, unless overridden, reads OPENPAIRINGS_NO_BROWSER" do
      previous = System.get_env("OPENPAIRINGS_NO_BROWSER")

      on_exit(fn ->
        case previous do
          nil -> System.delete_env("OPENPAIRINGS_NO_BROWSER")
          value -> System.put_env("OPENPAIRINGS_NO_BROWSER", value)
        end
      end)

      System.put_env("OPENPAIRINGS_NO_BROWSER", "1")
      assert BrowserLauncher.plan(local_mode?: true, port: 4000) == :skip

      System.put_env("OPENPAIRINGS_NO_BROWSER", "0")

      assert BrowserLauncher.plan(local_mode?: true, port: 4000) ==
               {:open, "http://localhost:4000"}
    end
  end

  describe "command/2 - the argv for each OS, never actually run" do
    test "windows: cmd /c start, with the empty-title workaround" do
      assert BrowserLauncher.command("http://localhost:4000", {:win32, :nt}) ==
               {"cmd", ["/c", "start", "", "http://localhost:4000"]}
    end

    test "macOS: open" do
      assert BrowserLauncher.command("http://localhost:4000", {:unix, :darwin}) ==
               {"open", ["http://localhost:4000"]}
    end

    test "every other unix: xdg-open" do
      assert BrowserLauncher.command("http://localhost:4000", {:unix, :linux}) ==
               {"xdg-open", ["http://localhost:4000"]}

      assert BrowserLauncher.command("http://localhost:4000", {:unix, :freebsd}) ==
               {"xdg-open", ["http://localhost:4000"]}
    end

    test "defaults to this machine's own :os.type/0 when not given one" do
      {cmd, args} = BrowserLauncher.command("http://localhost:4000")
      assert is_binary(cmd)
      assert "http://localhost:4000" in args
    end
  end

  describe "maybe_open/0 - the real call site, under the real test config" do
    test "stays quiet and returns immediately rather than spawning anything" do
      assert BrowserLauncher.maybe_open() == :ok
    end
  end
end
