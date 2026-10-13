defmodule PairingsEngineWeb.BoardLan do
  @moduledoc """
  "Let boards on this network connect": a desktop copy's second listener,
  for a hall box (`PairingsEngine.BoardLink`) that is not on this PC.

  ## What it is

  A desktop copy answers on 127.0.0.1 and nowhere else, and that stays so:
  the pin is what makes having no login safe (`config/runtime.exs`), and
  nothing in this module touches that listener. This is a *second* one, off
  until the arbiter switches it on, on its own port, bound to the one
  network address the arbiter picked, serving `PairingsEngineWeb.BoardLan.Plug`
  - the board link's four requests and a 404 for everything else. The
  arbiter's pages are not behind it. They are not anywhere near it.

  A hosted server has none of this: `available?/0` is local mode, every
  entrance asks it first, and the process started for it sits idle for the
  life of the node (the same arrangement as `PairingsEngine.Updates.Checker`).

  ## When it listens

  All of these, or it does not:

    * the switch is on (`meta`, so it survives a restart);
    * the chosen address is still one of this PC's. If the network handed
      the PC another address, the listener stays down and the page says
      which address went: it does not move to the new one by itself, because
      "the laptop is on a different network now" is exactly when nobody
      wants a port opened without being asked;
    * a code made for the network exists that can still open something
      (`PairingsEngine.BoardLink.lan_codes?/0`). No code, no open port:
      withdraw the last one and the listener closes.

  ## What it does not do

  TLS. The secret of a network code crosses the hall in plain http; the page
  and the manual say so and say what to do about it (a cable, or a network
  the players are not on). What is cheap is done instead: private addresses
  only, on both ends; codes of their own kind that expire; a closed port
  whenever no such code exists.

  IPv6. A hall's link-local v6 address needs a zone to be dialled, which a
  URL in a QR code cannot carry in a way every client reads; a hall network
  that has no IPv4 at all has not been met yet.

  ## Moving parts

  One `GenServer` that owns the decision and a `DynamicSupervisor` that owns
  the Bandit it starts and stops, so switching is a child coming and going
  and never a restart of anything else. Every public function is a call
  into the server: two pages pressing the switch at once are two calls in a
  queue, not a race.
  """
  use GenServer

  require Logger

  alias PairingsEngine.{Authz, BoardLink, Meta}

  @supervisor PairingsEngineWeb.BoardLan.Supervisor

  # Not 4000 (this program), not 4001 (the results site next to it), not a
  # port anything well known uses, and under the range Windows hands out for
  # outgoing connections.
  @default_port 4747

  @enabled_key "board_lan_enabled"
  @address_key "board_lan_address"
  @port_key "board_lan_port"

  @type state_name ::
          :off | :idle | :listening | :port_taken | :address_gone | :no_address | :failed

  ## ---------- what pages ask ----------

  @doc "Whether this edition has the switch at all: a desktop copy, and only that."
  def available?, do: Authz.local_mode?()

  @doc "The port offered until the arbiter picks another."
  def default_port, do: @default_port

  @doc """
  Where things stand, after looking again:

      %{available?:, enabled?:, state:, address:, port:, addresses:, base_url:, name_url:}

  `state` is `:off`, `:idle` (on, and waiting for a network code to exist),
  `:listening`, `:port_taken`, `:address_gone` (the chosen address is no
  longer this PC's), `:no_address` (this PC has no private network address)
  or `:failed`. `base_url` is what a network code is made with, or nil while
  none can be made.
  """
  def status do
    if available?(), do: call(:status), else: unavailable()
  end

  @doc "Switches it on or off. `{:ok, status}`, or `{:error, :unavailable}` on a server."
  def switch(on?) when is_boolean(on?) do
    if available?(), do: call({:switch, on?}), else: {:error, :unavailable}
  end

  @doc """
  Picks the address to listen on and the port. `{:ok, status}`, or
  `{:error, :not_an_address}` for one that is not this PC's, `{:error,
  :bad_port}` for one that is not a port, a privileged one, or this
  program's own.
  """
  def choose(address, port) do
    if available?(), do: call({:choose, address, port}), else: {:error, :unavailable}
  end

  @doc "Whether a code for a box on the network can be made right now."
  def usable?(%{state: state}), do: state in [:idle, :listening]

  defp call(message) do
    GenServer.call(__MODULE__, message, 15_000)
  catch
    # Not running (a test that never started it), or busy for fifteen
    # seconds: the page gets "off", not a crash.
    :exit, _reason -> if message == :status, do: unavailable(), else: {:error, :unavailable}
  end

  defp unavailable do
    %{
      available?: false,
      enabled?: false,
      state: :off,
      address: nil,
      port: @default_port,
      addresses: [],
      base_url: nil,
      name_url: nil
    }
  end

  ## ---------- addresses ----------

  @doc """
  This PC's private IPv4 addresses, as text, in a stable order: the ones a
  box in the same hall could dial. 10/8, 172.16/12, 192.168/16, and
  169.254/16 - which is what two machines joined by one cable and no router
  give each other.
  """
  def addresses do
    case Application.get_env(:pairings_engine, :board_lan_addresses) do
      list when is_list(list) -> list
      fun when is_function(fun, 0) -> fun.()
      _none -> interface_addresses()
    end
  end

  defp interface_addresses do
    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        found =
          for {_name, opts} <- interfaces,
              flags = Keyword.get(opts, :flags, []),
              :up in flags and :loopback not in flags,
              {:addr, {_, _, _, _} = ip} <- opts,
              hall_address?(ip),
              do: ip |> :inet.ntoa() |> to_string()

        found |> Enum.uniq() |> Enum.sort()

      _error ->
        []
    end
  end

  defp hall_address?({10, _, _, _}), do: true
  defp hall_address?({172, b, _, _}) when b in 16..31, do: true
  defp hall_address?({192, 168, _, _}), do: true
  defp hall_address?({169, 254, _, _}), do: true
  defp hall_address?(_other), do: false

  @doc """
  Whether a caller's address is one a hall network has: the private IPv4
  ranges above, loopback, and their IPv6 counterparts (unique local,
  link-local, and an IPv4 address written as IPv6). The listener refuses
  everybody else, so a PC that turns out to have a public address on that
  interface is still not serving the internet.
  """
  def private_address?({127, _, _, _}), do: true
  def private_address?({_, _, _, _} = ip), do: hall_address?(ip)
  def private_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  def private_address?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}),
    do: private_address?({div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)})

  def private_address?({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: true
  def private_address?({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF, do: true
  def private_address?(_other), do: false

  ## ---------- the server ----------

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    state = %{server: nil, ref: nil, bound: nil, name: :off, probe: nil}

    # After `init/1`, not in it: reading the switch is a query, and a
    # supervisor waiting on a query is a boot that can hang on one.
    if available?(), do: {:ok, state, {:continue, :boot}}, else: {:ok, state}
  end

  @impl true
  def handle_continue(:boot, state) do
    # A listener left over from a previous life of this process (it was
    # restarted; the supervisor beside it was not) belongs to nobody now.
    # Close it and decide afresh, rather than find the port "in use" by
    # ourselves.
    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(@supervisor),
        is_pid(pid),
        do: DynamicSupervisor.terminate_child(@supervisor, pid)

    state = safely(state, &reconcile(&1, probe: true))
    safely(state, &warn_if_moved/1)
    schedule_tick()
    {:noreply, state}
  end

  # At start-up, in the log: the page says the same to whoever opens it.
  defp warn_if_moved(%{name: :address_gone} = state) do
    config = config()

    Logger.warning(
      "Boards on the network: this PC no longer has the address #{config.address} " <>
        "(it has: #{Enum.join(config.addresses, ", ")}). Boxes holding a code with the old " <>
        "address cannot find it. Settings, Live boards says what to do."
    )

    state
  end

  defp warn_if_moved(state), do: state

  @impl true
  def handle_call(:status, _from, state) do
    state = reconcile(state, [])
    {:reply, describe(state), state}
  end

  def handle_call({:switch, on?}, _from, state) do
    if on? do
      Meta.put(@enabled_key, "1")
      config = config()

      # The first time: take the PC's address rather than make the arbiter
      # choose from a list of one. An address that was chosen and is gone
      # is NOT replaced here - see the moduledoc.
      if is_nil(config.address) and config.addresses != [],
        do: Meta.put(@address_key, hd(config.addresses))
    else
      Meta.delete(@enabled_key)
    end

    state = reconcile(state, probe: true)
    {:reply, {:ok, describe(state)}, state}
  end

  def handle_call({:choose, address, port}, _from, state) do
    with {:ok, port} <- port(port),
         :ok <- if(address in addresses(), do: :ok, else: {:error, :not_an_address}) do
      Meta.put(@address_key, address)
      Meta.put(@port_key, Integer.to_string(port))
      state = reconcile(state, probe: true)
      {:reply, {:ok, describe(state)}, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    state = if available?(), do: safely(state, &reconcile(&1, [])), else: state
    schedule_tick()
    {:noreply, state}
  end

  # The listener went down by itself. Look again; if it should be up it is
  # started again, once, and if that fails the page says so.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{ref: ref} = state) do
    state = %{state | server: nil, ref: nil, bound: nil}
    state = if available?(), do: safely(state, &reconcile(&1, [])), else: state
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # For the places nobody is waiting on an answer: a database that is not
  # there for a moment must not take the process down with it.
  defp safely(state, fun) do
    fun.(state)
  rescue
    error ->
      Logger.warning("Boards on the network: could not look again (#{Exception.message(error)})")
      state
  end

  defp schedule_tick do
    case Application.get_env(:pairings_engine, :board_lan_tick_ms, 30_000) do
      ms when is_integer(ms) and ms > 0 -> Process.send_after(self(), :tick, ms)
      _disabled -> :ok
    end
  end

  ## ---------- deciding ----------

  defp config do
    %{
      enabled?: Meta.get(@enabled_key) == "1",
      address: Meta.get(@address_key),
      port: stored_port(),
      addresses: addresses()
    }
  end

  defp stored_port do
    case Integer.parse(Meta.get(@port_key) || "") do
      {port, ""} when port in 1024..65_535 -> port
      _unset -> @default_port
    end
  end

  defp port(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {port, ""} -> port(port)
      _other -> {:error, :bad_port}
    end
  end

  defp port(value) when is_integer(value) and value in 1024..65_535 do
    if value == own_port(), do: {:error, :bad_port}, else: {:ok, value}
  end

  defp port(_other), do: {:error, :bad_port}

  # The port the arbiter's own pages are on. Offering it to the hall would
  # be a different feature, and not one anybody asked for.
  defp own_port do
    case PairingsEngineWeb.Endpoint.config(:http) do
      http when is_list(http) -> Keyword.get(http, :port)
      _other -> nil
    end
  end

  defp wanted(config) do
    cond do
      not config.enabled? -> :off
      is_nil(config.address) -> :no_address
      config.address not in config.addresses -> :address_gone
      not BoardLink.lan_codes?() -> :idle
      true -> :listen
    end
  end

  defp reconcile(state, opts) do
    config = config()
    target = {config.address, config.port}

    case wanted(config) do
      :listen ->
        if state.server && state.bound == target && Process.alive?(state.server) do
          %{state | name: :listening}
        else
          state |> stop() |> start(target)
        end

      :idle ->
        state = stop(state)

        # Is the port free? Asked when somebody changed something, so a port
        # that is taken is said on the page now and not on the morning of
        # the tournament - and not asked every thirty seconds for ever.
        result =
          case state.probe do
            {^target, known} ->
              if Keyword.get(opts, :probe, false), do: probe(target), else: known

            _other ->
              probe(target)
          end

        %{state | probe: {target, result}, name: if(result == :ok, do: :idle, else: result)}

      other ->
        %{stop(state) | name: other}
    end
  end

  defp stop(%{server: nil} = state), do: state

  defp stop(%{server: pid, ref: ref} = state) do
    if ref, do: Process.demonitor(ref, [:flush])
    _ = DynamicSupervisor.terminate_child(@supervisor, pid)
    %{state | server: nil, ref: nil, bound: nil}
  end

  defp start(state, {address, port} = target) do
    with :ok <- probe(target),
         {:ok, ip} <- :inet.parse_ipv4strict_address(String.to_charlist(address)),
         {:ok, pid} <- DynamicSupervisor.start_child(@supervisor, listener(ip, port)) do
      Logger.info("Boards on the network: answering the board link at http://#{address}:#{port}")

      %{
        state
        | server: pid,
          ref: Process.monitor(pid),
          bound: target,
          name: :listening,
          probe: {target, :ok}
      }
    else
      failure ->
        name = failure_name(failure)
        Logger.warning("Boards on the network: not listening on #{address}:#{port} (#{name})")
        %{state | name: name, probe: {target, name}}
    end
  end

  # `:temporary`: a listener that cannot stay up is not restarted in a loop
  # by the supervisor. This process hears about it and decides.
  defp listener(ip, port) do
    Supervisor.child_spec(
      {Bandit,
       plug: PairingsEngineWeb.BoardLan.Plug,
       scheme: :http,
       ip: ip,
       port: port,
       startup_log: false,
       thousand_island_options: [num_acceptors: 4, num_connections: 256]},
      restart: :temporary
    )
  end

  # Opens the port for an instant and closes it again, to learn whether it
  # can be opened. Twice: on the address itself, and on every address -
  # Windows lets a second program bind one address of a port a first program
  # holds on all of them, and "it started, and the other program gets half
  # the requests" is not a state anybody should have to debug in a hall.
  defp probe(target), do: probe(target, 10)

  # A port this program closed a moment ago can still read as taken (the
  # probe refuses to share it, on purpose, and the system keeps a closed
  # port's last connections around for a little while): off and on again
  # within the second said "port in use" about its own port. Ask again for
  # up to a second before believing it; another program's port is still
  # taken after that.
  defp probe({address, port} = target, tries) do
    with {:ok, ip} <- :inet.parse_ipv4strict_address(String.to_charlist(address)),
         :ok <- try_listen(ip, port),
         :ok <- try_listen({0, 0, 0, 0}, port) do
      :ok
    else
      {:error, :eaddrinuse} when tries > 1 ->
        Process.sleep(100)
        probe(target, tries - 1)

      failure ->
        failure_name(failure)
    end
  end

  defp try_listen(ip, port) do
    case :gen_tcp.listen(port, [:binary, ip: ip, active: false, reuseaddr: false]) do
      {:ok, socket} -> :gen_tcp.close(socket)
      {:error, reason} -> {:error, reason}
    end
  end

  defp failure_name(name) when name in [:port_taken, :address_gone, :failed], do: name

  defp failure_name(failure) do
    text = inspect(failure)

    cond do
      text =~ "eaddrinuse" or text =~ "eacces" -> :port_taken
      text =~ "eaddrnotavail" or text =~ "einval" -> :address_gone
      true -> :failed
    end
  end

  ## ---------- describing ----------

  defp describe(state) do
    config = config()
    usable? = state.name in [:idle, :listening]

    %{
      available?: true,
      enabled?: config.enabled?,
      state: state.name,
      address: config.address,
      port: config.port,
      addresses: config.addresses,
      base_url: if(usable?, do: "http://#{config.address}:#{config.port}"),
      name_url: if(usable?, do: name_url(config))
    }
  end

  # The same address by this PC's name, where the name leads there and only
  # there. A name survives the network handing out another address; whether
  # the box can look it up is the box's network's business, and the page
  # says so.
  #
  # "Only there" was learnt by trying it: a PC on three networks has a name
  # that leads to three addresses, the listener is on one of them, and a
  # client that takes the first answer gets a timeout two times in three. A
  # code that works on some attempts is worse than no code, so such a PC is
  # offered its address and nothing else.
  defp name_url(config) do
    with {:ok, name} <- :inet.gethostname(),
         name = to_string(name),
         true <- name =~ ~r/\A[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z/,
         {:ok, ips} <- :inet.getaddrs(String.to_charlist(name), :inet),
         true <- Enum.map(ips, &(&1 |> :inet.ntoa() |> to_string())) == [config.address] do
      "http://#{String.downcase(name)}:#{config.port}"
    else
      _no -> nil
    end
  end
end
