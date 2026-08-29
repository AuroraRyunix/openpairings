defmodule PairingsEngine.RateLimit do
  @moduledoc """
  Rolling-window counters for the endpoints anyone can reach without an
  account, keyed by whatever identifies the abuser there.

  One `GenServer` owns a `:public` ETS table (same pattern as
  `PairingsEngine.Tools.Session`) so callers count straight into it with no
  message pass; the server exists to own the table and to sweep windows that
  have rolled past.

  ## Buckets

    * `:mobile_enroll` - wrong enrollment codes, keyed by client address. The
      code is short and `PairingsEngine.Mobile.get_active_by_code/1` matches
      it across every tournament, so guesses have to be expensive.

    * `:login_email` - magic-link sends, keyed by RECIPIENT address. This is
      the one that protects a person's inbox (and the SMTP quota) from being
      buried in log-in links, so it is deliberately tight.

    * `:login_client` - the same sends, keyed by CLIENT address, to stop one
      client walking a list of addresses. Much looser than the recipient
      limit on purpose: a chess club, a school or an office arrives from a
      single NAT address, and several arbiters signing in at the start of a
      tournament must not lock each other out.

    * `:public_register` - entries submitted through a tournament's public
      self-registration form, keyed by CLIENT address. Loose for the same
      NAT reason as `:login_client`, and looser still: a whole club
      registering from the venue wifi in the ten minutes before round one is
      the NORMAL use of that page, not abuse. This exists to stop a script
      filling an entry list, not to ration honest sign-ups.

  Callers pass the client address from `PairingsEngineWeb.ClientIp`, not
  `conn.remote_ip` - behind a proxy the latter is the same value for
  everybody, which would turn any of these limits into a way to lock the
  whole venue out at once.
  """
  use GenServer

  @table __MODULE__
  @sweep_ms :timer.minutes(10)

  @buckets %{
    mobile_enroll: %{max: 8, window_ms: :timer.minutes(10)},
    login_email: %{max: 5, window_ms: :timer.minutes(15)},
    login_client: %{max: 30, window_ms: :timer.minutes(15)},
    public_register: %{max: 40, window_ms: :timer.minutes(15)},
    # The results site searching this machine's FIDE list on behalf of
    # somebody filling in the entry form. A person typing a name fires a
    # handful; anything past this is not typing. Generous because a whole
    # club signing up from one venue's wifi shares an address.
    fide_lookup: %{max: 60, window_ms: :timer.minutes(1)}
  }

  @typedoc "Which limit is being counted - see the module doc."
  @type bucket :: :mobile_enroll | :login_email | :login_client | :public_register | :fide_lookup

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  True while `key` is still under `bucket`'s allowance. A window older than
  the bucket's own `window_ms` has rolled over, so its count no longer counts.
  """
  @spec allow?(bucket(), String.t()) :: boolean()
  def allow?(bucket, key) do
    %{max: max, window_ms: window_ms} = config(bucket)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, {bucket, key}) do
      [{_id, count, started_at}] -> now - started_at >= window_ms or count < max
      [] -> true
    end
  end

  @doc "Counts one hit for `key` in `bucket`, starting a fresh window if the last one rolled over."
  @spec record(bucket(), String.t()) :: :ok
  def record(bucket, key) do
    %{window_ms: window_ms} = config(bucket)
    now = System.monotonic_time(:millisecond)
    id = {bucket, key}

    case :ets.lookup(@table, id) do
      [{^id, count, started_at}] when now - started_at < window_ms ->
        :ets.insert(@table, {id, count + 1, started_at})

      _ ->
        :ets.insert(@table, {id, 1, now})
    end

    :ok
  end

  @doc "Forgets `key`'s count in `bucket` - used where a success proves the caller isn't guessing."
  @spec clear(bucket(), String.t()) :: :ok
  def clear(bucket, key) do
    :ets.delete(@table, {bucket, key})
    :ok
  end

  @doc "The configured allowance for `bucket`, for tests and for error copy."
  @spec config(bucket()) :: %{max: pos_integer(), window_ms: pos_integer()}
  def config(bucket), do: Map.fetch!(@buckets, bucket)

  ## ---------- GenServer ----------

  @impl true
  def init(:ok) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    # Rows are {{bucket, key}, count, started_at} and buckets have different
    # window lengths, so sweep per bucket rather than with one global cutoff -
    # dropping a row early would hand back a fresh allowance.
    Enum.each(@buckets, fn {bucket, %{window_ms: window_ms}} ->
      cutoff = now - window_ms

      :ets.select_delete(@table, [
        {{{bucket, :_}, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}
      ])
    end)

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
end
