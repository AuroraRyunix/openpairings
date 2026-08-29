defmodule PairingsEngine.BrowserLauncher do
  @moduledoc """
  Opens the default browser at this server's own address, for the
  standalone binary.

  ## Who this is for

  Someone who downloaded one file, double-clicked it, and is now looking at
  a terminal window that prints a database path and an address - useful to
  a developer, and not to the arbiter it was built for. Local mode already
  prints that address (`config/runtime.exs`); this is the difference
  between reading it and typing it in, and not having to.

  ## Why local mode is the only gate

  A hosted server has other people looking at it and no browser to open -
  `xdg-open` on a systemd unit with no display attached would at best do
  nothing and at worst hang waiting for a D-Bus session that will never
  exist. `PairingsEngine.Authz.local_mode?/0` is the same switch everything
  else in the app already uses to tell "somebody's laptop" from "a server",
  so this asks it rather than inventing a second opinion.

  That single gate is also why dev is unaffected: `local_mode?` is off by
  default everywhere except inside a Burrito binary (see
  `config/runtime.exs`), so a plain `mix phx.server` - and every test run -
  never reaches past `plan/0`'s first check. `OPENPAIRINGS_LOCAL=1` can turn
  it on for a dev run deliberately; short of that, nothing here fires.

  `OPENPAIRINGS_NO_BROWSER=1` overrides it regardless, for a binary run
  headless or over SSH, where the machine with the terminal is not the
  machine with a screen.

  ## Why this waits for `Application.start/2` to already be done

  `PairingsEngine.Application.start/2` calls `maybe_open/0` only after
  `Supervisor.start_link/2` has already returned `{:ok, _}`, which does not
  happen until every child before `PairingsEngineWeb.Endpoint` in the list,
  and Endpoint itself, has finished starting. Binding the listening socket
  happens inside Endpoint's own `start_link`, so by the time control reaches
  here the port is already accepting connections. Opening the browser any
  earlier would sometimes win the race and show a connection error for a
  server that was a few milliseconds from being ready.

  ## Why this can never fail the boot

  Everything past the decision runs inside an unlinked, one-off process, and
  the decision itself is wrapped the same way: a chess tournament does not
  fail because a browser did not open, so a missing `xdg-open`, a sandboxed
  binary with no shell to spawn, or anything else in between is logged and
  dropped rather than allowed anywhere near `Application.start/2`'s return
  value.
  """

  alias PairingsEngine.Authz

  require Logger

  @doc """
  Whether a browser would be opened, and at what URL - the decision, with no
  side effect.

  `opts` overrides what would otherwise be read from the real application
  and system state, which is what makes this testable without spawning
  anything:

    * `:local_mode?` - defaults to `PairingsEngine.Authz.local_mode?/0`
    * `:suppressed?` - defaults to whether `OPENPAIRINGS_NO_BROWSER` is set
    * `:port` - defaults to the endpoint's configured HTTP port
  """
  @spec plan(keyword()) :: {:open, String.t()} | :skip
  def plan(opts \\ []) do
    local? = Keyword.get_lazy(opts, :local_mode?, &Authz.local_mode?/0)
    suppressed? = Keyword.get_lazy(opts, :suppressed?, &suppressed?/0)

    cond do
      not local? -> :skip
      suppressed? -> :skip
      true -> {:open, url(opts)}
    end
  end

  @doc """
  Acts on `plan/0`, for real.

  Called once at boot, from `PairingsEngine.Application.start/2`; see the
  moduledoc for why that call site is safe. Never raises: a failure while
  deciding, launching, or in between is logged and swallowed.
  """
  @spec maybe_open() :: :ok
  def maybe_open do
    case plan() do
      {:open, url} -> Task.start(fn -> open(url) end)
      :skip -> :ok
    end

    :ok
  rescue
    error ->
      Logger.warning("browser launcher did not run: #{Exception.message(error)}")
      :ok
  end

  defp suppressed?, do: System.get_env("OPENPAIRINGS_NO_BROWSER") in ["1", "true", "yes"]

  defp url(opts) do
    port = Keyword.get_lazy(opts, :port, &endpoint_port/0)
    "http://localhost:#{port}"
  end

  # Read from the endpoint's own (already-resolved) config rather than
  # `Application.get_env` directly, and defaulted rather than raising: a
  # missing port here should show a wrong tab, never take the decision
  # above down with it.
  defp endpoint_port do
    PairingsEngineWeb.Endpoint.config(:http)[:port] || 4000
  end

  @doc false
  @spec command(String.t(), {atom(), atom()}) :: {String.t(), [String.t()]}
  def command(url, os_type \\ :os.type())

  # `start` treats a quoted first argument as the new window's title rather
  # than the thing to open - the empty string supplies that title so `url`
  # is read as the target instead, the standard workaround for `cmd /c start`.
  def command(url, {:win32, _}), do: {"cmd", ["/c", "start", "", url]}
  def command(url, {:unix, :darwin}), do: {"open", [url]}
  def command(url, {:unix, _}), do: {"xdg-open", [url]}

  # Fire-and-forget in its own unlinked process: `xdg-open` can hang waiting
  # on a D-Bus session that will never come on a headless box, and nothing
  # here may block, crash its caller, or retry.
  defp open(url) do
    {cmd, args} = command(url)

    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        Logger.info("could not open a browser (#{cmd} exited #{status}): #{String.trim(output)}")
    end
  rescue
    error -> Logger.info("could not open a browser: #{Exception.message(error)}")
  catch
    kind, reason -> Logger.info("could not open a browser: #{inspect({kind, reason})}")
  end
end
