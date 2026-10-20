defmodule PairingsEngine.EngineSlots do
  @moduledoc """
  How many engine runs this machine does at once, and which tournament is
  already being paired.

  The hosted server has two cores and some two dozen accounts. Before this,
  every "Pair round" click was its own engine run with nobody counting: a
  team Swiss at a few hundred teams is tens of seconds of CPU, the guard
  against a second click lived in ONE page's assigns (so a second tab was a
  second run of the same round), and a run carried on after the page that
  asked for it had gone. Ten tabs was ten runs and an unanswerable box for
  everybody else. Optimism is not a scheduling policy.

  ## Pools

  Each kind of work has its own pool, so a long preview cannot keep a round
  from being paired and the commentary cannot starve either:

    * `:pairing` - pairing a round (`PairingsEngineWeb.PairingsLive`),
      individual and team alike. Keyed by tournament: a tournament already
      being paired - or waiting for a slot - refuses a second run outright
      instead of queueing it behind the first, because the second would
      only pair a round that no longer needs pairing.
    * `:preview` - the next-round preview (`PairingsEngine.NextRoundPreview`).
    * `:explanation` - a round's engine account and its alternatives
      (`PairingsEngine.ExplanationJobs`), background work that can wait.

  How many of each run at once is `limit/1`: on the hosted edition the
  configured number (`config :pairings_engine, :engine_slots, pairing: 2`,
  or `PAIRINGS_ENGINE_SLOTS` for the pairing pool), on a desktop install
  `:infinity` - the only person a desktop run could starve is the one who
  started it, and they can see the spinner. The per-tournament lock applies
  everywhere: two tabs pairing the same round is a mistake on any machine.

  ## Holding a slot

  `request/3` either grants a slot at once, queues the caller, or refuses.
  A queued caller hears `{:engine_slot, ref, :granted}` when its turn comes
  (`await/2` waits for it). A slot belongs to the PROCESS that asked: the
  server monitors it, so a holder that dies - a closed tab's task, a killed
  run - gives its slot back without anyone remembering to.

  `run/4` is the whole sequence with a time limit on the work itself, which
  is what callers normally want.
  """
  use GenServer

  require Logger

  @pools [:pairing, :preview, :explanation]

  @default_limits %{pairing: 2, preview: 1, explanation: 2}

  # A team Swiss of 300-500 teams pairs in 10-50 seconds on the hosted box.
  # Three minutes is several times the worst real field, and still an end.
  @default_pairing_timeout_ms 180_000

  @type pool :: :pairing | :preview | :explanation

  ## ---------- configuration ----------

  @doc """
  How many runs of `pool` may go at once: `:infinity` on a desktop install,
  the configured number (default #{inspect(@default_limits)}) on the hosted
  edition.
  """
  @spec limit(pool()) :: pos_integer() | :infinity
  def limit(pool) when pool in @pools do
    if PairingsEngine.Authz.local_mode?() do
      :infinity
    else
      configured = Application.get_env(:pairings_engine, :engine_slots, [])

      case configured[pool] do
        n when is_integer(n) and n > 0 -> n
        :infinity -> :infinity
        _ -> Map.fetch!(@default_limits, pool)
      end
    end
  end

  @doc """
  How long one pairing run may take before it is stopped: `:infinity` on a
  desktop install, `:pairing_timeout_ms` (default three minutes, or
  `PAIRINGS_PAIRING_TIMEOUT_S`) on the hosted edition.
  """
  @spec pairing_timeout() :: pos_integer() | :infinity
  def pairing_timeout do
    if PairingsEngine.Authz.local_mode?(),
      do: :infinity,
      else:
        Application.get_env(
          :pairings_engine,
          :pairing_timeout_ms,
          @default_pairing_timeout_ms
        )
  end

  ## ---------- the client side ----------

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Asks for a slot in `pool` for the calling process. `key` (a tournament id,
  or nil for none) is the lock: while a run with the same key holds a slot
  or waits for one, another is refused.

    * `{:ok, ref}` - granted; `release/2` it when done (or just exit).
    * `{:queued, ref}` - every slot is taken; `await/2` the grant.
    * `{:error, :engine_already_pairing}` - `key` is already running or queued.

  `opts`: `:server` (default this module), `:limit` (overrides `limit/1`,
  for a test's own server).
  """
  @spec request(pool(), term(), keyword()) ::
          {:ok, reference()} | {:queued, reference()} | {:error, :engine_already_pairing}
  def request(pool, key, opts \\ []) when pool in @pools do
    limit = Keyword.get_lazy(opts, :limit, fn -> limit(pool) end)
    GenServer.call(server(opts), {:request, pool, key, self(), limit})
  end

  @doc """
  Waits up to `timeout` for a queued request's grant. `:ok`, or
  `{:error, :engine_busy}` - in which case the place in the queue is given
  up, so a slot is never granted to somebody who stopped waiting.
  """
  @spec await(reference(), timeout(), keyword()) :: :ok | {:error, :engine_busy}
  def await(ref, timeout, opts \\ []) do
    receive do
      {:engine_slot, ^ref, :granted} -> :ok
    after
      timeout ->
        release(ref, opts)

        # The grant may have crossed the release in the post. Whatever
        # arrived is answered by the release above; just do not leave it
        # in the mailbox.
        receive do
          {:engine_slot, ^ref, :granted} -> :ok
        after
          0 -> :ok
        end

        {:error, :engine_busy}
    end
  end

  @doc "Gives back the slot (or the place in the queue) `ref` names."
  @spec release(reference(), keyword()) :: :ok
  def release(ref, opts \\ []), do: GenServer.call(server(opts), {:release, ref})

  @doc """
  Runs `fun` under a slot of `pool` and returns what it returned - or
  `{:error, reason}` without running it, or having stopped it:

    * `:engine_already_pairing` - `key` is already running or waiting;
    * `:engine_busy` - no slot came free within `:wait`;
    * `:engine_timeout` - `fun` ran past `:timeout` and was stopped;
    * `:engine_failed` - `fun` raised or exited.

  `opts`:

    * `:wait` - how long to wait for a slot (default `:infinity`);
    * `:timeout` - how long `fun` may run (default `:infinity`). Anything
      but `:infinity` runs `fun` in a task of its own, killed at the limit,
      so a run that has lost its way does not keep the slot - or the core -
      for ever. Gettext's locale goes with it, so an engine message still
      speaks the arbiter's language;
    * `:on_queued` - a zero-arity function called once if the run has to
      wait, so whoever is watching can be told it is queued, not hung;
    * `:server`, `:limit` - as for `request/3`.
  """
  @spec run(pool(), term(), (-> result), keyword()) :: result | {:error, atom()}
        when result: term()
  def run(pool, key, fun, opts \\ []) when is_function(fun, 0) do
    with {:ok, ref} <- acquire(pool, key, opts) do
      try do
        work(fun, Keyword.get(opts, :timeout, :infinity))
      after
        release(ref, opts)
      end
    end
  end

  defp acquire(pool, key, opts) do
    case request(pool, key, opts) do
      {:ok, ref} ->
        {:ok, ref}

      {:queued, ref} ->
        if on_queued = opts[:on_queued], do: on_queued.()

        with :ok <- await(ref, Keyword.get(opts, :wait, :infinity), opts), do: {:ok, ref}

      {:error, _} = refused ->
        refused
    end
  end

  defp work(fun, :infinity), do: fun.()

  defp work(fun, timeout) do
    locale = Gettext.get_locale(PairingsEngineWeb.Gettext)

    task =
      Task.Supervisor.async_nolink(PairingsEngine.TaskSupervisor, fn ->
        Gettext.put_locale(PairingsEngineWeb.Gettext, locale)
        fun.()
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        Logger.warning("An engine run passed its #{timeout} ms limit and was stopped")
        {:error, :engine_timeout}

      {:exit, reason} ->
        Logger.error("An engine run failed: #{Exception.format_exit(reason)}")
        {:error, :engine_failed}
    end
  end

  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)

  ## ---------- the server side ----------

  # State: per pool, the running slots (ref => {pid, key}) and the queue
  # (oldest first, [{ref, pid, key}]); plus one monitor per holding or
  # waiting process (pid => monitor ref), so its death frees everything it
  # held.

  @impl true
  def init(_opts) do
    pools = Map.new(@pools, &{&1, %{running: %{}, queue: []}})
    {:ok, %{pools: pools, monitors: %{}, owner: %{}}}
  end

  @impl true
  def handle_call({:request, pool, key, pid, limit}, _from, state) do
    %{running: running, queue: queue} = state.pools[pool]

    cond do
      key != nil and taken?(running, queue, key) ->
        {:reply, {:error, :engine_already_pairing}, state}

      below?(map_size(running), limit) ->
        ref = make_ref()
        state = state |> watch(pid) |> put_running(pool, ref, pid, key)
        {:reply, {:ok, ref}, state}

      true ->
        ref = make_ref()

        state =
          state |> watch(pid) |> update_pool(pool, &%{&1 | queue: queue ++ [{ref, pid, key}]})

        state = %{state | owner: Map.put(state.owner, ref, {pool, limit})}
        {:reply, {:queued, ref}, state}
    end
  end

  def handle_call({:release, ref}, _from, state), do: {:reply, :ok, drop(state, ref)}

  @impl true
  def handle_info({:DOWN, _mon, :process, pid, _reason}, state) do
    refs =
      for {_pool, %{running: running, queue: queue}} <- state.pools,
          ref <-
            for({ref, {^pid, _key}} <- running, do: ref) ++
              for({ref, ^pid, _key} <- queue, do: ref),
          do: ref

    state = Enum.reduce(refs, state, &drop(&2, &1))
    {:noreply, %{state | monitors: Map.delete(state.monitors, pid)}}
  end

  defp taken?(running, queue, key) do
    Enum.any?(running, fn {_ref, {_pid, k}} -> k == key end) or
      Enum.any?(queue, fn {_ref, _pid, k} -> k == key end)
  end

  defp below?(_count, :infinity), do: true
  defp below?(count, limit), do: count < limit

  defp watch(state, pid) do
    if Map.has_key?(state.monitors, pid),
      do: state,
      else: %{state | monitors: Map.put(state.monitors, pid, Process.monitor(pid))}
  end

  defp put_running(state, pool, ref, pid, key),
    do: update_pool(state, pool, &%{&1 | running: Map.put(&1.running, ref, {pid, key})})

  defp update_pool(state, pool, fun), do: %{state | pools: Map.update!(state.pools, pool, fun)}

  # Removes `ref` wherever it is - a running slot or a place in the queue -
  # then lets the queue move up into whatever room that made.
  defp drop(state, ref) do
    pool =
      Enum.find_value(state.pools, fn {pool, %{running: running, queue: queue}} ->
        if Map.has_key?(running, ref) or List.keymember?(queue, ref, 0), do: pool
      end)

    case pool do
      nil ->
        state

      pool ->
        state
        |> update_pool(pool, fn p ->
          %{p | running: Map.delete(p.running, ref), queue: List.keydelete(p.queue, ref, 0)}
        end)
        |> Map.update!(:owner, &Map.delete(&1, ref))
        |> promote(pool)
    end
  end

  # The oldest waiter gets the room, if there is room for it - judged by the
  # limit it asked under, which is the limit of the moment it asked.
  defp promote(state, pool) do
    case state.pools[pool] do
      %{queue: [{ref, pid, key} | rest], running: running} ->
        {_pool, limit} = Map.get(state.owner, ref, {pool, limit(pool)})

        if below?(map_size(running), limit) do
          send(pid, {:engine_slot, ref, :granted})

          state
          |> update_pool(pool, &%{&1 | queue: rest})
          |> put_running(pool, ref, pid, key)
          |> Map.update!(:owner, &Map.delete(&1, ref))
          |> promote(pool)
        else
          state
        end

      _ ->
        state
    end
  end
end
