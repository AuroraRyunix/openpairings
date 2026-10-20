defmodule PairingsEngineWeb.PhoneLan do
  @moduledoc """
  "Let phones on this network connect": a desktop copy's listener for
  Manubrium, the arbiters' phone pages (docs/manubrium.md).

  The board link's listener (`PairingsEngineWeb.BoardLan`) is the model, and
  the same promises hold. The desktop's own listener stays on 127.0.0.1 -
  that pin is what makes having no login safe (`config/runtime.exs`) and
  nothing here moves it. This is a *separate* listener, off until the
  arbiter switches it on, on its own port, bound to one private address of
  this PC, answering callers with a private address only, and serving
  `PairingsEngineWeb.PhoneLan.Plug`: the phone pages under `/m`, the
  LiveView socket they talk over, and the public static files they load. A
  404 for everything else. The arbiter's desk pages are not behind it.

  It differs from the board link's in one way, because a phone is a browser
  and a box is not: behind the path list sits the ordinary endpoint, so the
  phone pages are the same pages. What keeps the rest of the program out is
  the list (`PairingsEngineWeb.PhoneLan.Plug.phone_route?/2`), the
  loopback-only sign-in (`PairingsEngineWeb.UserAuth.local_owner_session/2`,
  which a network caller never passes), and the LiveView socket refusing to
  join a page its session token was not issued for.

  ## When it listens

  All of these, or it does not:

    * the switch is on (`meta`, so it survives a restart);
    * the chosen address is still one of this PC's (it does not follow the
      PC to another network by itself);
    * at least one phone code is active (`PairingsEngine.Mobile.any_active?/0`),
      or a Manubrium app is connected or about to be
      (`PairingsEngine.Manubrium.any_active?/0`). Revoke or outlive the last
      of them and the port closes.

  The full app's API (`/api/manubrium/v1`) rides the same listener: a phone
  in the hall reaches a desktop copy the way the hall pages do.

  ## What it does not do

  TLS, as with the boards: the hall network is plain http, and so is a
  phone code crossing it. A desktop build marks its session cookie
  `Secure`, which a phone would refuse to keep over http, so this listener
  - and only this one - hands it out without the flag
  (`PairingsEngineWeb.PhoneLan.Plug`).
  """
  use GenServer

  require Logger

  alias PairingsEngine.{Authz, Manubrium, Meta, Mobile}
  alias PairingsEngineWeb.BoardLan

  @supervisor PairingsEngineWeb.PhoneLan.Supervisor

  # The board link's is 4747; the phones get the next one.
  @default_port 4748

  @address_key "phone_lan_address"
  @port_key "phone_lan_port"

  ## ---------- what pages ask ----------

  @doc "Whether this edition has the switch at all: a desktop copy, and only that."
  def available?, do: Authz.local_mode?()

  @doc "The port offered until the arbiter picks another."
  def default_port, do: @default_port

  @doc """
  Where things stand, after looking again:

      %{available?:, enabled?:, state:, address:, port:, addresses:, base_url:}

  `state` is `:off`, `:idle` (on, waiting for a phone code to exist),
  `:listening`, `:port_taken`, `:address_gone`, `:no_address` or
  `:failed`. `base_url` is what a phone code's link is made with, or nil
  while none can be.
  """
  def status do
    if available?(), do: call(:status), else: unavailable()
  end

  @doc "Switches it on or off. `{:ok, status}`, or `{:error, :unavailable}` on a server."
  def switch(on?) when is_boolean(on?) do
    if available?(), do: call({:switch, on?}), else: {:error, :unavailable}
  end

  @doc """
  Picks the address and port. `{:ok, status}`, or `{:error,
  :not_an_address | :bad_port}`.
  """
  def choose(address, port) do
    if available?(), do: call({:choose, address, port}), else: {:error, :unavailable}
  end

  @doc """
  For `Plug.SSL`'s `exclude` (config/prod.exs): a request that came in on
  this listener is plain http by design, and redirecting it to an https
  nobody serves would lock every phone out.
  """
  def lan_request?(%Plug.Conn{private: %{phone_lan: true}}), do: true
  def lan_request?(_conn), do: false

  @doc """
  The LiveView socket's origin check on a desktop copy
  (`config/runtime.exs`): the endpoint's own host, as Phoenix's default
  check would allow, and this listener's address and port while it
  listens. Nothing else.
  """
  def origin_allowed?(%URI{host: host, port: port}) do
    own = PairingsEngineWeb.Endpoint.config(:url)[:host] || "localhost"

    cond do
      host == own -> true
      host in ["localhost", "127.0.0.1"] and own in ["localhost", "127.0.0.1"] -> true
      true -> listening_on?(host, port)
    end
  end

  def origin_allowed?(_uri), do: false

  defp listening_on?(host, port) do
    case :persistent_term.get({__MODULE__, :bound}, nil) do
      {^host, ^port} -> true
      _other -> false
    end
  end

  defp call(message) do
    GenServer.call(__MODULE__, message, 15_000)
  catch
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
      base_url: nil
    }
  end

  ## ---------- the server ----------

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    state = %{server: nil, ref: nil, bound: nil, name: :off}
    if available?(), do: {:ok, state, {:continue, :boot}}, else: {:ok, state}
  end

  @impl true
  def handle_continue(:boot, state) do
    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(@supervisor),
        is_pid(pid),
        do: DynamicSupervisor.terminate_child(@supervisor, pid)

    state = safely(state, &reconcile/1)
    schedule_tick()
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    state = reconcile(state)
    {:reply, describe(state), state}
  end

  def handle_call({:switch, on?}, _from, state) do
    if on? do
      Meta.put(Mobile.lan_key(), "1")
      config = config()

      if is_nil(config.address) and config.addresses != [],
        do: Meta.put(@address_key, hd(config.addresses))
    else
      Meta.delete(Mobile.lan_key())
    end

    state = reconcile(state)
    {:reply, {:ok, describe(state)}, state}
  end

  def handle_call({:choose, address, port}, _from, state) do
    with {:ok, port} <- port(port),
         :ok <- if(address in BoardLan.addresses(), do: :ok, else: {:error, :not_an_address}) do
      Meta.put(@address_key, address)
      Meta.put(@port_key, Integer.to_string(port))
      state = reconcile(state)
      {:reply, {:ok, describe(state)}, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    state = if available?(), do: safely(state, &reconcile/1), else: state
    schedule_tick()
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{ref: ref} = state) do
    state = forget(%{state | server: nil, ref: nil, bound: nil})
    state = if available?(), do: safely(state, &reconcile/1), else: state
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp safely(state, fun) do
    fun.(state)
  rescue
    error ->
      Logger.warning("Phones on the network: could not look again (#{Exception.message(error)})")
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
      enabled?: Meta.get(Mobile.lan_key()) == "1",
      address: Meta.get(@address_key),
      port: stored_port(),
      addresses: BoardLan.addresses()
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
    taken = [own_port(), BoardLan.status().port]
    if value in taken, do: {:error, :bad_port}, else: {:ok, value}
  end

  defp port(_other), do: {:error, :bad_port}

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
      not (Mobile.any_active?() or Manubrium.any_active?()) -> :idle
      true -> :listen
    end
  end

  defp reconcile(state) do
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
        %{stop(state) | name: :idle}

      other ->
        %{stop(state) | name: other}
    end
  end

  defp stop(%{server: nil} = state), do: state

  defp stop(%{server: pid, ref: ref} = state) do
    if ref, do: Process.demonitor(ref, [:flush])
    _ = DynamicSupervisor.terminate_child(@supervisor, pid)
    forget(%{state | server: nil, ref: nil, bound: nil})
  end

  defp forget(state) do
    :persistent_term.erase({__MODULE__, :bound})
    state
  end

  defp start(state, {address, port} = target) do
    with {:ok, ip} <- :inet.parse_ipv4strict_address(String.to_charlist(address)),
         {:ok, pid} <- DynamicSupervisor.start_child(@supervisor, listener(ip, port)) do
      Logger.info("Phones on the network: Manubrium answers at http://#{address}:#{port}/m")
      :persistent_term.put({__MODULE__, :bound}, {address, port})
      %{state | server: pid, ref: Process.monitor(pid), bound: target, name: :listening}
    else
      failure ->
        name = failure_name(failure)
        Logger.warning("Phones on the network: not listening on #{address}:#{port} (#{name})")
        %{state | name: name}
    end
  end

  defp listener(ip, port) do
    Supervisor.child_spec(
      {Bandit,
       plug: PairingsEngineWeb.PhoneLan.Plug,
       scheme: :http,
       ip: ip,
       port: port,
       startup_log: false,
       thousand_island_options: [num_acceptors: 4, num_connections: 256]},
      restart: :temporary
    )
  end

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
      base_url: if(usable?, do: "http://#{config.address}:#{config.port}")
    }
  end
end
